import Foundation

public struct DeviceInfo: Equatable, Sendable {
    public var productKey: String
    public var deviceId: String
    public var firmware: String

    /// get_device_info response: {1: productKey, 2: deviceId, 3: firmware}.
    public init?(response: ProtoMessage) {
        guard let id = response.string(2)?.trimmed, !id.isEmpty else { return nil }
        productKey = response.string(1)?.trimmed ?? ""
        deviceId = id
        firmware = response.string(3)?.trimmed ?? ""
    }
}

public struct RobotError: Equatable, Sendable, Hashable {
    public var code: Int
    public var level: Int
    public var detail: String
}

/// Station/tank states from robot_base_status. Values 2-4 mean attention
/// needed (sewage: 2-3). Absent fields are unknown, never "fine".
public struct StationState: Equatable, Sendable {
    public var cleanWaterTank: Int?
    public var sewageTank: Int?
    public var dustBox: Int?
    public var dustBag: Int?
    public var stationBag: Int?
    public var dustBagHealth: Float?
    public var detergentRemaining: Int?

    public var problems: [String] {
        var out: [String] = []
        if let v = cleanWaterTank, (2...4).contains(v) { out.append("Clean water tank needs attention") }
        if let v = sewageTank, (2...3).contains(v) { out.append("Dirty water tank needs emptying") }
        if let v = dustBox, (2...4).contains(v) { out.append("Dust box needs attention") }
        if let v = dustBag, (2...4).contains(v) { out.append("Dust bag needs attention") }
        if let v = stationBag, (2...4).contains(v) { out.append("Station bag needs replacing") }
        return out
    }
}

/// status/robot_base_status (broadcast) or the field-2 payload of
/// status/get_device_base_status (response).
public struct BaseStatus: Equatable, Sendable {
    public var battery: Int?
    public var rawWorkingStatus: Int?
    public var workingStatus: WorkingStatus
    public var isPaused: Bool
    public var isReturning: Bool
    /// nil when this message carried no dock evidence either way.
    public var isDocked: Bool?
    public var fanLevel: FanLevel?
    public var mopHumidity: MopHumidity?
    public var errors: [RobotError]
    public var station: StationState
    public var dockLightMode: Int?

    public init(_ m: ProtoMessage) {
        battery = m.float(2).flatMap { $0.isFinite ? Int($0.rounded()) : nil }
        fanLevel = m.int(26).flatMap(FanLevel.init(rawValue:))
        mopHumidity = m.int(29).flatMap(MopHumidity.init(rawValue:))
        dockLightMode = m.int(50)

        errors = m.messages(1).compactMap { e in
            guard let code = e.int(1), code != 0 else { return nil }
            return RobotError(code: code, level: e.int(2) ?? 0, detail: e.string(3) ?? "")
        }

        station = StationState(
            cleanWaterTank: m.int(23), sewageTank: m.int(24), dustBox: m.int(20),
            dustBag: m.int(21), stationBag: m.int(39),
            dustBagHealth: m.float(35), detergentRemaining: m.int(41)
        )

        let task = m.message(3)
        let raw = task?.int(1)
        rawWorkingStatus = raw
        var status = raw.flatMap(WorkingStatus.init(rawValue:)) ?? .unknown
        // Newer firmware keeps reporting 2 while cleaning off the dock and
        // distinguishes it only by sub-field 4 = 3.
        if status == .dockedV2, task?.int(4) == 3 {
            status = .cleaningV2
        }
        workingStatus = status
        isPaused = task?.int(2) == 1
        isReturning = task?.int(7) == 1

        let f11 = m.int(11)
        let f47 = m.int(47)
        let presence = task?.int(3)
        let subState = task?.int(10)
        let activity = task?.int(12)
        let saysDocked = (f11.map { $0 >= 2 } ?? false)
            || f47 == 1 || f47 == 3
            || presence == 1 || presence == 6
            || subState == 1
            || (activity.map { $0 > 0 } ?? false)
        let saysOffDock = f11 == 1 || f47 == 2 || presence == 2 || subState == 2
        if saysOffDock {
            isDocked = false
        } else if saysDocked {
            isDocked = true
        } else {
            isDocked = nil
        }
    }
}

/// status/working_status: metrics for the running task, not state.
public struct WorkingProgress: Equatable, Sendable {
    public var progressPercent: Int?
    public var areaSquareMeters: Float?
    public var elapsedSeconds: Int?
    public var remainingSeconds: Int?
    public var currentRoomId: Int?

    public init(_ m: ProtoMessage) {
        if let p = m.float(1), p.isFinite {
            if (0...1).contains(p) {
                progressPercent = Int((p * 100).rounded())
            } else if (0...100).contains(p) {
                progressPercent = Int(p.rounded())
            }
        }
        areaSquareMeters = m.float(2).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        elapsedSeconds = m.int(3)
        remainingSeconds = m.int(4)
        if let room = m.message(6) ?? m.message(8) {
            currentRoomId = room.int(1)
        } else {
            currentRoomId = m.int(6)
        }
        if currentRoomId == 0 { currentRoomId = nil }
    }
}

public struct MapPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
}

/// map/display_map: live robot pose, ~every 1.5 s while subscribed.
public struct LivePose: Equatable, Sendable {
    public var position: MapPoint
    /// Radians, counter-clockwise from +x in map coordinates.
    public var heading: Double
    public var timestampMs: Int?

    public init?(_ m: ProtoMessage) {
        guard let pose = m.message(1), let pos = pose.message(1),
              let x = pos.float(1), let y = pos.float(2), x.isFinite, y.isFinite,
              !(x == 0 && y == 0)
        else { return nil }
        position = MapPoint(x: Double(x), y: Double(y))
        heading = pose.float(2).flatMap { $0.isFinite ? Double($0) : nil } ?? 0
        timestampMs = m.int(10)
    }
}

/// consumable/get_consumable_info: which parts want attention.
public struct ConsumableAlerts: Equatable, Sendable {
    public var maintain: [Int]
    public var replace: [Int]

    public init(response: ProtoMessage) {
        let payload = response.message(1)
        maintain = payload?.varints(1) ?? []
        replace = payload?.varints(2) ?? []
    }

    public static let maintainNames: [Int: String] = [
        1: "Dust box", 2: "Dust filter", 4: "Wash ribs", 6: "Universal wheel",
        7: "Cliff sensor", 8: "Side distance sensor", 9: "Water tank sponge",
        10: "Anti-winding brush", 11: "Smart module sponge", 20: "Dust container",
    ]

    public static let replaceNames: [Int: String] = [
        1: "Dust filter", 2: "Mop", 3: "Side brush", 4: "Clean water filter",
        5: "Roller brush", 6: "Detergent", 7: "Smart module filter", 8: "Dust bag",
        20: "Station bag", 21: "Silver ions", 22: "Curing agent",
        23: "Heavy detergent", 24: "Inner dust box",
    ]

    public var maintainLabels: [String] {
        maintain.map { Self.maintainNames[$0] ?? "Part #\($0)" }
    }

    public var replaceLabels: [String] {
        replace.map { Self.replaceNames[$0] ?? "Part #\($0)" }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
