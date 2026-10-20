import XCTest
@testable import NarwalKit

private func hex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var index = s.startIndex
    while index < s.endIndex {
        let next = s.index(index, offsetBy: 2)
        out.append(UInt8(s[index..<next], radix: 16)!)
        index = next
    }
    return out
}

private func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

final class EncodingTests: XCTestCase {
    func testFramesMatchReference() {
        XCTAssertEqual(hexString(NarwalFrame(topic: "/DrzDKQ0MU8/DEV123/common/yell").encoded()),
                       GoldenVectors.frameYell)
        XCTAssertEqual(hexString(NarwalFrame(topic: "/DrzDKQ0MU8/DEV123/clean/set_fan_level",
                                             payload: Payloads.setFanLevel(.strong)).encoded()),
                       GoldenVectors.frameSetFan)
    }

    func testWakePayloadsMatchReference() {
        XCTAssertEqual(hexString(Payloads.topicSubscription(duration: 600)), GoldenVectors.subscription600)
        XCTAssertEqual(hexString(Payloads.singleVarint(1)), GoldenVectors.notifyAppEvent)
        XCTAssertEqual(hexString(Payloads.singleVarint(600)), GoldenVectors.activeRobotDuration600)
    }

    func testStartCleanMatchesReference() {
        XCTAssertEqual(hexString(Payloads.startClean(mapId: 7, rooms: [3, 5])),
                       GoldenVectors.startCleanDefaultsTwoRooms)
        XCTAssertEqual(hexString(Payloads.startClean(mapId: 7, rooms: [4])),
                       GoldenVectors.startCleanDefaultsOneRoom)

        let vacuum = CleanSettings(workMode: .vacuum, fan: .strong, water: .wet,
                                   mopStrength: .high, passes: 2, route: .meticulous)
        XCTAssertEqual(hexString(Payloads.startClean(mapId: 300, rooms: [1, 2, 9], settings: vacuum)),
                       GoldenVectors.startCleanVacuumStrongTwoPassesMeticulous)

        let perRoom: [Int: CleanSettings] = [
            2: CleanSettings(workMode: .vacuumThenMop, fan: .ultraPowerful, water: .dry, passes: 3),
            6: CleanSettings(workMode: .mop, water: .wet),
        ]
        XCTAssertEqual(hexString(Payloads.startClean(mapId: 7, rooms: [2, 6], perRoom: perRoom)),
                       GoldenVectors.startCleanMixedPerRoom)
    }

    func testLiveFanCommandClampsUltra() {
        XCTAssertEqual(Payloads.setFanLevel(.ultraPowerful), [0x08, 0x04])
    }
}

final class DecodingTests: XCTestCase {
    func testResponseFrame() throws {
        let frame = try NarwalFrame(bytes: [0x01, 0x02, 0x2A, 0x00, 0x08, 0x01])
        XCTAssertEqual(frame.kind, .response)
        XCTAssertEqual(frame.topic, "")
        XCTAssertEqual(frame.payload, [0x08, 0x01])
    }

    func testBroadcastTopicParts() throws {
        let frame = try NarwalFrame(bytes: NarwalFrame(topic: "/DrzDKQ0MU8/abc/status/working_status").encoded())
        XCTAssertEqual(frame.shortTopic, "status/working_status")
        XCTAssertEqual(frame.topicDeviceId, "abc")
        XCTAssertEqual(frame.topicProductKey, "DrzDKQ0MU8")
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try NarwalFrame(bytes: [0x02, 0x02, 0x22, 0x00]))
        XCTAssertThrowsError(try NarwalFrame(bytes: [0x01, 0x09, 0x22, 0x08, 0x41]))
    }

    func testCommandResultCodes() throws {
        let ack = CommandResponse(message: try ProtoMessage(bytes: [0x08, 0x04]), raw: [])
        XCTAssertEqual(ack.result, .notReady)
        XCTAssertFalse(ack.accepted)
        let data = CommandResponse(message: try ProtoMessage(bytes: [0x0A, 0x01, 0x41]), raw: [])
        XCTAssertTrue(data.accepted)
    }

    func testMap() throws {
        let map = try RobotMap(response: ProtoMessage(bytes: hex(GoldenVectors.mapResponse)))
        XCTAssertEqual(map.mapId, 1742)
        XCTAssertEqual(map.width, 4)
        XCTAssertEqual(map.height, 3)
        XCTAssertEqual(map.resolution, 60)
        XCTAssertEqual(map.originX, 20)
        XCTAssertEqual(map.originY, 10)
        XCTAssertEqual(map.dock, MapPoint(x: 1.5, y: 1.0))
        XCTAssertEqual(map.rooms.map(\.displayName), ["Kitchen", "Ensuite", "Bathroom 2"])
        XCTAssertEqual(map.pixels, [0x100, 0x100, 0x200, 0x200,
                                    0x110, 0x100, 0x200, 0x20,
                                    0, 0x28, 0x210, 0])
        XCTAssertEqual(map.pixel(x: 0, y: 1), .wall(room: 1))
        XCTAssertEqual(map.pixel(x: 3, y: 1), .unassignedFloor)
        XCTAssertEqual(map.roomId(atGridX: 2, y: 0), 2)
        XCTAssertNil(map.roomId(atGridX: 0, y: 2))
        XCTAssertEqual(map.roomCentroids()[1], MapPoint(x: 2.0 / 3.0, y: 1.0 / 3.0))
    }

    func testMapWithoutActiveMapThrows() {
        XCTAssertThrowsError(try RobotMap(response: ProtoMessage(bytes: [0x08, 0x01, 0x10, 0x05])))
    }

    func testBaseStatusCleaningOffDockWithFault() throws {
        let status = BaseStatus(try ProtoMessage(bytes: hex(GoldenVectors.baseStatusCleaningOffDockWithFault)))
        XCTAssertEqual(status.battery, 83)
        XCTAssertEqual(status.workingStatus, .cleaningV2)
        XCTAssertEqual(status.rawWorkingStatus, 2)
        XCTAssertEqual(status.isDocked, false)
        XCTAssertEqual(status.errors, [RobotError(code: 2103, level: 2, detail: "wheel")])
        XCTAssertEqual(status.fanLevel, .strong)
        XCTAssertEqual(status.mopHumidity, .normal)
        XCTAssertEqual(status.station.problems, ["Clean water tank needs attention"])
    }

    func testBaseStatusDocked() throws {
        let status = BaseStatus(try ProtoMessage(bytes: hex(GoldenVectors.baseStatusDockedCharged)))
        XCTAssertEqual(status.battery, 100)
        XCTAssertEqual(status.workingStatus, .docked)
        XCTAssertEqual(status.isDocked, true)
        XCTAssertTrue(status.errors.isEmpty)
        XCTAssertNil(status.station.cleanWaterTank, "absent fields are unknown, not fine")
    }

    func testLivePose() throws {
        let pose = try XCTUnwrap(LivePose(ProtoMessage(bytes: hex(GoldenVectors.displayMapPose))))
        XCTAssertEqual(pose.position, MapPoint(x: 123.25, y: -45.5))
        XCTAssertEqual(pose.heading, Double(Float(1.5707964)), accuracy: 1e-6)
        XCTAssertEqual(pose.timestampMs, 1_760_000_000_000)
    }

    func testWorkingProgress() throws {
        let progress = WorkingProgress(try ProtoMessage(bytes: hex(GoldenVectors.workingStatus)))
        XCTAssertEqual(progress.progressPercent, 42)
        XCTAssertEqual(progress.areaSquareMeters, 12.5)
        XCTAssertEqual(progress.elapsedSeconds, 600)
        XCTAssertEqual(progress.remainingSeconds, 900)
        XCTAssertEqual(progress.currentRoomId, 2)
    }

    func testConsumablesArePackedLists() throws {
        let alerts = ConsumableAlerts(response: try ProtoMessage(bytes: hex(GoldenVectors.consumableInfo)))
        XCTAssertEqual(alerts.maintain, [4, 6, 8, 10])
        XCTAssertEqual(alerts.replace, [3, 20])
        XCTAssertEqual(alerts.replaceLabels, ["Side brush", "Station bag"])
    }
}

final class ZoneTests: XCTestCase {
    func testZoneCleanMatchesReference() {
        XCTAssertEqual(hexString(Payloads.zoneClean(mapId: 1742, zones: [.init(x1: -21, y1: -23, x2: 29, y2: -15)])),
                       GoldenVectors.zoneCleanNegativeCoords)
        let vacuum = CleanSettings(workMode: .vacuum, fan: .strong, water: .wet, mopStrength: .high, passes: 2)
        XCTAssertEqual(hexString(Payloads.zoneClean(mapId: 7, zones: [.init(x1: 5, y1: 5, x2: 9, y2: 12),
                                                                     .init(x1: -3, y1: 4, x2: 0, y2: 1)],
                                                    settings: vacuum)),
                       GoldenVectors.zoneCleanTwoZonesVacuum)
    }
}

final class ResearchTests: XCTestCase {
    func testFlattenNamesNestedAndRepeatedFields() throws {
        let leaves = Research.flatten(try ProtoMessage(bytes: hex(GoldenVectors.consumableInfo)))
        XCTAssertEqual(leaves, [Research.Leaf(path: "1.1", value: "0x0406080a"),
                                Research.Leaf(path: "1.2", value: "0x0314")])

        var w = ProtoWriter()
        w.message(2) { m in m.string(3, "Kitchen"); m.varint(1, 4) }
        w.message(2) { m in m.varint(1, 5) }
        w.varint(10, 7)
        let flat = Research.flatten(try ProtoMessage(bytes: w.bytes))
        XCTAssertEqual(flat.map(\.path), ["2[0].3", "2[0].1", "2[1].1", "10"])
        XCTAssertEqual(flat[0].value, "\"Kitchen\"")
    }

    func testDiffReportsOnlyChanges() {
        let before = [Research.Leaf(path: "1", value: "5"), Research.Leaf(path: "2", value: "1"),
                      Research.Leaf(path: "10", value: "x")]
        let after = [Research.Leaf(path: "1", value: "6"), Research.Leaf(path: "10", value: "x"),
                     Research.Leaf(path: "3", value: "9")]
        XCTAssertEqual(Research.diff(before, after), [
            Research.Change(path: "1", before: "5", after: "6"),
            Research.Change(path: "2", before: "1", after: nil),
            Research.Change(path: "3", before: nil, after: "9"),
        ])
    }

    func testErrorText() {
        XCTAssertEqual(RobotErrorText.message(for: 0x01010013), "Base station overflowed")
        XCTAssertEqual(RobotErrorText.message(for: 255), "Fault 255 (0xFF)")
    }
}

final class SafetyTests: XCTestCase {
    func testLabOnlySendsQueries() {
        XCTAssertTrue(Research.isSafeQuery("config/get"))
        XCTAssertTrue(Research.isSafeQuery("info/battery_info"))
        XCTAssertFalse(Research.isSafeQuery("config/set"))
        XCTAssertFalse(Research.isSafeQuery("common/reboot"))
        XCTAssertFalse(Research.isSafeQuery("developer/get_robot_info"), "returns the Wi-Fi password")
        XCTAssertTrue(Research.probeTopics.allSatisfy(Research.isSafeQuery))
    }
}

final class ResponseShapeTests: XCTestCase {
    private func message(_ build: (inout ProtoWriter) -> Void) throws -> ProtoMessage {
        var w = ProtoWriter()
        build(&w)
        return try ProtoMessage(bytes: w.bytes)
    }

    func testDeviceInfoIsNotTakenForAnAck() throws {
        let info = try message { $0.string(1, "DrzDKQ0MU8"); $0.string(2, "abc"); $0.string(3, "v1") }
        let ack = try message { $0.varint(1, 1) }
        let burstAck = ResponseShape(topic: Topic.notifyAppEvent, fireAndForget: true)
        let deviceInfo = ResponseShape(topic: Topic.getDeviceInfo, fireAndForget: false)
        XCTAssertFalse(burstAck.accepts(info))
        XCTAssertTrue(burstAck.accepts(ack))
        XCTAssertTrue(deviceInfo.accepts(info))
        XCTAssertFalse(deviceInfo.accepts(ack), "a success ack is not device info")
        XCTAssertTrue(deviceInfo.accepts(try message { $0.varint(1, 4) }), "an error status answers anything")
    }

    func testMapRejectsStatusReply() throws {
        let map = ResponseShape(topic: Topic.getMap, fireAndForget: false)
        let status = ResponseShape(topic: Topic.getBaseStatus, fireAndForget: false)
        let bareNumber = try message { $0.varint(2, 1_120_403_456) }  // captured in reference #108
        XCTAssertFalse(map.accepts(bareNumber))
        XCTAssertTrue(status.accepts(bareNumber))
        XCTAssertTrue(map.accepts(try ProtoMessage(bytes: hex(GoldenVectors.mapResponse))))
    }
}
