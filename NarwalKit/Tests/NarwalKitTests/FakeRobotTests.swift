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
        let childLock = try XCTUnwrap(RobotSetting.named("childLockEnabled"))
        let locked = try await connection.setSetting(childLock.choices[1])
        XCTAssertEqual(locked?.value(childLock), "On")
        let unlocked = try await connection.setSetting(childLock.choices[0])
        XCTAssertEqual(unlocked?.value(childLock), "Off")
        // A nested Freo Mind setting, written into smartCleanParam.
        let remop = try XCTUnwrap(RobotSetting.named("maxRemopCount"))
        let two = try XCTUnwrap(remop.choices.first { $0.label == "2" })
        let limited = try await connection.setSetting(two)
        XCTAssertEqual(limited?.value(remop), "2")
        // Narwal's auto-empty picker: two stored switches.
        let frequency = try XCTUnwrap(RobotSetting.named("autoEmptyFrequency"))
        let smartEmpty = try await connection.setSetting(frequency.choices[0])
        XCTAssertEqual(smartEmpty?.value(frequency), "Smart")
        let quiet = RobotSettings.DoNotDisturb(enabled: true, begin: 75_600, end: 25_200)
        let withQuiet = try await connection.setDoNotDisturb(quiet)
        XCTAssertEqual(withQuiet?.doNotDisturb, quiet)

        // A map edit: one carpet set to "avoid", read back from the map.
        let edited = try await connection.setCarpetCleanOption(1, to: 4, on: map)
        XCTAssertEqual(edited.carpets.first?.cleanOption, 4)

        // More map edits, each checked against the map fetched afterwards.
        let zone = MapEdit.addNoGoZone(id: 2, kind: .noMop,
                                       corners: RobotMap.corners(Payloads.Zone(x1: 5, y1: 25, x2: 12, y2: 32)))
        let withZone = try await connection.editMap([zone], on: edited)
        XCTAssertTrue(zone.isApplied(before: edited, after: withZone))
        XCTAssertEqual(withZone.noGoZones.count, 2)
        let added = try XCTUnwrap(withZone.noGoZones.first { $0.id == 2 })
        let removal = MapEdit.deleteNoGoZone(added)
        let withoutZone = try await connection.editMap([removal], on: withZone)
        XCTAssertTrue(removal.isApplied(before: withZone, after: withoutZone))
        let kitchen = try XCTUnwrap(withoutZone.rooms.first { $0.id == 1 })
        let rename = MapEdit.renameRoom(kitchen, to: "Pantry")
        let renamed = try await connection.editMap([rename], on: withoutZone)
        XCTAssertTrue(rename.isApplied(before: withoutZone, after: renamed))
        XCTAssertEqual(renamed.rooms.first { $0.id == 1 }?.displayName, "Pantry")
        // Floor material keeps the name just set: the edit sends the room's
        // own RoomInfo with one value changed.
        let pantry = try XCTUnwrap(renamed.rooms.first { $0.id == 1 })
        let wood = MapEdit.setFloor(pantry, .wood, angle: 90)
        let floored = try await connection.editMap([wood], on: renamed)
        XCTAssertTrue(wood.isApplied(before: renamed, after: floored))
        XCTAssertEqual(floored.rooms.first { $0.id == 1 }?.displayName, "Pantry")
        XCTAssertEqual(floored.rooms.first { $0.id == 1 }?.floorAngle, 90)
        let soiled = MapEdit.setHeavilySoiled(try XCTUnwrap(floored.rooms.first { $0.id == 1 }), true)
        let marked = try await connection.editMap([soiled], on: floored)
        XCTAssertTrue(marked.rooms.first { $0.id == 1 }?.isHeavilySoiled == true)
        XCTAssertEqual(marked.rooms.first { $0.id == 1 }?.floor, .wood)
        // The real robot refuses easy clean, empty or not.
        let refused = try await connection.send(Topic.easyClean)
        XCTAssertFalse(refused.accepted)
        // Requests the robot ignores must not take the next query's answer.
        try await connection.drainDockBase()
        let afterDrain = try await connection.deviceInfo()
        XCTAssertNotNil(afterDrain, "drainage takes no place in the reply order")
        _ = try? await connection.send(Topic.pumpTroubleshooting, timeout: 2, lateGrace: 0)
        let afterProbe = try await connection.deviceInfo()
        XCTAssertNotNil(afterProbe, "an ignored probe with no late grace")
        // Wood floor maintenance on its own.
        try await connection.startFloorMaintenance(rooms: [1], cleanFirst: false)

        // Schedules: a routine saved as a plan, scheduled, switched off, deleted.
        let planId = try await connection.saveCleanPlan(
            Payloads.setCleanPlan(mapId: renamed.mapId, name: "Kitchen", rooms: [1], settings: CleanSettings(workMode: .vacuum)))
        XCTAssertGreaterThan(planId, 0)
        var schedules = try await connection.changeSchedules(
            Topic.addCleanSchedule,
            Payloads.addSchedule(cron: "30 9 * * 1,3", enabled: true, planId: planId, cleanMode: 2, name: "Kitchen"))
        XCTAssertEqual(schedules.map(\.summary), ["09:30, Mon Wed"])
        var off = try XCTUnwrap(schedules.first)
        off.enabled = false
        schedules = try await connection.changeSchedules(Topic.updateCleanSchedule, Payloads.updateSchedule(off))
        XCTAssertEqual(schedules.first?.enabled, false)
        schedules = try await connection.changeSchedules(Topic.deleteCleanSchedules, Payloads.deleteSchedules([off.id]))
        XCTAssertTrue(schedules.isEmpty)
        do {
            _ = try await connection.changeSchedules(
                Topic.addCleanSchedule,
                Payloads.addSchedule(cron: "0 8 * * *", enabled: true, planId: 999, cleanMode: 2, name: "x"))
            XCTFail("a schedule for a missing plan was accepted")
        } catch NarwalError.rejected(_, let code) {
            XCTAssertEqual(code, 3)
        }

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
