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
        let connection = NarwalConnection(host: try host())
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
        XCTAssertEqual(map.rooms.map(\.displayName), ["Kitchen", "Living Room", "Ensuite"])
        XCTAssertEqual(map.width * map.height, map.pixels.count)
        XCTAssertNotNil(map.roomId(atGridX: 10, y: 10))
        XCTAssertEqual(map.noGoZones.count, 1)
        XCTAssertEqual(map.noGoZones.first?.kind, .noVacuumOrMop)
        XCTAssertEqual(map.noGoZones.first?.polygon.count, 4)
        XCTAssertEqual(map.virtualWalls.count, 1)
        XCTAssertEqual(map.furniture.map(\.name), ["Sofa"])
        XCTAssertEqual(map.carpets.first?.polygon.count, 4)
        XCTAssertEqual(map.carpetCellCount, 80)
        XCTAssertEqual(map.doorways.first?.roomIds, [1, 2])

        let history = try await connection.cleaningHistory()
        XCTAssertEqual(history.events.map(\.taskLabel), ["Cleaning", "Emptying dustbin"])
        XCTAssertEqual(history.events.first?.resultLabel, "Completed")
        XCTAssertNotNil(history.events.first?.date)

        // Settings: each write is read back.
        let before = try await connection.settings()
        XCTAssertEqual(before?.voiceVolume, 29)
        let louder = try await connection.setVoiceVolume(40)
        XCTAssertEqual(louder?.voiceVolume, 40)
        let childLock = try XCTUnwrap(RobotSettingKey.all.first { $0.id == "childLockEnabled" })
        let locked = try await connection.setSetting(childLock, 1)
        XCTAssertEqual(locked?.value(childLock), 1)
        let unlocked = try await connection.setSetting(childLock, 0)
        XCTAssertEqual(unlocked?.value(childLock), 0)
        let quiet = RobotSettings.DoNotDisturb(enabled: true, begin: 75_600, end: 25_200)
        let withQuiet = try await connection.setDoNotDisturb(quiet)
        XCTAssertEqual(withQuiet?.doNotDisturb, quiet)

        // A map edit: one carpet set to "avoid", read back from the map.
        let edited = try await connection.setCarpetCleanOption(1, to: 4, on: map)
        XCTAssertEqual(edited.carpets.first?.cleanOption, 4)

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

        // The fake drops clients that use another model's key, as a Z10
        // Ultra does: one connection attempt means it never happened.
        let connects = await recorder.events.filter {
            if case .connection(.connecting) = $0 { return true }
            return false
        }.count
        XCTAssertEqual(connects, 1)
        await connection.stop()
    }

    /// A docked robot is asleep and ignores everything until woken: the
    /// condition behind a "stuck connecting" report on a real Z10 Ultra.
    func testWakesSleepingRobot() async throws {
        guard let port = ProcessInfo.processInfo.environment["NARWAL_FAKE_SLEEPY_PORT"].flatMap(Int.init) else {
            throw XCTSkip("Set NARWAL_FAKE_SLEEPY_PORT with tools/fake_robot.py --sleepy running")
        }
        let connection = NarwalConnection(host: try host(), port: port)
        let recorder = Recorder()
        let consumer = Task {
            for await event in connection.events { await recorder.add(event) }
        }
        defer { consumer.cancel() }
        await connection.start()

        try await waitFor(recorder, timeout: 30, "device info from a sleeping robot") {
            if case .deviceInfo = $0 { return true }
            return false
        }
        try await waitFor(recorder, timeout: 20, "live status after waking") {
            if case .connection(.awake) = $0 { return true }
            return false
        }
        let map = try await connection.fetchMap()
        XCTAssertEqual(map.rooms.count, 3)
        // No reconnect loop: exactly one connection attempt.
        let connects = await recorder.events.filter {
            if case .connection(.connecting) = $0 { return true }
            return false
        }.count
        XCTAssertEqual(connects, 1)
        await connection.stop()
    }

    /// A robot that ignores commands without its device id, but is
    /// broadcasting (woken by the Narwal app): the id comes from a broadcast.
    func testLearnsDeviceIdFromBroadcast() async throws {
        guard let port = ProcessInfo.processInfo.environment["NARWAL_FAKE_NEEDS_ID_PORT"].flatMap(Int.init) else {
            throw XCTSkip("Set NARWAL_FAKE_NEEDS_ID_PORT with tools/fake_robot.py --needs-device-id running")
        }
        let connection = NarwalConnection(host: try host(), port: port)
        let recorder = Recorder()
        let consumer = Task {
            for await event in connection.events { await recorder.add(event) }
        }
        defer { consumer.cancel() }
        await connection.start()

        try await waitFor(recorder, timeout: 10, "identity from a broadcast") {
            if case .identity(_, let id) = $0 { return id == "fakerobot01" }
            return false
        }
        try await waitFor(recorder, timeout: 15, "device info once addressed properly") {
            if case .deviceInfo = $0 { return true }
            return false
        }
        let map = try await connection.fetchMap()
        XCTAssertEqual(map.rooms.count, 3)
        await connection.stop()
    }
}
