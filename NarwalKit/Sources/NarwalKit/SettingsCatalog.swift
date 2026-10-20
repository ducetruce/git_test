import Foundation

/// One robot setting: where config/get reports it and where config/set
/// takes it. The two messages number their fields differently
/// (docs/schema/messages.txt, GetConfig.Response.Config vs SetConfig.Request):
///
/// - get 1-3 = set 1-3
/// - get 4-13 = set 5-14 (set skips 4)
/// - get 14 (cleanCorner) has no setter
/// - get 15-44 = set 15-44
/// - get 46-47 = set 45-46 (no buildDateTime)
/// - get 49-56 = set 47-54 (no wakeVoiceWords)
public struct RobotSettingKey: Hashable, Sendable, Identifiable {
    public struct Option: Hashable, Sendable {
        public let value: Int
        public let label: String
    }

    public enum Group: String, CaseIterable, Sendable {
        case cleaning = "Cleaning"
        case carpets = "Carpets"
        case mopping = "Mopping & station"
        case sound = "Voice"
        case home = "Home & safety"
    }

    /// The schema's field name.
    public let id: String
    public let title: String
    public let group: Group
    public let getField: Int
    public let setField: Int
    /// Empty for an on/off setting.
    public let options: [Option]
    public var footnote: String?

    public var isToggle: Bool { options.isEmpty }

    /// Label for a value; 0 is the robot's "not set".
    public func label(for value: Int) -> String {
        if isToggle { return value != 0 ? "On" : "Off" }
        return options.first { $0.value == value }?.label ?? "Not set"
    }

    static func toggle(_ id: String, _ title: String, _ group: Group, get: Int, set: Int,
                       footnote: String? = nil) -> Self {
        Self(id: id, title: title, group: group, getField: get, setField: set, options: [], footnote: footnote)
    }

    static func choice(_ id: String, _ title: String, _ group: Group, get: Int, set: Int,
                       _ options: [(Int, String)], footnote: String? = nil) -> Self {
        Self(id: id, title: title, group: group, getField: get, setField: set,
             options: options.map { Option(value: $0.0, label: $0.1) }, footnote: footnote)
    }
}

extension RobotSettingKey {
    static let carpetHandling: [(Int, String)] = [(1, "Cross over"), (2, "Boost suction"), (3, "Ignore"), (4, "Avoid")]
    static let offOn: [(Int, String)] = [(1, "Off"), (2, "On")]

    /// Settings shown in the app, in display order within each group.
    /// Voice volume and quiet hours have their own controls.
    public static let all: [RobotSettingKey] = [
        .choice("avoidMode", "Obstacle avoidance", .cleaning, get: 34, set: 34,
                [(1, "Smart"), (2, "Extra careful"), (3, "Off")]),
        .choice("cornerCleanMode", "Edges and corners", .cleaning, get: 41, set: 41,
                [(1, "Extend the mop"), (2, "Turn into corners"), (3, "Off")]),
        .toggle("smartCleanDetectionEnabled", "Dirt detection", .cleaning, get: 11, set: 12),
        .toggle("enableDustSensorDirtyDetect", "Dust sensor", .cleaning, get: 43, set: 43,
                footnote: "Cleans longer where the sensor picks up more dust."),
        .toggle("smartDeepCleanEnabled", "Deep clean dirty spots", .cleaning, get: 23, set: 23),
        .toggle("boostCrossingModeEnabled", "Climb thresholds", .cleaning, get: 10, set: 11),
        .toggle("petMode", "Pet mode", .cleaning, get: 22, set: 22),

        .choice("carpetCleanOption", "Known carpets", .carpets, get: 15, set: 15, carpetHandling,
                footnote: "\"Avoid\" keeps the robot off carpets entirely, so it never mops them."),
        .choice("addCarpetCleanOption", "Newly found carpets", .carpets, get: 17, set: 17, carpetHandling),
        .toggle("cleanCarpetEnabled", "Clean carpets", .carpets, get: 8, set: 9),
        .choice("carpetCleanPriorityOption", "Order", .carpets, get: 46, set: 45,
                [(1, "Normal"), (2, "Carpets first")]),
        .choice("carpetDeepCleanOption", "Deep clean carpets", .carpets, get: 47, set: 46, offOn),
        .choice("carpetCleanSidebrushOption", "Side brush on carpets", .carpets, get: 53, set: 51, offOn),

        .choice("cleanMopFreq", "Mop washing", .mopping, get: 13, set: 14,
                [(1, "Less often"), (2, "Normal"), (3, "More often")]),
        .choice("dryMopStrength", "Mop drying", .mopping, get: 12, set: 13,
                [(1, "Quiet"), (2, "Strong"), (3, "Smart")]),
        .toggle("hotWaterWashEnabled", "Hot water wash", .mopping, get: 32, set: 32),
        .toggle("autoAddDetergentEnabled", "Add detergent", .mopping, get: 6, set: 7),
        .toggle("dustGatheringEnabled", "Auto-empty dustbin", .mopping, get: 27, set: 27),
        .toggle("smartDustGatheringEnabled", "Empty only when needed", .mopping, get: 28, set: 28),
        .toggle("quietDustGatheringEnabled", "Quiet emptying", .mopping, get: 30, set: 30),
        .toggle("dryRobotBagEnabled", "Dry the dust bag", .mopping, get: 31, set: 31),

        .toggle("speechControlEnabled", "Voice control", .sound, get: 36, set: 36),

        .toggle("childLockEnabled", "Child lock", .home, get: 7, set: 8,
                footnote: "Disables the buttons on the robot."),
        .toggle("preciousItemGuardEnabled", "Avoid valuables", .home, get: 50, set: 48,
                footnote: "Steers around small items like jewellery and cables."),
    ]
}
