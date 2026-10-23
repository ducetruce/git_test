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
        XCTAssertEqual(hexString(NarwalFrame(topic: "/DrzDKQ0MU8/DEV123/common/yell").encoded() ?? []),
                       GoldenVectors.frameYell)
        XCTAssertEqual(hexString(NarwalFrame(topic: "/DrzDKQ0MU8/DEV123/clean/set_fan_level",
                                             payload: Payloads.setFanLevel(.strong)).encoded() ?? []),
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
        let frame = try NarwalFrame(bytes: XCTUnwrap(NarwalFrame(topic: "/DrzDKQ0MU8/abc/status/working_status").encoded()))
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
        // 23 = 3 is CLEAN_WATER_TANK_STATE_NOT_INSTALLED, 24 = 1 is NORMAL.
        XCTAssertEqual(status.station.problems, ["Clean water tank is not in place"])
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
        XCTAssertEqual(RobotErrorText.message(for: 255), "Robot fault")
        XCTAssertEqual(RobotErrorText.hexCode(0x02020031), "0x02020031")
        XCTAssertEqual(RobotErrorText.hexCode(255), "0x000000FF")
        XCTAssertEqual(RobotErrorText.advice(for: 0x02020031)?.hasPrefix("Turn the robot over"), true)
        XCTAssertNil(RobotErrorText.advice(for: 255))
        // As sent by a Z10 Ultra.
        let detail = "错误码:0x02020031\n等级:Error 级别\n域:机器人-嵌入式系统\n节点:主控板 hal node\n原因:robot roll brush is over current when sweeping\n是否会触发自动召回基站:否"
        XCTAssertEqual(RobotErrorText.reason(fromDetail: detail), "Robot roll brush is over current when sweeping")
        XCTAssertNil(RobotErrorText.reason(fromDetail: "原因:滚刷电流过大"))
        XCTAssertNil(RobotErrorText.reason(fromDetail: ""))
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

    func testRobotSettings() throws {
        // Shapes seen on a Z10 Ultra as the volume slider was moved.
        let loud = try message { w in
            w.varint(1, 1)
            w.message(2) { m in
                m.varint(1, 96)
                m.message(3) { tz in tz.string(1, "Europe/Berlin") }
                m.message(4) { dnd in dnd.varint(2, 79_200); dnd.varint(3, 28_800) }
                m.varint(6, 1)
            }
        }
        let settings = try XCTUnwrap(RobotSettings(response: loud))
        XCTAssertEqual(settings.voiceVolume, 96)
        XCTAssertEqual(settings.timeZone, "Europe/Berlin")
        XCTAssertEqual(settings.doNotDisturb, .init(enabled: false, begin: 79_200, end: 28_800))

        let silent = try message { w in w.varint(1, 1); w.message(2) { m in m.varint(6, 1) } }
        XCTAssertEqual(RobotSettings(response: silent)?.voiceVolume, 0, "0 is omitted on the wire")
        XCTAssertNil(RobotSettings(response: try message { $0.varint(1, 1) }), "a bare ack is not settings")
    }

    func testSettingsCatalogFieldNumbers() throws {
        // Independent restatement of the get -> set numbering in the schema.
        func setField(forGet get: Int) -> Int? {
            switch get {
            case 1...3, 15...44: return get
            case 4...13: return get + 1
            case 46, 47: return get - 1
            case 49...56: return get - 2
            default: return nil
            }
        }
        for setting in RobotSetting.all {
            for choice in setting.choices {
                for write in choice.writes {
                    XCTAssertNotNil(setField(forGet: write.path[0]), "\(setting.id) has no setter")
                    XCTAssertEqual(RobotSetting.setField(forGet: write.path[0]), setField(forGet: write.path[0]), setting.id)
                }
            }
        }
        XCTAssertEqual(Set(RobotSetting.all.map(\.id)).count, RobotSetting.all.count)

        let response = try message { w in
            w.varint(1, 1)
            w.message(2) { m in
                m.varint(7, 1); m.varint(17, 4); m.varint(27, 1)
                m.message(29) { p in p.message(4) { f in f.varint(1, 1); f.varint(2, 3) }; p.varint(99, 7) }
            }
        }
        let settings = try XCTUnwrap(RobotSettings(response: response))

        let childLock = try XCTUnwrap(RobotSetting.named("childLockEnabled"))
        XCTAssertEqual(settings.value(childLock), "On")
        XCTAssertEqual(RobotSetting.requests(for: childLock.choices[1], current: settings), [[0x40, 0x01]])
        XCTAssertEqual(RobotSetting.requests(for: childLock.choices[0], current: settings), [[0x40, 0x00]],
                       "off must still be sent")
        XCTAssertEqual(settings.value(try XCTUnwrap(RobotSetting.named("addCarpetCleanOption"))), "Avoid")
        XCTAssertEqual(settings.value(try XCTUnwrap(RobotSetting.named("petMode"))), "Off", "absent is off")
        // Two stored switches behind one Narwal picker: emptying on, smart off.
        let frequency = try XCTUnwrap(RobotSetting.named("autoEmptyFrequency"))
        XCTAssertEqual(settings.value(frequency), "Frequent")
        XCTAssertEqual(RobotSetting.requests(for: frequency.choices[0], current: settings),
                       [[0xD8, 0x01, 0x01], [0xE0, 0x01, 0x01]])

        // A Freo Mind strategy lives inside smartCleanParam (29): the write
        // sends the robot's own message back with one value changed and
        // unknown fields kept.
        let suction = try XCTUnwrap(RobotSetting.named("fanLevelStrategy"))
        XCTAssertEqual(settings.value(suction), "Strong")
        let smart = try XCTUnwrap(suction.choices.first { $0.label == "Smart" })
        let request = try XCTUnwrap(RobotSetting.requests(for: smart, current: settings).first)
        let sent = try XCTUnwrap(try ProtoMessage(bytes: request).message(29))
        XCTAssertEqual(sent.int(path: [4, 1]), 0)
        XCTAssertEqual(sent.int(path: [4, 2]), 3)
        XCTAssertEqual(sent.int(99), 7)

        XCTAssertEqual(Payloads.setDoNotDisturb(.init(enabled: true, begin: 79_200, end: 28_800)),
                       [0x2A, 0x0A, 0x08, 0x01, 0x10, 0xE0, 0xEA, 0x04, 0x18, 0x80, 0xE1, 0x01])
    }

    func testOtherRepliesAreNotTakenForDeviceInfo() async throws {
        // As crashed the app: a config/get reply (field 2 = a message) read
        // as device info made its bytes the device id.
        let config = try message { w in
            w.varint(1, 1)
            w.message(2) { m in m.varint(1, 96); m.message(3) { tz in tz.string(1, "America/Los_Angeles") } }
        }
        XCTAssertNil(DeviceInfo(response: config))
        let shape = ResponseShape(topic: Topic.getDeviceInfo, fireAndForget: false)
        XCTAssertFalse(shape.accepts(config))
        XCTAssertNotNil(DeviceInfo(response: try message { $0.string(1, "DrzDKQ0MU8"); $0.string(2, "a1B2-c3_d4") }))
        XCTAssertFalse(DeviceInfo.isPlausibleId(String(repeating: "x", count: 65)))
        XCTAssertFalse(DeviceInfo.isPlausibleId("ab cd"))
        XCTAssertNil(NarwalFrame(topic: "/" + String(repeating: "x", count: 300)).encoded(), "too long: nil, not a trap")
        let restored = await NarwalConnection(host: "127.0.0.1", deviceId: "\u{8}\u{1}\u{12}").deviceId
        XCTAssertEqual(restored, "", "a saved binary id is dropped")
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

final class HostTests: XCTestCase {
    func testInterfaceScopeIsStripped() {
        // Network framework hands back addresses like this; the "%" made the
        // WebSocket URL invalid and crashed the app at launch.
        XCTAssertEqual(NarwalConnection.normalizedHost("192.168.1.50%en0"), "192.168.1.50")
        XCTAssertEqual(NarwalConnection.normalizedHost(" 10.0.0.7 \n"), "10.0.0.7")
        XCTAssertEqual(NarwalConnection.normalizedHost("[fe80::1%en0]"), "fe80::1")
        XCTAssertEqual(NarwalConnection.normalizedHost("robot.local"), "robot.local")
    }

    func testBadAddressDoesNotCrash() async {
        let connection = NarwalConnection(host: "bad host name with spaces")
        await connection.start()
        try? await Task.sleep(nanoseconds: 300_000_000)
        await connection.stop()
    }
}

/// Built from docs/schema/messages.txt field numbers.
final class SchemaDecoderTests: XCTestCase {
    private func message(_ build: (inout ProtoWriter) -> Void) throws -> ProtoMessage {
        var w = ProtoWriter()
        build(&w)
        return try ProtoMessage(bytes: w.bytes)
    }

    func testFloatWriterRoundTrips() throws {
        let m = try message { $0.float(1, -2.5); $0.float(2, 96.25) }
        XCTAssertEqual(m.float(1), -2.5)
        XCTAssertEqual(m.float(2), 96.25)
    }

    func testNoGoZonesAndVirtualWalls() throws {
        // map/get_map response {1: result, 2: StaticMapPayload}
        let response = try message { w in
            w.varint(1, 1)
            w.message(2) { map in
                map.varint(1, 7)       // mapId
                map.varint(3, 60)      // resolution
                map.varint(4, 2)       // width
                map.varint(5, 2)       // height
                // 9 forbiddens: ForbiddenArea {1 polygon, 2 type, 3 id, 4 roomId, 5 mode}
                map.message(9) { zone in
                    for (x, y) in [(-1.5, -2.0), (3.0, -2.0), (3.0, 4.5), (-1.5, 4.5)] as [(Float, Float)] {
                        zone.message(1) { p in p.float(1, x); p.float(2, y) }   // Point (float)
                    }
                    zone.varint(2, 3)  // FORBIDDEN_TYPE_SWEEP_MOP
                    zone.varint(3, 11)
                }
                map.message(9) { zone in
                    zone.message(1) { p in p.varint(1, -3); p.varint(2, 4) }   // Grid (int32)
                    zone.message(1) { _ in }                                    // (0, 0): zeros omitted
                    zone.message(1) { p in p.varint(1, 5) }
                    zone.varint(2, 2)  // FORBIDDEN_TYPE_MOP
                    zone.varint(3, 12)
                    zone.varint(4, 5)
                    zone.varint(5, 1)  // FORBIDDEN_MODE_ROOM
                }
                // 50 virtualWalls: VirtualWallData {1 id, 2 startPoint, 3 endPoint}
                map.message(50) { wall in
                    wall.varint(1, 21)
                    wall.message(2) { p in p.float(1, 0.5); p.float(2, 1) }
                    wall.message(3) { p in p.float(1, 4); p.float(2, 1) }
                }
            }
        }
        let map = try RobotMap(response: response)
        XCTAssertEqual(map.noGoZones.count, 2)

        let both = map.noGoZones[0]
        XCTAssertEqual(both.id, 11)
        XCTAssertEqual(both.kind, .noVacuumOrMop)
        XCTAssertNil(both.roomId)
        XCTAssertFalse(both.coversWholeRoom)
        XCTAssertEqual(both.polygon, [MapPoint(x: -1.5, y: -2), MapPoint(x: 3, y: -2),
                                      MapPoint(x: 3, y: 4.5), MapPoint(x: -1.5, y: 4.5)])

        let mop = map.noGoZones[1]
        XCTAssertEqual(mop.kind, .noMop)
        XCTAssertEqual(mop.roomId, 5)
        XCTAssertTrue(mop.coversWholeRoom)
        XCTAssertEqual(mop.polygon, [MapPoint(x: -3, y: 4), MapPoint(x: 0, y: 0), MapPoint(x: 5, y: 0)])

        XCTAssertEqual(map.virtualWalls, [VirtualWall(id: 21, start: MapPoint(x: 0.5, y: 1), end: MapPoint(x: 4, y: 1))])
    }

    func testFurnitureCarpetsAndDoorways() throws {
        let response = try message { w in
            w.varint(1, 1)
            w.message(2) { map in
                map.varint(1, 7); map.varint(4, 2); map.varint(5, 2)
                // 11 doors: Door {1 roomIds (packed), 2 doorPts Grid, 3 hasDoorSill}
                map.message(11) { door in
                    door.bytesField(1, [3, 4])
                    door.message(2) { p in p.varint(1, 10); p.varint(2, 20) }
                    door.message(2) { p in p.varint(1, 10); p.varint(2, 26) }
                    door.varint(3, 1)
                }
                // 26 carpets: Carpet {1 id, 2 polygon Grid, ..., 12 roomId}
                map.message(26) { carpet in
                    carpet.varint(1, 9)
                    for (x, y) in [(1, 1), (5, 1), (5, 3)] { carpet.message(2) { p in p.varint(1, x); p.varint(2, y) } }
                    carpet.varint(12, 3)
                }
                // 32 visionData: VisionData {1 furnitures: Furniture {1 id, 2 type,
                //   3 box {1 center Point, 2 width, 3 height}, 4 angle}}
                map.message(32) { vision in
                    vision.message(1) { f in
                        f.varint(1, 4)
                        f.varint(2, 2)   // double bed
                        f.message(3) { box in
                            box.message(1) { c in c.float(1, 12.5); c.float(2, -3) }
                            box.float(2, 20); box.float(3, 16)
                        }
                        f.float(4, 90)
                    }
                }
            }
        }
        let map = try RobotMap(response: response)
        XCTAssertEqual(map.doorways, [Doorway(points: [MapPoint(x: 10, y: 20), MapPoint(x: 10, y: 26)],
                                              roomIds: [3, 4], hasSill: true)])
        XCTAssertEqual(map.carpets, [CarpetArea(id: 9, polygon: [MapPoint(x: 1, y: 1), MapPoint(x: 5, y: 1),
                                                                  MapPoint(x: 5, y: 3)], roomId: 3)])
        XCTAssertEqual(map.furniture, [Furniture(id: 4, type: 2, center: MapPoint(x: 12.5, y: -3),
                                                 width: 20, height: 16, angle: 90)])
        XCTAssertEqual(map.furniture.first?.name, "Double bed")
    }

    func testCarpetsInPixelOrMapCoordinates() throws {
        let response = try message { w in
            w.varint(1, 1)
            w.message(2) { map in
                map.varint(1, 7); map.varint(4, 40); map.varint(5, 30)
                map.message(6) { border in border.varint(1, -100); border.varint(3, -200) }
                // Map coordinates: stays as is.
                map.message(26) { carpet in
                    carpet.varint(1, 1)
                    for (x, y) in [(-190, -90), (-180, -90), (-180, -80)] { carpet.message(2) { p in p.varint(1, x); p.varint(2, y) } }
                }
                // Pixel indices: moved into map coordinates.
                map.message(26) { carpet in
                    carpet.varint(1, 2)
                    for (x, y) in [(5, 5), (15, 5), (15, 10)] { carpet.message(2) { p in p.varint(1, x); p.varint(2, y) } }
                }
                // Only carpetModifyPolygon (6).
                map.message(26) { carpet in
                    carpet.varint(1, 3)
                    for (x, y) in [(-170, -90), (-160, -90), (-160, -80)] { carpet.message(6) { p in p.varint(1, x); p.varint(2, y) } }
                }
            }
        }
        let map = try RobotMap(response: response)
        XCTAssertEqual(map.carpets.map(\.polygon), [
            [MapPoint(x: -190, y: -90), MapPoint(x: -180, y: -90), MapPoint(x: -180, y: -80)],
            [MapPoint(x: -195, y: -95), MapPoint(x: -185, y: -95), MapPoint(x: -185, y: -90)],
            [MapPoint(x: -170, y: -90), MapPoint(x: -160, y: -90), MapPoint(x: -160, y: -80)],
        ])
        XCTAssertEqual(map.carpets.map { map.gridPoint(for: $0.polygon[0]) },
                       [MapPoint(x: 10, y: 10), MapPoint(x: 5, y: 5), MapPoint(x: 30, y: 10)])
    }

    func testCarpetPixelsAndTypeCounts() {
        // Row 0: plain floor, carpet floor, flagged (0x10) carpet, obstacle 0x28.
        let map = RobotMap(mapId: 1, width: 4, height: 1, resolution: 60, rooms: [],
                           pixels: [0x100, 0x104, 0x114, 0x28])
        XCTAssertEqual((0..<4).map { map.isCarpet(x: $0, y: 0) }, [false, true, true, false])
        XCTAssertEqual(map.carpetCellCount, 2)
        XCTAssertEqual(map.pixelTypeCounts().map(\.type), [0x00, 0x04, 0x14, 0x28])
        XCTAssertEqual(map.pixel(x: 1, y: 0), .floor(room: 1))
    }

    func testCarpetEditPayload() throws {
        var map = RobotMap(mapId: 1742, width: 1, height: 1, resolution: 60, rooms: [], pixels: [0])
        map.mapVersion = 3
        map.editVersion = 9
        let bytes = Payloads.carpetCleanOption(map, carpetId: 5, option: 4)
        // {1: 1742, 2: 3, 3: 9, 4: {6: {1: 5, 2: 4, 3: 0}}}
        XCTAssertEqual(bytes, [0x08, 0xCE, 0x0D, 0x10, 0x03, 0x18, 0x09,
                               0x22, 0x08, 0x32, 0x06, 0x08, 0x05, 0x10, 0x04, 0x18, 0x00])
        let request = try ProtoMessage(bytes: bytes)
        let carpet = try XCTUnwrap(request.message(4)?.message(6))
        XCTAssertEqual([carpet.int(1), carpet.int(2), carpet.int(3)], [5, 4, 0])
    }

    func testCarpetDetails() throws {
        let response = try message { w in
            w.varint(1, 1)
            w.message(2) { map in
                map.varint(1, 7); map.varint(2, 12); map.varint(33, 4); map.varint(4, 20); map.varint(5, 20)
                map.message(26) { carpet in
                    carpet.varint(1, 2)
                    for (x, y) in [(0, 0), (10, 0), (10, 5), (0, 5)] { carpet.message(2) { p in p.varint(1, x); p.varint(2, y) } }
                    carpet.varint(4, 4); carpet.varint(5, 2); carpet.varint(9, 1); carpet.varint(11, 1)
                }
            }
        }
        let map = try RobotMap(response: response)
        XCTAssertEqual([map.mapVersion, map.editVersion], [12, 4])
        let carpet = try XCTUnwrap(map.carpets.first)
        XCTAssertEqual(carpet.cleanOption, 4)
        XCTAssertEqual(carpet.source, 2)
        XCTAssertTrue(carpet.isFullRoom && carpet.sideBrush && !carpet.deepClean)
        XCTAssertEqual(carpet.area, 50)
    }

    func testMapWithoutAnnotations() throws {
        let map = try RobotMap(response: ProtoMessage(bytes: hex(GoldenVectors.mapResponse)))
        XCTAssertTrue(map.noGoZones.isEmpty)
        XCTAssertTrue(map.virtualWalls.isEmpty)
        XCTAssertTrue(map.furniture.isEmpty && map.carpets.isEmpty && map.doorways.isEmpty)
    }

    func testCleaningHistory() throws {
        // GetCleanTimeLine.Response {1 result, 2 TimeLineStatus {1 robotEventList}}
        let response = try message { w in
            w.varint(1, 1)
            w.message(2) { status in
                status.message(1) { node in                 // RobotEventNode
                    node.varint(1, 1_760_000_000_000)       // eventTime (ms)
                    node.varint(2, 4)                       // PRIMARY_TASK_TYPE_CLEAN
                    node.message(3) { secondary in          // SecondaryCleanEvent
                        secondary.message(2) { zone in      // EventZoneInfo
                            zone.varint(1, 1); zone.varint(2, 3); zone.varint(4, 4)
                        }
                    }
                    node.varint(5, 1)                       // TASK_RESULT_NORMAL_END
                    node.varint(7, 1)                       // isPrimaryNode
                    node.varint(8, 99)                      // nodeKey
                }
                status.message(1) { node in
                    node.varint(1, 1_760_000_000)           // eventTime (s)
                    node.varint(2, 5)                       // UNEXPECTED_PAUSE
                    node.message(6) { e in e.varint(1, 0x0213_0020); e.varint(2, 2) }
                }
                status.message(1) { node in node.varint(1, 42); node.varint(2, 1) }
            }
        }
        let history = try XCTUnwrap(CleaningHistory(response: response))
        XCTAssertEqual(history.events.count, 3)

        let clean = history.events[0]
        XCTAssertEqual(clean.id, 99)
        XCTAssertEqual(clean.date, Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(clean.taskLabel, "Cleaning")
        XCTAssertEqual(clean.resultLabel, "Completed")
        XCTAssertTrue(clean.succeeded)
        XCTAssertTrue(clean.isPrimary)
        XCTAssertEqual(clean.zoneId, 3)
        XCTAssertEqual(clean.cleanMode, 4)

        let pause = history.events[1]
        XCTAssertEqual(pause.id, 1, "no nodeKey: position in the list")
        XCTAssertEqual(pause.date, Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(pause.errorCode, 0x0213_0020)
        XCTAssertNil(pause.resultLabel)
        XCTAssertFalse(pause.isPrimary)

        XCTAssertNil(history.events[2].date, "not an epoch time")
        // A Z10 Ultra sends nanoseconds since 1970.
        let now = Date(timeIntervalSince1970: 1_792_480_000)
        XCTAssertEqual(CleaningEvent.plausibleDate(1_792_473_254_734_706_034, now: now)?.timeIntervalSince1970 ?? 0,
                       1_792_473_254.734706, accuracy: 0.001)
        XCTAssertEqual(CleaningEvent.plausibleDate(1_792_473_254, now: now)?.timeIntervalSince1970, 1_792_473_254)
        XCTAssertNil(CleaningEvent.plausibleDate(4_102_444_800), "2100 is in the future")
        XCTAssertEqual(history.events[2].taskLabel, "Self-check")

        XCTAssertNil(CleaningHistory(response: try message { $0.varint(1, 1) }), "a bare ack has no timeline")
        XCTAssertTrue(CleaningHistory(timeLine: try message { _ in }).events.isEmpty)
    }

    func testSchedules() throws {
        // GetCleanSchedules.Response {1 errorCode, 2 cleanSchedules}
        let response = try message { w in
            w.message(1) { _ in }
            w.message(2) { s in                           // CleanSchedule
                s.varint(1, 3)                            // taskId
                s.message(2) { p in                       // CleanScheduleParam
                    p.message(1) { c in c.string(1, "0 30 9 * * 1,3,5"); c.varint(2, 10); c.varint(3, 1) }
                    p.varint(2, 7)                        // cleanPlanId
                    p.varint(3, 4)                        // CLEAN_MODE_SWEEP_MOP_SYNC
                    p.varint(4, 1)
                    p.string(5, "Weekday mornings")
                }
            }
            w.message(2) { s in
                s.varint(1, 4)
                s.message(2) { p in p.message(1) { c in c.string(1, "15 22 * * *") } }
            }
        }
        let schedules = CleanSchedule.list(response: response)
        XCTAssertEqual(schedules.count, 2)
        XCTAssertEqual(schedules[0].id, 3)
        XCTAssertEqual(schedules[0].name, "Weekday mornings")
        XCTAssertTrue(schedules[0].enabled)
        XCTAssertEqual(schedules[0].remindingTime, 10)
        XCTAssertEqual(schedules[0].planId, 7)
        XCTAssertEqual(schedules[0].cleanMode, 4)
        XCTAssertTrue(schedules[0].isCustomPlan)
        XCTAssertEqual(schedules[0].summary, "09:30, Mon Wed Fri")
        XCTAssertFalse(schedules[1].enabled)
        XCTAssertEqual(schedules[1].summary, "22:15, every day")
        XCTAssertTrue(CleanSchedule.list(response: try message { $0.message(1) { _ in } }).isEmpty)
    }

    func testCronSummaryEdgeCases() throws {
        func summary(_ cron: String) throws -> String? {
            try XCTUnwrap(CleanSchedule.list(response: message { w in
                w.message(2) { s in s.message(2) { p in p.message(1) { c in c.string(1, cron) } } }
            }).first).summary
        }
        XCTAssertEqual(try summary("0 8 * * 1-3"), "08:00, Mon Tue Wed")
        XCTAssertEqual(try summary("0 8 * * 0,7"), "08:00, Sun Sun")
        XCTAssertNil(try summary("0 8 * * 5-1"), "reversed range")
        XCTAssertNil(try summary("0 25 * * *"), "hour out of range")
        XCTAssertNil(try summary("not a cron line"))
    }

    func testSetVoiceVolumeUsesSetConfigField1() {
        // SetConfig.Request field 1 = volumePercentage; one setting per request.
        XCTAssertEqual(Payloads.setVoiceVolume(42), [0x08, 42])
        XCTAssertEqual(Payloads.setVoiceVolume(0), [0x08, 0x00], "0 must be sent: it's a oneof")
        XCTAssertEqual(Payloads.setVoiceVolume(150), [0x08, 100])
        XCTAssertEqual(Payloads.setVoiceVolume(-5), [0x08, 0x00])
        XCTAssertFalse(Research.isSafeQuery(Topic.setConfig), "the lab must never send config/set")
    }
}

final class RelocalizationTests: XCTestCase {
    private func status(_ build: (inout ProtoWriter) -> Void, _ top: (inout ProtoWriter) -> Void = { _ in }) throws -> BaseStatus {
        var w = ProtoWriter()
        w.float(2, 80)
        w.message(3, build)
        top(&w)
        return BaseStatus(try ProtoMessage(bytes: w.bytes))
    }

    func testRelocalizationFromTaskType() throws {
        XCTAssertTrue(try status { $0.varint(1, 13) }.isRelocalizing)
    }

    func testRelocalizationWhileHeadingToCharge() throws {
        // On the dock's status code, but chargingStatus = RELOCALIZATION.
        let s = try status { $0.varint(1, 10); $0.varint(11, 4) }
        XCTAssertTrue(s.isRelocalizing)
    }

    func testStationActivities() throws {
        XCTAssertEqual(try status { $0.varint(1, 10); $0.varint(12, 3) }.activity, "Washing mops")
        XCTAssertEqual(try status { $0.varint(1, 10); $0.varint(18, 1) }.activity, "Emptying the dustbin")
        XCTAssertNil(try status { $0.varint(1, 10) }.activity)
        XCTAssertEqual(try status { $0.varint(1, 25) }.activity, "Draining the dock base")
    }

    func testPlainDockedIsNotRelocalizing() throws {
        let s = try status({ $0.varint(1, 10) }, { $0.varint(47, 1) })
        XCTAssertFalse(s.isRelocalizing)
        XCTAssertEqual(s.isCharging, true)
        XCTAssertEqual(try status({ $0.varint(1, 10) }, { $0.varint(47, 4) }).isCharging, false)
    }
}

final class DockErrorFilterTests: XCTestCase {
    private let lost = RobotError(code: 0x02100017, level: 1, detail: "")
    private let stuck = RobotError(code: 0x01000001, level: 1, detail: "")

    func testDockSearchErrorWaitsForGrace() {
        var filter = DockErrorFilter()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(filter.filter([lost, stuck], docked: false, now: t0), [stuck])
        XCTAssertEqual(filter.filter([lost], docked: false, now: t0.addingTimeInterval(60)), [])
        XCTAssertEqual(filter.filter([lost], docked: false, now: t0.addingTimeInterval(90)), [lost])
    }

    func testDockSearchErrorIgnoredWhileDockedAndRestartsAfterClearing() {
        var filter = DockErrorFilter()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(filter.filter([lost], docked: false, now: t0), [])
        XCTAssertEqual(filter.filter([lost], docked: true, now: t0.addingTimeInterval(100)), [])
        // Off the dock again: the grace period starts over.
        XCTAssertEqual(filter.filter([lost], docked: false, now: t0.addingTimeInterval(110)), [])
        XCTAssertEqual(filter.filter([], docked: false, now: t0.addingTimeInterval(120)), [])
        XCTAssertEqual(filter.filter([lost], docked: false, now: t0.addingTimeInterval(130)), [])
        XCTAssertEqual(filter.filter([lost], docked: false, now: t0.addingTimeInterval(220)), [lost])
    }
}

final class StationStateTests: XCTestCase {
    func testStatesFollowTheAppEnums() {
        // A station with no bag fitted reports "uninstalled" all the time:
        // that must not raise "replace the bag" (seen on a Z10 Ultra).
        var station = StationState(cleanWaterTank: 1, sewageTank: 1, dustBox: 1, dustBag: nil, stationBag: 2)
        XCTAssertEqual(station.problems, [])
        XCTAssertEqual(station.readings.last, .init(part: "Station dust bag", state: "Not installed", alert: nil))

        // "Suggest replace" is informational: the Narwal app shows it as a
        // countdown, not a warning (seen on a Z10 Ultra, 12 days left).
        station.stationBag = 3
        XCTAssertEqual(station.problems, [])
        XCTAssertEqual(station.readings.last?.state, "Replace soon")
        XCTAssertEqual(station.readings.last?.needsCare, true, "still highlighted on the Station tab")
        station.stationBag = 4
        XCTAssertEqual(station.problems, ["Station dust bag fault"])
        station = StationState(cleanWaterTank: 2, sewageTank: 2, dustBox: 4, dustBag: 0, stationBag: 1)
        XCTAssertEqual(station.problems, ["Clean water tank is empty", "Dirty water tank is full or not in place",
                                          "Dust box needs cleaning"])
        XCTAssertEqual(station.readings.map(\.state), ["Empty", "Full or removed", "Needs cleaning", "Unknown", "Installed"])
        XCTAssertTrue(StationState().readings.isEmpty, "absent fields are unknown and not listed")
    }
}


final class MapEditTests: XCTestCase {
    private func map() -> RobotMap {
        var map = RobotMap(mapId: 9, width: 20, height: 10, resolution: 60,
                           rooms: [Room(id: 1, userName: "", roomType: 4, category: 0, instanceIndex: 0),
                                   Room(id: 2, userName: "Den", roomType: 0, category: 0, instanceIndex: 0)],
                           pixels: (0..<200).map { $0 % 20 < 10 ? 0x100 : 0x200 })
        map.noGoZones = [NoGoZone(id: 3, kind: .noMop, roomId: nil, coversWholeRoom: false,
                                  polygon: [MapPoint(x: 1, y: 1), MapPoint(x: 4, y: 1), MapPoint(x: 4, y: 4), MapPoint(x: 1, y: 4)])]
        map.virtualWalls = [VirtualWall(id: 5, start: MapPoint(x: 12, y: 2), end: MapPoint(x: 12, y: 8))]
        map.furniture = [Furniture(id: 7, type: 14, center: MapPoint(x: 16, y: 5), width: 4, height: 2, angle: 0)]
        return map
    }

    func testPayloadShapes() throws {
        let m = map()
        func op(_ edit: MapEdit) throws -> (Int, ProtoMessage) {
            let request = try ProtoMessage(bytes: Payloads.mapOperation(m, [edit]))
            XCTAssertEqual(request.int(1), 9)
            let payload = try XCTUnwrap(request.message(4))
            let field = try XCTUnwrap(payload.fields.first?.number)
            return (field, try XCTUnwrap(payload.message(field)))
        }
        let corners = RobotMap.corners(Payloads.Zone(x1: 2, y1: 6, x2: 8, y2: 9))
        var (field, body) = try op(.addNoGoZone(id: 4, kind: .noVacuumOrMop, corners: corners))
        XCTAssertEqual(field, 4)
        XCTAssertEqual(body.int(1), 1)
        XCTAssertEqual(body.message(2)?.messages(1).count, 4)
        XCTAssertEqual(body.message(2)?.messages(1).first?.float(1), 2)
        XCTAssertEqual(body.message(2)?.int(2), 3)

        (field, body) = try op(.deleteWall(m.virtualWalls[0]))
        XCTAssertEqual([field, body.int(1), body.message(2)?.int(1)], [13, 2, 5])

        (field, body) = try op(.renameRoom(m.rooms[0], to: "Pantry"))
        XCTAssertEqual(field, 3)
        XCTAssertEqual(body.message(1)?.string(3), "Pantry")
        XCTAssertEqual(body.message(1)?.int(1), 1)

        (field, body) = try op(.mergeRooms(2, 1))
        XCTAssertEqual([field, body.int(1), body.int(2), body.int(3)], [2, 2, 1, 1])

        (field, body) = try op(.splitRoom(1, from: MapPoint(x: 5, y: 0), to: MapPoint(x: 5, y: 10)))
        XCTAssertEqual(field, 1)
        XCTAssertEqual(body.message(2)?.float(2), 10)

        // Carpet grid in pixel frame: map coordinates minus origin.
        var shifted = m
        shifted.originX = -100
        shifted.originY = -50
        let request = try ProtoMessage(bytes: Payloads.mapOperation(shifted, [
            .addCarpet(id: 2, corners: [MapPoint(x: -90, y: -45)], gridInPixels: true, origin: (x: -100, y: -50))]))
        let carpet = try XCTUnwrap(request.message(4)?.message(6))
        XCTAssertEqual([carpet.int(1), carpet.int(3)], [2, 1])
        XCTAssertEqual([carpet.message(4)?.int(1), carpet.message(4)?.int(2)], [10, 5])

        (field, body) = try op(.retypeFurniture(m.furniture[0], to: 15))
        XCTAssertEqual([field, body.int(1), body.message(2)?.int(2)], [8, 1, 15])
        XCTAssertEqual(body.message(2)?.message(3)?.float(2), 4)
    }

    func testIsApplied() {
        let before = map()
        var after = before
        XCTAssertFalse(MapEdit.renameRoom(before.rooms[0], to: "Pantry").isApplied(before: before, after: after))
        after.rooms[0].userName = "Pantry"
        XCTAssertTrue(MapEdit.renameRoom(before.rooms[0], to: "Pantry").isApplied(before: before, after: after))
        after.virtualWalls = []
        XCTAssertTrue(MapEdit.deleteWall(before.virtualWalls[0]).isApplied(before: before, after: after))
        XCTAssertFalse(MapEdit.addWall(id: 6, from: MapPoint(x: 0, y: 0), to: MapPoint(x: 1, y: 1))
            .isApplied(before: before, after: after))
    }

    func testHitTesting() {
        let m = map()
        guard case .noGoZone(let zone)? = m.item(at: MapPoint(x: 2, y: 2)) else { return XCTFail("zone") }
        XCTAssertEqual(zone.id, 3)
        guard case .wall? = m.item(at: MapPoint(x: 13, y: 5)) else { return XCTFail("wall") }
        guard case .furniture(let item)? = m.item(at: MapPoint(x: 17, y: 5.5)) else { return XCTFail("furniture") }
        XCTAssertEqual(item.id, 7)
        guard case .room(let room)? = m.item(at: MapPoint(x: 6, y: 7)) else { return XCTFail("room") }
        XCTAssertEqual(room.id, 1)
    }
}

final class ScheduleWriteTests: XCTestCase {
    func testCron() {
        XCTAssertEqual(CleanSchedule.cron(hour: 9, minute: 30, weekdays: [1, 3, 5]), "30 9 * * 1,3,5")
        XCTAssertEqual(CleanSchedule.cron(hour: 7, minute: 0, weekdays: Set(0...6)), "0 7 * * *")
        XCTAssertEqual(CleanSchedule.cron(hour: 7, minute: 5, weekdays: [0], like: ["0 0 8 * * 1"]), "0 5 7 * * 0")
        var s = CleanSchedule(id: 1, cron: "0 30 9 * * 1-3", enabled: true, remindingTime: 0, planId: 2,
                              cleanMode: 2, isCustomPlan: true, name: "x")
        XCTAssertEqual(s.time?.hour, 9)
        XCTAssertEqual(s.time?.weekdays, [1, 2, 3])
        s.cron = "15 6 * * *"
        XCTAssertEqual(s.time?.weekdays.count, 7)
    }

    func testPlanAndSchedulePayloads() throws {
        let plan = try ProtoMessage(bytes: Payloads.setCleanPlan(
            mapId: 9, name: "Kitchen", rooms: [4, 2],
            settings: CleanSettings(workMode: .vacuum, fan: .strong, passes: 2)))
        let body = try XCTUnwrap(plan.message(1))
        XCTAssertEqual([body.int(2), body.int(3), body.int(4)], [9, 2, 1])
        XCTAssertEqual(body.string(5), "Kitchen")
        let options = body.messages(9)
        XCTAssertEqual(options.map { $0.int(1) }, [4, 2])
        XCTAssertEqual(options.first?.int(2), 1)
        XCTAssertEqual([options.first?.message(4)?.int(1), options.first?.message(4)?.int(2)], [3, 2])

        let whole = try ProtoMessage(bytes: Payloads.setCleanPlan(mapId: 9, name: "All", rooms: [], settings: CleanSettings()))
        XCTAssertEqual(whole.message(1)?.messages(9).first?.int(2), 3)
        XCTAssertEqual(whole.message(1)?.int(3), 4)

        let add = try ProtoMessage(bytes: Payloads.addSchedule(cron: "0 9 * * 1", enabled: true, planId: 12, cleanMode: 2, name: "Kitchen"))
        let param = try XCTUnwrap(add.message(1))
        XCTAssertEqual(param.message(1)?.string(1), "0 9 * * 1")
        XCTAssertEqual(param.message(1)?.int(3), 1)
        XCTAssertEqual(param.int(2), 12)

        XCTAssertEqual(Payloads.deleteSchedules([3, 4]), [0x08, 0x03, 0x08, 0x04])
        XCTAssertEqual(ScheduleReply.failure(try ProtoMessage(bytes: [0x0A, 0x02, 0x08, 0x03])), 3)
        XCTAssertNil(ScheduleReply.failure(try ProtoMessage(bytes: [0x0A, 0x02, 0x08, 0x01])))
    }
}

final class ObstacleTests: XCTestCase {
    func testObstaclesAndPhotoRequest() throws {
        var w = ProtoWriter()
        w.varint(1, 1)
        w.message(2) { map in
            map.varint(1, 7); map.varint(4, 10); map.varint(5, 10)
            map.message(32) { vision in
                vision.message(2) { obs in
                    obs.varint(1, 12)
                    obs.varint(2, 7)  // socks
                    obs.message(3) { box in
                        box.message(1) { c in c.float(1, 3.5); c.float(2, 4) }
                        box.float(2, 1.5); box.float(3, 1)
                    }
                    obs.varint(4, 99)
                }
            }
        }
        let map = try RobotMap(response: ProtoMessage(bytes: w.bytes))
        let obstacle = try XCTUnwrap(map.obstacles.first)
        XCTAssertEqual(obstacle.id, 12)
        XCTAssertEqual(obstacle.name, "Socks")
        XCTAssertEqual(obstacle.center, MapPoint(x: 3.5, y: 4))
        XCTAssertEqual(Payloads.obstaclePhoto(12), [0x08, 0x01, 0x10, 0x0C])

        var reply = ProtoWriter()
        reply.varint(1, 1)
        reply.bytesField(2, Array(repeating: 0xFF, count: 100))
        XCTAssertEqual(ObstaclePhoto.imageData(try ProtoMessage(bytes: reply.bytes))?.count, 100)
        XCTAssertNil(ObstaclePhoto.imageData(try ProtoMessage(bytes: [0x08, 0x01])))
    }
}

final class FloorCareTests: XCTestCase {
    private func message(_ build: (inout ProtoWriter) -> Void) throws -> ProtoMessage {
        var w = ProtoWriter()
        build(&w)
        return try ProtoMessage(bytes: w.bytes)
    }

    func testProtoEditsKeepUnknownFields() throws {
        let m = try message { $0.varint(1, 5); $0.string(3, "Den"); $0.varint(42, 7) }
        let edited = m.setting(4, int: 1).setting(path: [9, 2], int: 3)
        let back = try ProtoMessage(bytes: edited.encoded())
        XCTAssertEqual(back.int(1), 5)
        XCTAssertEqual(back.string(3), "Den")
        XCTAssertEqual(back.int(42), 7)
        XCTAssertEqual(back.int(4), 1)
        XCTAssertEqual(back.int(path: [9, 2]), 3)
        XCTAssertEqual(m.setting(1, int: 6).int(1), 6, "replaces, not appends")
        XCTAssertEqual(m.setting(1, int: 6).all(1).count, 1)
    }

    func testFloorMaintenanceAndCleanOptions() throws {
        XCTAssertEqual(Payloads.startFloorMaintenance(rooms: [3, 7]), [0x0A, 0x02, 0x03, 0x07])
        let plain = try ProtoMessage(bytes: Payloads.startClean(mapId: 9, rooms: [1]))
        XCTAssertNil(plain.message(1)?.message(3)?.int(1), "no Freo Mind unless asked")
        let both = try ProtoMessage(bytes: Payloads.startClean(
            mapId: 9, rooms: [1], options: CleanOptions(freoMind: true, maintainFloorsAfter: true)))
        let task = try XCTUnwrap(both.message(1))
        XCTAssertEqual(task.message(3)?.int(1), 1)
        XCTAssertEqual(task.message(3)?.int(5), 1)
        XCTAssertEqual(task.message(2)?.message(2)?.int(9), 1)
    }

    func testRoomEditsSendTheRoomsOwnInfo() throws {
        let info = try message { $0.varint(1, 4); $0.varint(2, 3); $0.string(3, "Den"); $0.varint(9, 12) }
        let room = Room(id: 4, userName: "Den", roomType: 3, category: 0, instanceIndex: 0, info: info)
        let (field, body) = MapEdit.setFloor(room, .wood, angle: 45).operation
        XCTAssertEqual(field, 3)
        let sent = try XCTUnwrap(try ProtoMessage(bytes: body).message(1))
        XCTAssertEqual([sent.int(1), sent.int(4), sent.int(5), sent.int(9)], [4, 1, 45, 12])
        XCTAssertEqual(sent.string(3), "Den")
        XCTAssertEqual(MapEdit.rotateMap(degrees: 90).operation.field, 5)
        let floor = Room(id: 1, userName: "", roomType: 0, category: 0, instanceIndex: 0,
                         info: try message { $0.varint(1, 1); $0.varint(4, 1); $0.varint(7, 1) })
        XCTAssertEqual(floor.floor, .wood)
        XCTAssertTrue(floor.isHeavilySoiled)
    }

    func testCartridgesFollowTheSharedSlot() {
        // Wood Floor Maintainer in the shared slot: the stain remover isn't
        // listed as missing.
        var station = StationState(detergent: 1, stainRemover: 1, stainRemoverPercent: nil,
                                   woodFloorSolution: 2, woodFloorSolutionPercent: 70)
        XCTAssertEqual(station.cartridges.map(\.name), ["Detergent", "Wood Floor Maintenance Solution"])
        XCTAssertEqual(station.cartridges.last?.percent, 70)
        XCTAssertTrue(station.hasWoodFloorSolution)
        XCTAssertFalse(station.hasStainRemover)
        station = StationState(detergent: 4, stainRemover: 2, stainRemoverPercent: 55, woodFloorSolution: 1)
        XCTAssertEqual(station.cartridges.map(\.name), ["Detergent", "Heavy-duty Stain Remover"])
        XCTAssertTrue(station.cartridges[0].needsCare)
        station = StationState(stainRemover: 1, woodFloorSolution: 1)
        XCTAssertEqual(station.cartridges.map(\.label), ["Not installed"], "an empty shared slot shows once")
    }

    func testBatteryHealthWithoutRatedCapacity() throws {
        // What the Z10 Ultra sends: no ratedCapacity (9), healthState 84.
        let z10 = try message { $0.varint(1, 4393); $0.varint(2, 131); $0.varint(4, 21); $0.varint(8, 84) }
        XCTAssertEqual(BatteryHealth(z10)?.capacityPercent, 84)
        XCTAssertEqual(BatteryHealth(z10)?.cycles, 131)
        let rated = try message { $0.varint(1, 4500); $0.varint(8, 84); $0.varint(9, 5000) }
        XCTAssertEqual(BatteryHealth(rated)?.capacityPercent, 90, "rated capacity wins when sent")
    }

    func testMapsAndNoStairs() throws {
        let response = try message { w in
            w.varint(1, 1)
            w.message(2) { $0.varint(1, 11); $0.varint(30, 1); $0.message(8) { _ in } }
            w.message(2) { $0.varint(1, 12); $0.string(28, "Upstairs") }
        }
        let maps = MapSummary.list(response)
        XCTAssertEqual(maps.map(\.title), ["Main Map", "Upstairs"])
        XCTAssertEqual(maps.map(\.hasDock), [true, false])

        let config = try message { w in
            w.varint(1, 1)
            w.message(2) { m in
                m.message(44) { c in
                    c.message(1) { $0.varint(1, 11); $0.varint(2, 0) }
                    c.message(1) { $0.varint(1, 12); $0.varint(2, 1) }
                }
            }
        }
        let settings = try XCTUnwrap(RobotSettings(response: config))
        XCTAssertFalse(settings.noStairs(mapId: 11))
        XCTAssertTrue(settings.noStairs(mapId: 12))
        let request = try ProtoMessage(bytes: Payloads.setNoStairs(true, mapId: 11, current: settings))
        let units = request.message(44)?.messages(1) ?? []
        XCTAssertEqual(units.map { $0.int(1) }, [11, 12])
        XCTAssertEqual(units.map { $0.int(2) }, [1, 1])
    }
}

