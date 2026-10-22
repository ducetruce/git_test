import Foundation

/// Options for a clean beyond each room's settings.
public struct CleanOptions: Equatable, Hashable, Sendable, Codable {
    /// Freo Mind: the robot picks suction, water and passes itself
    /// (CleanParam 9 enableSmartMode, TaskOption 1).
    public var freoMind: Bool
    /// Wood floor maintenance after the clean (TaskOption 5
    /// enableMaintainAfterClean): Narwal's "Cleaning before maintenance".
    public var maintainFloorsAfter: Bool

    public init(freoMind: Bool = false, maintainFloorsAfter: Bool = false) {
        self.freoMind = freoMind
        self.maintainFloorsAfter = maintainFloorsAfter
    }
}

/// One saved map from map/get_all_reduced_maps.
public struct MapSummary: Equatable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let isMain: Bool
    public let hasDock: Bool
    public let roomCount: Int

    public var title: String {
        if !name.isEmpty { return name }
        return isMain ? "Main Map" : "Secondary map"
    }

    init(_ m: ProtoMessage) {
        id = m.int(1) ?? 0
        name = m.string(28) ?? ""
        isMain = (m.int(30) ?? 0) != 0
        hasDock = m.message(8) != nil
        roomCount = m.messages(12).count
    }

    public static func list(_ response: ProtoMessage) -> [MapSummary] {
        response.messages(2).map(MapSummary.init).filter { $0.id != 0 }
    }
}

/// common/upgrade/get_firmware_version: the robot, dock and camera
/// versions as text.
public struct FirmwareVersions: Equatable, Sendable {
    public let robot: String
    public let parts: [(name: String, version: String)]

    public static func == (a: Self, b: Self) -> Bool {
        a.robot == b.robot && a.parts.map(\.version) == b.parts.map(\.version)
    }

    public init?(_ m: ProtoMessage) {
        guard let text = m.string(2), !text.isEmpty else { return nil }
        robot = text
        func version(_ group: ProtoMessage?, _ field: Int) -> String? {
            group?.message(field)?.string(3).flatMap { $0.isEmpty ? nil : $0 }
        }
        var out: [(String, String)] = []
        if let v = version(m.message(4), 3) ?? version(m.message(4), 1) { out.append(("Dock", v)) }
        if let v = version(m.message(5), 1) ?? version(m.message(5), 2) { out.append(("Camera", v)) }
        parts = out
    }
}

/// info/battery_info.
public struct BatteryHealth: Equatable, Sendable {
    public let cycles: Int?
    /// Full-charge capacity as a share of the rated capacity, 0...100.
    public let capacityPercent: Int?
    public let temperature: Double?

    public init?(_ m: ProtoMessage) {
        cycles = m.int(2)
        if let full = m.int(1), let rated = m.int(9), rated > 0 {
            capacityPercent = min(100, Int((Double(full) / Double(rated) * 100).rounded()))
        } else {
            capacityPercent = nil
        }
        temperature = m.first(5).flatMap {
            if case .fixed64(let bits) = $0 { return Double(bitPattern: bits) }
            return nil
        }
        if cycles == nil && capacityPercent == nil && temperature == nil { return nil }
    }
}

/// task/get_continue_task: an interrupted clean the robot can pick up.
public struct ContinuableTask: Equatable, Sendable {
    public let stoppedAt: Date?
    public let finishedRooms: [Int]

    public init?(_ m: ProtoMessage) {
        guard let task = m.message(6), !task.messages(2).isEmpty else { return nil }
        stoppedAt = m.int(5).flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0) / ($0 > 10_000_000_000 ? 1000 : 1)) : nil }
        finishedRooms = m.varints(9)
    }
}

extension Payloads {
    /// StartMaintainFloor.Request {1 roomIds: packed int32}.
    public static func startFloorMaintenance(rooms: [Int]) -> [UInt8] {
        var w = ProtoWriter()
        w.bytesField(1, rooms.flatMap { ProtoWriter.encodeVarint(UInt64($0)) })
        return w.bytes
    }

    /// ResetConsumableInfo.Request {1 ConsumableInfoPayload {2 replaceItems}}.
    public static func resetConsumable(_ item: Int) -> [UInt8] {
        var w = ProtoWriter()
        w.message(1) { $0.varint(2, item) }
        return w.bytes
    }

    /// BuildMap.Request {1 buildType 0 explore, 3 mapStairType,
    /// 4 isRebuildCurrentMap}.
    public static func buildMap(rebuildCurrent: Bool, hasStairs: Bool) -> [UInt8] {
        var w = ProtoWriter()
        w.varint(1, 0)
        w.varint(2, hasStairs ? 1 : 0)
        w.varint(3, hasStairs ? 1 : 2)
        w.varint(4, rebuildCurrent ? 1 : 0)
        return w.bytes
    }

    /// SetConfig 44 mapConfiguration {1 configs: MapConfigUnit {1 mapId,
    /// 2 boostCrossingModeEnabled}}: Narwal's per-map "No stairs" switch.
    /// Units for other maps are kept as the robot sent them.
    public static func setNoStairs(_ on: Bool, mapId: Int, current: RobotSettings) -> [UInt8] {
        let units = current.config.message(44)?.messages(1) ?? []
        var w = ProtoWriter()
        w.message(44) { config in
            var found = false
            for unit in units {
                if unit.int(1) == mapId {
                    found = true
                    config.bytesField(1, unit.setting(2, int: on ? 1 : 0).encoded())
                } else {
                    config.bytesField(1, unit.encoded())
                }
            }
            if !found { config.message(1) { $0.varint(1, mapId); $0.varint(2, on ? 1 : 0) } }
        }
        return w.bytes
    }
}

extension RobotSettings {
    /// Narwal's "No stairs" for one map.
    public func noStairs(mapId: Int) -> Bool {
        config.message(44)?.messages(1).first { $0.int(1) == mapId }?.int(2) == 1
    }
}
