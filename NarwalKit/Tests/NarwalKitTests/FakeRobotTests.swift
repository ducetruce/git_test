import XCTest
@testable import NarwalKit

/// End-to-end session against tools/fake_robot.py. CI starts the fake robot
/// and sets NARWAL_FAKE_ROBOT; locally the test is skipped unless you do too.
final class FakeRobotTests: XCTestCase {
    private func host() throws -> String {
        guard let host = ProcessInfo.processInfo.environment["NARWAL_FAKE_ROBOT"] else {
            throw XCTSkip("Set NARWAL_FAKE_ROBOT=127.0.0.1 with tools/fake_robot.py running")
        }
        return host
    }

    /// Records every event from one long-lived consumer: an AsyncStream is
    /// terminated for good when the task iterating it is cancelled.
    private actor Recorder {
        private(set) var events: [NarwalEvent] = []
        func add(_ event: NarwalEvent) { events.append(event) }
    }

    private func waitFor(_ recorder: Recorder, timeout: TimeInterval, _ what: String,
                         _ predicate: (NarwalEvent) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await recorder.events.contains(where: predicate) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("timed out after \(Int(timeout)) s waiting for \(what)")
    }

    func testFullSession() async throws {
        // Start from the wrong product key to exercise identification.
        let connection = NarwalConnection(host: try host(), productKey: "QoEsI5qYXO")
        let recorder = Recorder()
        let consumer = Task {
            for await event in connection.events { await recorder.add(event) }
        }
        defer { consumer.cancel() }
        await connection.start()

        try await waitFor(recorder, timeout: 30, "device info") {
            if case .deviceInfo(let info) = $0 { return info.deviceId == "fakerobot01" }
            return false
        }
        try await waitFor(recorder, timeout: 10, "status broadcast") {
            if case .baseStatus(let status) = $0 { return status.workingStatus == .charged }
            return false
        }
        let identity = await (connection.productKey, connection.deviceId)
        XCTAssertEqual(identity.0, NarwalDefaults.z10UltraProductKey)
        XCTAssertEqual(identity.1, "fakerobot01")

        let map = try await connection.fetchMap()
        XCTAssertEqual(map.mapId, 1742)
        XCTAssertEqual(map.rooms.map(\.displayName), ["Kitchen", "Living room", "Ensuite"])
        XCTAssertEqual(map.width * map.height, map.pixels.count)
        XCTAssertNotNil(map.roomId(atGridX: 10, y: 10))

        do {
            try await connection.cleanRooms([42])
            XCTFail("unknown room accepted")
        } catch let error as RoomCleanError {
            XCTAssertEqual(error, .unknownRooms([42]))
        }

        try await connection.cleanRooms([3, 1], settings: CleanSettings(workMode: .vacuum))
        try await waitFor(recorder, timeout: 10, "live position") {
            if case .pose = $0 { return true }
            return false
        }
        try await connection.pause()
        try await connection.resume()
        try await connection.returnToDock()
        try await waitFor(recorder, timeout: 10, "returning to dock") {
            if case .baseStatus(let status) = $0 { return status.isReturning }
            return false
        }

        let alerts = try await connection.consumableAlerts()
        XCTAssertEqual(alerts.maintain, [4])
        XCTAssertEqual(alerts.replace, [3])

        await connection.stop()
    }
}
