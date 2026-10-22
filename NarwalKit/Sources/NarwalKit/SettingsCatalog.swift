import Foundation

/// One robot setting as the Narwal app shows it: a title and a list of
/// choices (an on/off setting is two choices). Each choice is the values it
/// stores in the robot's config, so one choice can span several stored
/// fields (Auto-empty Frequency is two switches on the robot) or a field
/// inside a nested message (Freo Mind's suction is `smartCleanParam`
/// .fanLevelStrategy).
///
/// Paths are config/get field numbers (docs/schema/messages.txt,
/// GetConfig.Response.Config). config/set numbers its top-level fields
/// differently; `RobotSetting.setField(forGet:)` maps them:
///
/// - get 1-3 = set 1-3
/// - get 4-13 = set 5-14 (set skips 4)
/// - get 14 (cleanCorner) has no setter
/// - get 15-44 = set 15-44
/// - get 46-47 = set 45-46 (no buildDateTime)
/// - get 49-56 = set 47-54 (no wakeVoiceWords)
public struct RobotSetting: Hashable, Sendable, Identifiable {
    /// One stored value: `path` starts at a config/get field and may go
    /// into nested messages.
    public struct Write: Hashable, Sendable {
        public let path: [Int]
        public let value: Int

        public init(_ path: [Int], _ value: Int) {
            self.path = path
            self.value = value
        }
    }

    public struct Choice: Hashable, Sendable {
        public let label: String
        public var detail: String?
        /// The choice is selected when every one of these reads back as
        /// written (absent fields read as 0).
        public let writes: [Write]

        public init(_ label: String, detail: String? = nil, _ writes: [Write]) {
            self.label = label
            self.detail = detail
            self.writes = writes
        }
    }

    public enum Menu: String, CaseIterable, Sendable {
        case freoMind = "Freo Mind Mode"
        case floorCleaning = "Floor Cleaning"
        case carpet = "Carpet Detection and Cleaning"
        case general = "General"
        case dock = "Dock"
        case pet = "Pet-friendly Mode"
        case ai = "AI Recognition"
        case voice = "Navo Voice Assistant"
        /// Stored on the robot but not shown by the Narwal app for the
        /// Freo Z10 Ultra. Listed in diagnostics only.
        case hidden = "Not in the Narwal app"
    }

    public let id: String
    public let title: String
    public let menu: Menu
    public let choices: [Choice]
    public var footnote: String?

    /// True for a plain on/off switch (choices are Off, On).
    public var isToggle: Bool { choices.count == 2 && choices[0].label == "Off" && choices[1].label == "On" }

    /// The selected choice, or nil when the stored values match none of
    /// them (a value this app doesn't know).
    public func choice(in settings: RobotSettings) -> Choice? {
        choices.first { choice in choice.writes.allSatisfy { settings.int(path: $0.path) == $0.value } }
    }

    public func label(in settings: RobotSettings) -> String {
        choice(in: settings)?.label ?? "Not set"
    }

    /// config/set number for a config/get top-level field.
    public static func setField(forGet get: Int) -> Int? {
        switch get {
        case 1...3: return get
        case 4...13: return get + 1
        case 15...44: return get
        case 46...47: return get - 1
        case 49...56: return get - 2
        default: return nil
        }
    }

    /// The config/set requests that store `choice`, one per top-level
    /// field (config/set takes one field per request). A nested value is
    /// written by sending the robot's own current message with only that
    /// value changed.
    public static func requests(for choice: Choice, current: RobotSettings) -> [[UInt8]] {
        var order: [Int] = []
        var byField: [Int: [Write]] = [:]
        for write in choice.writes {
            guard let top = write.path.first else { continue }
            if byField[top] == nil { order.append(top) }
            byField[top, default: []].append(write)
        }
        return order.compactMap { top in
            guard let set = setField(forGet: top), let writes = byField[top] else { return nil }
            var w = ProtoWriter()
            if writes.count == 1, writes[0].path.count == 1 {
                w.varint(set, writes[0].value)
            } else {
                var message = current.config.message(top) ?? ProtoMessage(fields: [])
                for write in writes { message = message.setting(path: Array(write.path.dropFirst()), int: write.value) }
                w.bytesField(set, message.encoded())
            }
            return w.bytes
        }
    }

    static func toggle(_ id: String, _ title: String, _ menu: Menu, _ field: Int, footnote: String? = nil) -> Self {
        Self(id: id, title: title, menu: menu,
             choices: [Choice("Off", [Write([field], 0)]), Choice("On", [Write([field], 1)])], footnote: footnote)
    }

    /// A Freo Mind strategy: Smart leaves it to the robot, anything else
    /// is `isCustomizeMode` with a value.
    static func strategy(_ id: String, _ title: String, _ field: Int, _ levels: [(String, Int)], footnote: String) -> Self {
        Self(id: id, title: title, menu: .freoMind,
             choices: [Choice("Smart", [Write([29, field, 1], 0)])]
                + levels.map { Choice($0.0, [Write([29, field, 1], 1), Write([29, field, 2], $0.1)]) },
             footnote: footnote)
    }
}

extension RobotSetting {
    /// Settings in the Narwal app's order and wording for the Freo Z10 Ultra.
    /// Voice volume, Do Not Disturb hours and "No stairs" have their own
    /// controls.
    public static let all: [RobotSetting] = [
        // Freo Mind Mode
        .toggle("massiveDirtyDeepCleanEnable", "Intensive Cleaning for Large Soiled Areas", .freoMind, 33,
                footnote: "When the robot finds a large soiled area during Freo Mind cleaning, it runs a separate intensive clean there."),
        RobotSetting(id: "maxRemopCount", title: "Re-mopping Cycle Limit", menu: .freoMind, choices: [
            Choice("AI", [Write([29, 1, 1], 0)]),
            Choice("3", [Write([29, 1, 1], 1), Write([29, 1, 2], 3)]),
            Choice("2", [Write([29, 1, 1], 1), Write([29, 1, 2], 2)]),
            Choice("1", [Write([29, 1, 1], 1), Write([29, 1, 2], 1)]),
        ]),
        RobotSetting(id: "heavyDirtyClean", title: "Use Heavy-duty Floor Stain Remover", menu: .freoMind, choices: [
            Choice("Off", [Write([29, 7, 1], 0)]),
            Choice("Every time", [Write([29, 7, 1], 1), Write([29, 7, 2], 1)]),
        ], footnote: "Adds heavy-duty stain remover while washing the mops when Freo Mind finds a heavily soiled room. Needs the stain remover in the dock's shared slot."),
        .strategy("fanLevelStrategy", "Suction", 4,
                  [("Quiet", 1), ("Standard", 2), ("Strong", 3), ("Super Powerful", 4)],
                  footnote: "Smart adjusts suction to how dirty each area is."),
        .strategy("mopHumidityStrategy", "Mopping Humidity", 5,
                  [("Dry", 1), ("Normal", 2), ("Wet", 3)],
                  footnote: "Smart adjusts the water to dirt, air humidity and the floor."),
        .strategy("overlapLevelStrategy", "Coverage Precision", 2,
                  [("Normal", 1), ("Dense", 2)],
                  footnote: "Smart adjusts how closely the robot's passes overlap."),

        // Floor Cleaning
        RobotSetting(id: "rewashStrategy", title: "Rewash Strategy", menu: .floorCleaning, choices: [
            Choice("Every 86 ft²", [Write([18, 1], 1), Write([18, 2], 3)]),
            Choice("Every 108 ft²", detail: "Default", [Write([18, 1], 1), Write([18, 2], 2)]),
            Choice("Every 129 ft²", [Write([18, 1], 1), Write([18, 2], 1)]),
            Choice("Wash mops by room", detail: "Washes after each room, so dirt isn't carried between rooms.", [Write([18, 1], 2)]),
        ], footnote: "Applies in Custom mode. Freo Mind washes after every room."),
        RobotSetting(id: "cornerCleanMode", title: "Intensive Corner Cleaning", menu: .floorCleaning, choices: [
            Choice("Mop Extension", detail: "Extends the mop into corners.", [Write([41], 1)]),
            Choice("Wiggle", detail: "Wiggles into corners.", [Write([41], 2)]),
            Choice("Close", [Write([41], 3)]),
        ]),
        .toggle("enableDustSensorDirtyDetect", "Intensive cleaning for granular debris", .floorCleaning, 43,
                footnote: "When the robot picks up granular debris, it adjusts how it cleans that spot."),

        // Carpet
        RobotSetting(id: "addCarpetCleanOption", title: "Cleaning mode for newly detected carpets", menu: .carpet, choices: [
            Choice("Clean", detail: "For low-pile carpets and mats. Raises suction.", [Write([17], 2)]),
            Choice("Avoid", [Write([17], 4)]),
            Choice("Cross", [Write([17], 1)]),
            Choice("Vacuum & Mop", [Write([17], 3)]),
        ]),

        // General
        .toggle("highAltitudeModeEnabled", "Plateau Mode", .general, 5,
                footnote: "Raises fan power at high altitude. For homes above 2,000 m."),
        .toggle("childLockEnabled", "Child Lock", .general, 7,
                footnote: "Locks the buttons on the dock and the robot."),
        .toggle("automaticPoweroffWhenDischarging", "Auto Power-Off", .general, 37,
                footnote: "Turns the robot off after 5 hours idle when it isn't charging."),

        // Dock
        .toggle("hotWaterWashEnabled", "Smart Mop Wash with Hot Water", .dock, 32,
                footnote: "Heats the wash water to suit the dirt the robot found."),
        RobotSetting(id: "dryMopStrength", title: "Mop Drying Intensity", menu: .dock, choices: [
            Choice("Smart", [Write([12], 3)]),
            Choice("Quiet", [Write([12], 1)]),
            Choice("Strong", [Write([12], 2)]),
        ]),
        RobotSetting(id: "autoEmptyFrequency", title: "Auto-empty Frequency", menu: .dock, choices: [
            Choice("Smart", detail: "Empties based on the area cleaned and how full the bin is.", [Write([27], 1), Write([28], 1)]),
            Choice("Frequent", detail: "For pets or lots of carpet. Empties more often while cleaning.", [Write([27], 1), Write([28], 0)]),
            Choice("Close", detail: "No auto-empty. Empty from the Station screen when needed.", [Write([27], 0)]),
        ]),
        RobotSetting(id: "autoEmptyLevel", title: "Auto-Empty Level", menu: .dock, choices: [
            Choice("Quiet", detail: "For routine cleaning.", [Write([30], 1)]),
            Choice("Strong", detail: "Stronger suction, for more granular debris.", [Write([30], 0)]),
        ]),
        .toggle("dryRobotBagEnabled", "Dust Bin / Dust Bag with Auto Disinfection", .dock, 31,
                footnote: "After a clean that includes vacuuming, air-dries the dust bin and bag."),
        RobotSetting(id: "stationCleanMode", title: "Default Cleaning Mode for Dock", menu: .dock, choices: [
            Choice("Vacuum and mop", [Write([21], 4)]),
            Choice("Vacuum then mop", [Write([21], 5)]),
            Choice("Vacuum", [Write([21], 2)]),
            Choice("Mop", [Write([21], 3)]),
        ], footnote: "What the dock's Start button cleans: the whole house in this mode."),
        .toggle("autoAddDetergentEnabled", "Automatically Add Detergent", .dock, 6,
                footnote: "Adds cleaning solution while the robot is mopping."),

        // Pet-friendly Mode
        .toggle("petMode", "Pet-friendly Mode", .pet, 22,
                footnote: "Watches more carefully for pet waste and avoids it. Some areas may be missed."),

        // AI Recognition
        RobotSetting(id: "avoidMode", title: "Obstacle Avoidance Strategy", menu: .ai, choices: [
            Choice("Smart", detail: "Keeps an ideal distance from obstacles and walls.", [Write([34], 1)]),
            Choice("Safety", detail: "Keeps further away to avoid bumps. May miss some areas.", [Write([34], 2)]),
        ]),

        // Navo Voice Assistant
        .toggle("speechControlEnabled", "Navo Voice Assistant", .voice, 36,
                footnote: "Wake the robot with \"Hey, Nawa\", then speak a command."),
        RobotSetting(id: "language", title: "Robot Language", menu: .voice, choices: [
            Choice("English", [Write([2], 3)]),
            Choice("Español", [Write([2], 10)]),
            Choice("Français", [Write([2], 9)]),
            Choice("Deutsch", [Write([2], 6)]),
            Choice("Italiano", [Write([2], 8)]),
            Choice("Polski", [Write([2], 12)]),
            Choice("Русский", [Write([2], 11)]),
            Choice("Türkçe", [Write([2], 13)]),
            Choice("עברית", [Write([2], 7)]),
            Choice("日本語", [Write([2], 5)]),
            Choice("한국어", [Write([2], 4)]),
            Choice("简体中文", [Write([2], 1)]),
            Choice("繁體中文", [Write([2], 2)]),
            Choice("ไทย", [Write([2], 14)]),
            Choice("Tiếng Việt", [Write([2], 15)]),
        ], footnote: "The robot needs that language's voice installed. If it isn't, the Narwal app downloads it."),

        // Stored, but not in the Narwal app for this robot.
        .toggle("smartCleanDetectionEnabled", "Dirt detection", .hidden, 11),
        .toggle("smartDeepCleanEnabled", "Deep clean dirty spots", .hidden, 23),
        .toggle("boostCrossingModeEnabled", "Climb thresholds (all maps)", .hidden, 10),
        .toggle("dustGatheringEnabled", "Auto-empty", .hidden, 27),
        RobotSetting(id: "carpetCleanOption", title: "Known carpets", menu: .hidden, choices: [
            Choice("Clean", [Write([15], 2)]), Choice("Avoid", [Write([15], 4)]),
            Choice("Cross", [Write([15], 1)]), Choice("Vacuum & Mop", [Write([15], 3)]),
        ]),
        RobotSetting(id: "carpetCleanPriorityOption", title: "Carpets first", menu: .hidden, choices: [
            Choice("Off", [Write([46], 1)]), Choice("On", [Write([46], 2)]),
        ]),
        RobotSetting(id: "carpetDeepCleanOption", title: "Deep clean carpets", menu: .hidden, choices: [
            Choice("Off", [Write([47], 1)]), Choice("On", [Write([47], 2)]),
        ]),
        RobotSetting(id: "carpetCleanSidebrushOption", title: "Side brush on carpets", menu: .hidden, choices: [
            Choice("Off", [Write([53], 1)]), Choice("On", [Write([53], 2)]),
        ]),
        .toggle("preciousItemGuardEnabled", "Avoid valuables", .hidden, 50),
        .toggle("allThingsRecognitionEnabled", "Recognise all objects", .hidden, 49),
        .toggle("showVisionImageEnabled", "Keep obstacle photos", .hidden, 24),
        .toggle("aiVoiceSoundEffectEnabled", "AI voice sound effects", .hidden, 39),
        .toggle("humanPetBlockRepenishCleanEnabled", "Re-clean spots blocked by people or pets", .hidden, 55),
        .toggle("trackForwardAssistEnabled", "Track forward assist", .hidden, 56),
        .toggle("moistureProofPadProtectEnabled", "Moisture-proof pad protection", .hidden, 26),
        RobotSetting(id: "cleanMopFreq", title: "Mop washing (older setting)", menu: .hidden, choices: [
            Choice("Every 129 ft²", [Write([13], 1)]), Choice("Every 108 ft²", [Write([13], 2)]),
            Choice("Every 86 ft²", [Write([13], 3)]),
        ]),
    ]

    public static func named(_ id: String) -> RobotSetting? { all.first { $0.id == id } }

    public static func menu(_ menu: Menu) -> [RobotSetting] { all.filter { $0.menu == menu } }
}
