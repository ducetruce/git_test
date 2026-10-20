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

/// config/get response: {1: result, 2: GetConfig.Response.Config}. Field
/// numbers are from the app schema (docs/schema/messages.txt), checked on a
/// Z10 Ultra. Don't reuse them for config/set: SetConfig.Request numbers differ.
public struct RobotSettings: Equatable, Sendable {
    /// volumePercentage, 0...100. 0 is omitted on the wire, so absent means 0.
    public var voiceVolume: Int
    /// region.timeZone, an IANA name such as "Europe/Berlin".
    public var timeZone: String?
    public var doNotDisturb: DoNotDisturb?

    /// DisturbMode {1: enabled, 2: beginTime, 3: endTime}, times in seconds
    /// after local midnight.
    public struct DoNotDisturb: Equatable, Sendable {
        public var enabled: Bool
        public var begin: Int
        public var end: Int
    }

    public init?(response: ProtoMessage) {
        guard let settings = response.message(2) else { return nil }
        voiceVolume = settings.int(1) ?? 0
        timeZone = settings.message(3)?.string(1)
        doNotDisturb = settings.message(4).map {
            DoNotDisturb(enabled: ($0.int(1) ?? 0) != 0, begin: $0.int(2) ?? 0, end: $0.int(3) ?? 0)
        }
    }
}

public struct RobotError: Equatable, Sendable, Hashable {
    public var code: Int
    public var level: Int
    public var detail: String
}

/// Station, tank and bag states from robot_base_status, interpreted with the
/// app's own enums (docs/schema/enums.txt, RobotBaseStatus_*). Absent fields
/// are unknown, never "fine" or "problem".
public struct StationState: Equatable, Sendable {
    public var cleanWaterTank: Int?
    public var sewageTank: Int?
    public var dustBox: Int?
    public var dustBag: Int?
    public var stationBag: Int?
    public var dustBagHealth: Float?
    public var detergentRemaining: Int?

    public struct Reading: Equatable, Sendable {
        public let part: String
        public let state: String
        /// Alert text when this state needs the owner, else nil.
        public let alert: String?
    }

    /// One reading per field the robot sent, in display order.
    public var readings: [Reading] {
        var out: [Reading] = []
        // field 23, CleanWaterTankState
        if let v = cleanWaterTank {
            out.append(Self.reading("Clean water tank", v, [
                1: ("OK", nil), 2: ("Empty", "Clean water tank is empty"),
                3: ("Not in place", "Clean water tank is not in place"), 4: ("Fault", "Clean water tank fault"),
            ]))
        }
        // field 24, SewageTankState
        if let v = sewageTank {
            out.append(Self.reading("Dirty water tank", v, [
                1: ("OK", nil), 2: ("Full or removed", "Dirty water tank is full or not in place"),
                3: ("Fault", "Dirty water tank fault"),
            ]))
        }
        // field 20, DustBoxState
        if let v = dustBox {
            out.append(Self.reading("Dust box", v, [
                1: ("OK", nil), 2: ("Not in place", "Dust box is not in place"),
                3: ("Fault", "Dust box fault"), 4: ("Needs cleaning", "Dust box needs cleaning"),
            ]))
        }
        // field 21, DustBagState. "Not installed" isn't alerted: setups
        // without a bag report it permanently.
        if let v = dustBag {
            out.append(Self.reading("Dust bag", v, [
                1: ("OK", nil), 2: ("Not installed", nil),
                3: ("Replace soon", "Dust bag should be replaced"), 4: ("Fault", "Dust bag fault"),
            ]))
        }
        // field 39, StationBagStatus: 1 installed, 2 uninstalled,
        // 3 suggest replace, 4 abnormal. Same rule for "not installed".
        if let v = stationBag {
            out.append(Self.reading("Station dust bag", v, [
                1: ("Installed", nil), 2: ("Not installed", nil),
                3: ("Replace soon", "Station dust bag should be replaced"), 4: ("Fault", "Station dust bag fault"),
            ]))
        }
        return out
    }

    public var problems: [String] { readings.compactMap(\.alert) }

    private static func reading(_ part: String, _ value: Int, _ table: [Int: (String, String?)]) -> Reading {
        guard let entry = table[value] else {
            return Reading(part: part, state: value == 0 ? "Unknown" : "State \(value)", alert: nil)
        }
        return Reading(part: part, state: entry.0, alert: entry.1)
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

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
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
