import Foundation

public struct DeviceInfo: Equatable, Sendable {
    public var productKey: String
    public var deviceId: String
    public var firmware: String

    /// get_device_info response: {1: productKey, 2: deviceId, 3: firmware}.
    /// Other replies also carry bytes in field 2 (a settings or status
    /// message), so the strings must look like identifiers, or a binary blob
    /// becomes the "device id" and every later topic is garbage.
    public init?(response: ProtoMessage) {
        guard let id = response.string(2)?.trimmed, Self.isPlausibleId(id) else { return nil }
        let key = response.string(1)?.trimmed ?? ""
        guard key.isEmpty || Self.isPlausibleId(key) else { return nil }
        productKey = key
        deviceId = id
        firmware = response.string(3)?.trimmed ?? ""
    }

    /// Short and plain: letters, digits, '-', '_', '.' and ':'.
    public static func isPlausibleId(_ s: String) -> Bool {
        (1...64).contains(s.utf8.count)
            && s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0)) }
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

        public init(enabled: Bool, begin: Int, end: Int) {
            self.enabled = enabled
            self.begin = begin
            self.end = end
        }
    }

    /// Every varint field of the config, by config/get field number.
    /// Absent means 0 (off / not set): proto3 omits zeros.
    public var values: [Int: Int] = [:]
    /// The whole config as received, so a nested setting can be written
    /// back with only one value changed.
    public var config: ProtoMessage = ProtoMessage(fields: [])

    /// A stored value by config/get path; absent reads as 0.
    public func int(path: [Int]) -> Int { config.int(path: path) ?? 0 }

    public func value(_ setting: RobotSetting) -> String { setting.label(in: self) }

    /// Replaces config/get's language (2) with config/language/get's.
    public mutating func setLanguage(_ language: Int) {
        values[2] = language
        config = config.setting(path: [2], int: language)
    }

    public init?(response: ProtoMessage) {
        guard let settings = response.message(2) else { return nil }
        config = settings
        for field in settings.fields {
            if case .varint(let v) = field.value { values[field.number] = Int(truncatingIfNeeded: v) }
        }
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
    /// 12 detergentState: 1 installed, 2 not installed, 3 empty, 4 running
    /// out, 5 not in use.
    public var detergent: Int?
    /// 40 heavyDetergentStatus (Heavy-duty Stain Remover): 1 not installed,
    /// 2 installed, 3 empty, 4 running out.
    public var stainRemover: Int?
    /// 41 heavyDetergentRemainPercent.
    public var stainRemoverPercent: Int?
    /// 33 multiLiquidStatus (Wood Floor Maintenance Solution, "curing
    /// agent"): 1 not installed, 2 installed, 3 empty, 4 running out.
    public var woodFloorSolution: Int?
    /// 38 curingAgentConsumptionPercent. Despite the name it's the amount
    /// left: a full cartridge reports 100 while the Narwal app shows "High".
    public var woodFloorSolutionPercent: Int?

    /// One dock cartridge as the Narwal app names it.
    public struct Cartridge: Equatable, Sendable, Identifiable {
        public enum Level: Equatable, Sendable { case ok, low, empty, notInstalled, notInUse }
        public let name: String
        public let level: Level
        /// Percent left, when the robot reports it.
        public let percent: Int?
        public var id: String { name }

        public var label: String {
            switch level {
            case .ok: return percent.map { "\($0)% left" } ?? "Installed"
            case .low: return percent.map { "Running low, \($0)% left" } ?? "Running low"
            case .empty: return "Empty"
            case .notInstalled: return "Not installed"
            case .notInUse: return "Not in use"
            }
        }

        public var needsCare: Bool { level == .low || level == .empty }
    }

    /// The detergent slot, then whatever is in the shared slot (the Wood
    /// Floor Maintenance Solution or the Heavy-duty Stain Remover, never
    /// both). A shared-slot cartridge that isn't installed is left out
    /// when the other one is, so it never reads as missing.
    public var cartridges: [Cartridge] {
        var out: [Cartridge] = []
        if let d = detergent {
            let table: [Int: Cartridge.Level] = [1: .ok, 2: .notInstalled, 3: .empty, 4: .low, 5: .notInUse]
            if let level = table[d] { out.append(Cartridge(name: "Detergent", level: level, percent: nil)) }
        }
        let shared: [Int: Cartridge.Level] = [1: .notInstalled, 2: .ok, 3: .empty, 4: .low]
        let wood = woodFloorSolution.flatMap { shared[$0] }.map {
            Cartridge(name: "Wood Floor Maintenance Solution", level: $0,
                      percent: woodFloorSolutionPercent.map { min(100, max(0, $0)) })
        }
        let stain = stainRemover.flatMap { shared[$0] }.map {
            Cartridge(name: "Heavy-duty Stain Remover", level: $0, percent: stainRemoverPercent)
        }
        let candidates = [wood, stain].compactMap { $0 }
        let installed = candidates.filter { $0.level != .notInstalled }
        out += installed.isEmpty ? Array(candidates.prefix(1)) : installed
        return out
    }

    public var hasWoodFloorSolution: Bool {
        cartridges.contains { $0.name.hasPrefix("Wood") && $0.level != .notInstalled && $0.level != .empty }
    }

    public var hasStainRemover: Bool {
        cartridges.contains { $0.name.hasPrefix("Heavy") && $0.level != .notInstalled }
    }

    public struct Reading: Equatable, Sendable {
        public let part: String
        public let state: String
        /// Alert text when this state needs the owner, else nil.
        public let alert: String?

        /// Worth highlighting even without an alert (e.g. "Replace soon").
        public var needsCare: Bool { alert != nil || state.hasPrefix("Replace") }
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
        // field 21, DustBagState. Neither "not installed" (setups without a
        // bag report it permanently) nor "suggest replace" is alerted: on a
        // Z10 Ultra the Narwal app shows the latter as a calm countdown
        // ("replacement countdown: 12 days"), not a warning.
        if let v = dustBag {
            out.append(Self.reading("Dust bag", v, [
                1: ("OK", nil), 2: ("Not installed", nil),
                3: ("Replace soon", nil), 4: ("Fault", "Dust bag fault"),
            ]))
        }
        // field 39, StationBagStatus: 1 installed, 2 uninstalled,
        // 3 suggest replace, 4 abnormal. Same rules as the dust bag.
        if let v = stationBag {
            out.append(Self.reading("Station dust bag", v, [
                1: ("Installed", nil), 2: ("Not installed", nil),
                3: ("Replace soon" + healthNote, nil), 4: ("Fault", "Station dust bag fault"),
            ]))
        }
        return out
    }

    public var problems: [String] { readings.compactMap(\.alert) }

    /// " (health 12%)" when the robot reports stationBagHealthScore (35).
    private var healthNote: String {
        guard let health = dustBagHealth, health.isFinite else { return "" }
        return " (health \(Int(health.rounded()))%)"
    }

    private static func reading(_ part: String, _ value: Int, _ table: [Int: (String, String?)]) -> Reading {
        guard let entry = table[value] else {
            return Reading(part: part, state: "Unknown", alert: nil)
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
    /// The robot is working out where it is (RELOCALIZATION in any of the
    /// task's sub-statuses). It may sit on or by the dock meanwhile.
    public var isRelocalizing: Bool
    /// RobotBaseStatus 47 chargingStatus / 11 stationContactType; nil when
    /// neither was sent.
    public var isCharging: Bool?
    /// What the robot is doing at the station or on its way there, in plain
    /// words (washing mops, emptying the dustbin...), from the task's
    /// sub-statuses. Nil when none applies.
    public var activity: String?
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
            dustBagHealth: m.float(35), detergent: m.int(12), stainRemover: m.int(40),
            stainRemoverPercent: m.int(41), woodFloorSolution: m.int(33), woodFloorSolutionPercent: m.int(38)
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
        isRelocalizing = Self.relocalizing(task)

        let f11 = m.int(11)
        let f47 = m.int(47)
        let presence = task?.int(3)
        let subState = task?.int(10)
        let washState = task?.int(12)
        let saysDocked = (f11.map { $0 >= 2 } ?? false)
            || f47 == 1 || f47 == 3
            || presence == 1 || presence == 6
            || subState == 1
            || (washState.map { $0 > 0 } ?? false)
        let saysOffDock = f11 == 1 || f47 == 2 || presence == 2 || subState == 2
        if f47 == 1 || f11 == 3 {
            isCharging = true
        } else if let f47, (2...5).contains(f47) {
            isCharging = false
        } else {
            isCharging = nil
        }
        if saysOffDock {
            isDocked = false
        } else if saysDocked {
            isDocked = true
        } else {
            isDocked = nil
        }
        // "Returning"/"parking" labels only off the dock: an older reading of
        // these fields treats some of the same values as docked.
        self.activity = Self.activity(task, enRoute: !(status.isOnDock || isDocked == true))
    }

    /// RobotTaskStatus field -> its RELOCALIZATION value (docs/schema/enums.txt,
    /// RobotTaskStatus_*Status). Field 1 is the task type, 13 = RELOCALIZATION.
    static let relocalizationValues: [Int: Int] = [
        1: 13, 4: 5, 5: 9, 6: 9, 7: 11, 8: 13, 9: 4, 10: 3, 11: 4,
        12: 5, 13: 3, 15: 4, 17: 13, 19: 6, 20: 8,
    ]

    /// RobotTaskStatus field -> value -> label (docs/schema/enums.txt):
    /// 12 washAndDryStatus, 18 dustGatheringStatus, 13 recallToWashStatus,
    /// 10 recallStatus, 11 chargingStatus. Checked in this order.
    static let activityLabels: [(field: Int, enRoute: Bool, labels: [Int: String])] = [
        (12, false, [3: "Washing mops", 4: "Drying mops", 6: "Drying the dust bag",
                     8: "Drying the station bag", 9: "Checking mop moisture"]),
        (18, false, [1: "Emptying the dustbin", 4: "Drying the station bag", 5: "Sanitising the station bag"]),
        (13, true, [1: "Going to wash mops", 2: "Parking to wash mops"]),
        (10, true, [1: "Returning to dock", 2: "Parking on the dock"]),
        (11, true, [1: "Going back to charge", 2: "Parking on the dock", 3: "Going back to recharge"]),
        (12, true, [1: "Going to the station", 2: "Parking on the dock"]),
    ]

    static func activity(_ task: ProtoMessage?, enRoute: Bool) -> String? {
        guard let task else { return nil }
        if task.int(1) == 25 { return "Draining the dock base" }  // TASK_TYPE_PUMP_TROUBLESHOOTING
        for entry in activityLabels where enRoute || !entry.enRoute {
            if let value = task.int(entry.field), let label = entry.labels[value] { return label }
        }
        return nil
    }

    static func relocalizing(_ task: ProtoMessage?) -> Bool {
        guard let task else { return false }
        return relocalizationValues.contains { field, value in task.int(field) == value }
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

/// Holds back "can't find the base station" errors, which the Z10 Ultra
/// raises while sitting in front of its dock and drops on its own (or as
/// soon as the Narwal app acknowledges it). They are ignored while the
/// robot says it's docked, and otherwise must last `dockSearchGrace`.
public struct DockErrorFilter: Sendable {
    public static let dockSearchCodes: Set<Int> = [0x02100015, 0x02100017, 0x02100018, 0x02110020]
    public static let dockSearchGrace: TimeInterval = 90

    private var firstSeen: [Int: Date] = [:]

    public init() {}

    public mutating func filter(_ errors: [RobotError], docked: Bool, now: Date = Date()) -> [RobotError] {
        let codes = Set(errors.map(\.code))
        firstSeen = firstSeen.filter { codes.contains($0.key) && !docked }
        return errors.filter { error in
            guard Self.dockSearchCodes.contains(error.code) else { return true }
            guard !docked else { return false }
            let since = firstSeen[error.code] ?? now
            firstSeen[error.code] = since
            return now.timeIntervalSince(since) >= Self.dockSearchGrace
        }
    }
}
