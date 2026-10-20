import Foundation

public enum NarwalDefaults {
    public static let port = 9002
    /// Freo Z10 Ultra (CX4). Other models are discovered from get_device_info.
    public static let z10UltraProductKey = "DrzDKQ0MU8"
    /// Bonjour service type the robots advertise.
    public static let bonjourType = "_narwal_sweeper._tcp"

    public static let commandTimeout: TimeInterval = 5
    /// A timed-out command keeps its place in the response order this much
    /// longer, so its late answer is dropped instead of misattributed.
    public static let lateResponseGrace: TimeInterval = 10
    /// Acks arrive within ~50 ms on an awake robot.
    public static let unawaitedAckWindow: TimeInterval = 1.5
    /// The robot closes the socket 60 s after the last command it received.
    public static let keepaliveInterval: TimeInterval = 15
    /// Broadcasts stop when the subscription expires, even on a live socket.
    /// This is what froze the live map in the reference integration (#73).
    public static let subscriptionDuration = 600
    public static let subscriptionRenewInterval: TimeInterval = 480
    /// Awake robots broadcast every ~1.5 s.
    public static let broadcastStaleAfter: TimeInterval = 15
    public static let displayMapDropoutAfter: TimeInterval = 30
}

/// Models known to speak the local protocol, with the product key the robot
/// expects in every topic. Sending another model's key gets a Z10 Ultra to
/// hang up, so the app never guesses.
public enum NarwalModel: String, CaseIterable, Identifiable, Sendable {
    case freoZ10Ultra = "DrzDKQ0MU8"
    case freoZ10Pro = "qV6BujoYLz"
    case flow = "QoEsI5qYXO"
    case flow2 = "QxMSPG6VSO"
    case freoX10Pro = "CNbforyZWI"
    case freoZUltra = "hEA7OEshlx"
    case freo20 = "fjhpiem4ba"
    case freo20Edge = "ulonq49mm1"
    case jx = "CGjuB6dzq7"

    public var id: String { rawValue }
    public var productKey: String { rawValue }

    public var name: String {
        switch self {
        case .freoZ10Ultra: return "Freo Z10 Ultra"
        case .freoZ10Pro: return "Freo Z10 Pro / Turbo"
        case .flow: return "Flow"
        case .flow2: return "Flow 2"
        case .freoX10Pro: return "Freo X10 Pro"
        case .freoZUltra: return "Freo Z Ultra (CX7)"
        case .freo20: return "Freo 20"
        case .freo20Edge: return "Freo 20 Edge"
        case .jx: return "JX"
        }
    }
}

public enum Topic {
    // Robot -> app broadcasts
    public static let workingStatus = "status/working_status"
    public static let robotBaseStatus = "status/robot_base_status"
    public static let upgradeStatus = "upgrade/upgrade_status"
    public static let downloadStatus = "status/download_status"
    public static let displayMap = "map/display_map"
    public static let timelineStatus = "status/time_line_status"

    public static let broadcastTopics = [
        robotBaseStatus, workingStatus, upgradeStatus, downloadStatus, displayMap, timelineStatus,
    ]

    // Common
    public static let yell = "common/yell"
    public static let reboot = "common/reboot"
    public static let getDeviceInfo = "common/get_device_info"
    public static let getFeatureList = "common/get_feature_list"
    public static let activeRobotPublish = "common/active_robot_publish"
    public static let notifyAppEvent = "common/notify_app_event"
    public static let appHeartbeat = "status/app_status_heartbeat"
    public static let getBaseStatus = "status/get_device_base_status"
    public static let getConsumableInfo = "consumable/get_consumable_info"
    public static let getConfig = "config/get"
    /// Takes SetConfig.Request, whose field numbers differ from config/get's.
    public static let setConfig = "config/set"
    public static let getCleanTimeLine = "info/get_clean_time_line"
    public static let getCleanSchedules = "schedule/clean_schedule/get"

    // Task control
    public static let pause = "task/pause"
    public static let resume = "task/resume"
    public static let forceEnd = "task/force_end"
    public static let cancel = "task/cancel"

    // Cleaning
    /// Runs the plan stored on the robot and IGNORES any rooms sent with it.
    /// Never use it for room cleaning; see `startClean`.
    public static let planStart = "clean/plan/start"
    public static let startClean = "clean/start_clean"
    public static let easyClean = "clean/easy_clean/start"
    public static let setFanLevel = "clean/set_fan_level"
    public static let setMopHumidity = "clean/set_mop_humidity"
    public static let currentCleanTask = "clean/current_clean_task/get"

    // Dock
    public static let recall = "supply/recall"
    public static let washMop = "supply/wash_mop"
    public static let dryMop = "supply/dry_mop"
    public static let dryDustBag = "supply/dry_dust_bag"
    public static let dryStationBag = "supply/dry_station_bag"
    public static let dustGathering = "supply/dust_gathering"
    public static let ambientLight = "supply/ambient_light_ctrl"

    // Map
    public static let getMap = "map/get_map"
    public static let getAllMaps = "map/get_all_reduced_maps"

    /// The robot never answers these, so they must not take a place in the
    /// response order or they would swallow the next real answer.
    public static let unacknowledged: Set<String> = [appHeartbeat]
}

public enum CommandResult: Int, Sendable {
    case success = 1
    case notApplicable = 2
    case conflict = 3
    case notReady = 4
    case applied = 6
}

/// Values observed live; they do not match the app's compiled enum.
public enum WorkingStatus: Int, Sendable, CaseIterable {
    case unknown = 0
    case standby = 1
    case dockedV2 = 2
    case cleaningV2 = 3
    case cleaning = 4
    case cleaningAlt = 5
    case remapping = 7
    case docked = 10
    case charged = 14
    case customCleaning = 17
    case taskCompleted = 19

    public var isActiveCleaning: Bool {
        switch self {
        case .cleaningV2, .cleaning, .cleaningAlt, .customCleaning, .remapping: return true
        default: return false
        }
    }

    public var isOnDock: Bool {
        switch self {
        case .dockedV2, .docked, .charged: return true
        default: return false
        }
    }
}

/// Suction tiers, named as in the Narwal app.
public enum FanLevel: Int, Sendable, CaseIterable, Codable {
    case quiet = 1
    case standard = 2
    case strong = 3
    case superPowerful = 4
    case ultraPowerful = 5

    public var label: String {
        switch self {
        case .quiet: return "Quiet"
        case .standard: return "Standard"
        case .strong: return "Strong"
        case .superPowerful: return "Super Powerful"
        case .ultraPowerful: return "Ultra Powerful"
        }
    }

    /// clean/set_fan_level has no tier 5; the app clamps it to 4.
    var liveCommandValue: Int { min(rawValue, 4) }
}

public enum MopHumidity: Int, Sendable, CaseIterable, Codable {
    case dry = 1
    case normal = 2
    case wet = 3

    public var label: String {
        switch self {
        case .dry: return "Dry"
        case .normal: return "Normal"
        case .wet: return "Wet"
        }
    }
}

public enum MopStrength: Int, Sendable, CaseIterable, Codable {
    case normal = 1
    case high = 2

    public var label: String { self == .normal ? "Normal" : "High" }
}

public enum CleaningRoute: Int, Sendable, CaseIterable, Codable {
    case standard = 1
    case meticulous = 2

    public var label: String { self == .standard ? "Standard" : "Meticulous" }
}

public enum WorkMode: Int, Sendable, CaseIterable, Codable {
    case vacuum = 1
    case mop = 2
    case vacuumThenMop = 3
    case vacuumAndMop = 4

    public var label: String {
        switch self {
        case .vacuum: return "Vacuum"
        case .mop: return "Mop"
        case .vacuumThenMop: return "Vacuum, then mop"
        case .vacuumAndMop: return "Vacuum & mop"
        }
    }

    /// CleanParam.mode and the CleanParam tags that carry the pass count.
    var cleanParam: (mode: Int, passTags: [Int]) {
        switch self {
        case .vacuum: return (2, [5])
        case .mop: return (3, [6])
        case .vacuumThenMop: return (5, [5, 6])
        case .vacuumAndMop: return (4, [7])
        }
    }
}

public enum AmbientLightMode: Int, Sendable, CaseIterable {
    case off = 0
    case nightLight = 1
    case winterWarmth = 2
    case purple = 3
}

/// RoomType names from the Narwal app's own strings.
public enum RoomType {
    public static let names: [Int: String] = [
        // Title case and "Hallway", as the Narwal app shows them.
        0: "Room", 1: "Primary Bedroom", 2: "Bedroom", 3: "Living Room",
        4: "Kitchen", 5: "Bathroom", 6: "Toilet", 7: "Balcony", 8: "Dining Room",
        9: "Closet", 10: "Hallway", 11: "Study", 12: "Kids' Room",
        13: "Entertainment Room", 14: "Storage Room", 15: "Other",
    ]
}
