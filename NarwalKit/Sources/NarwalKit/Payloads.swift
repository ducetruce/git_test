import Foundation

/// Settings applied to one room in a clean task.
public struct CleanSettings: Equatable, Hashable, Sendable, Codable {
    public var workMode: WorkMode
    public var fan: FanLevel
    public var water: MopHumidity
    public var mopStrength: MopStrength
    public var passes: Int
    public var route: CleaningRoute?

    public init(
        workMode: WorkMode = .vacuumAndMop,
        fan: FanLevel = .standard,
        water: MopHumidity = .normal,
        mopStrength: MopStrength = .normal,
        passes: Int = 1,
        route: CleaningRoute? = nil
    ) {
        self.workMode = workMode
        self.fan = fan
        self.water = water
        self.mopStrength = mopStrength
        self.passes = min(max(passes, 1), 3)
        self.route = route
    }
}

public enum Payloads {
    /// active_robot_publish: repeated TopicDuration{1: topic, 2: seconds}.
    public static func topicSubscription(duration: Int = NarwalDefaults.subscriptionDuration) -> [UInt8] {
        var w = ProtoWriter()
        for topic in Topic.broadcastTopics {
            w.message(1) { inner in
                inner.string(1, topic)
                inner.varint(2, duration)
            }
        }
        return w.bytes
    }

    public static func singleVarint(_ value: Int, field: Int = 1) -> [UInt8] {
        var w = ProtoWriter()
        w.varint(field, value)
        return w.bytes
    }

    public static func setFanLevel(_ level: FanLevel) -> [UInt8] {
        singleVarint(level.liveCommandValue)
    }

    public static func setMopHumidity(_ level: MopHumidity) -> [UInt8] {
        singleVarint(level.rawValue)
    }

    /// The app's taskType for a job whose rooms use different work modes.
    static let customTaskType = 6

    /// clean/start_clean request.
    ///
    ///     StartClean_Request{1: CleanTask{
    ///         1: mapId,
    ///         2: repeated CleanItem{1: ZoneOption{1: 1 (room), 2: roomId}, 2: CleanParam, 3: order},
    ///         3: TaskOption{},
    ///         5: taskType}}
    ///
    /// Rooms are cleaned in the order given.
    public static func startClean(
        mapId: Int,
        rooms: [Int],
        settings: CleanSettings = CleanSettings(),
        perRoom: [Int: CleanSettings] = [:]
    ) -> [UInt8] {
        let resolved = rooms.map { perRoom[$0] ?? settings }
        let modes = Set(resolved.map(\.workMode))
        let taskType = modes.count == 1 ? modes.first!.rawValue : customTaskType

        var w = ProtoWriter()
        w.message(1) { task in
            task.varint(1, mapId)
            for (index, room) in rooms.enumerated() {
                task.message(2) { item in
                    item.message(1) { zone in
                        zone.varint(1, 1)
                        zone.varint(2, room)
                    }
                    item.message(2) { param in
                        writeCleanParam(&param, resolved[index])
                    }
                    item.varint(3, index + 1)
                }
            }
            task.message(3) { _ in }
            task.varint(5, taskType)
        }
        return w.bytes
    }

    static func writeCleanParam(_ w: inout ProtoWriter, _ s: CleanSettings) {
        let (mode, passTags) = s.workMode.cleanParam
        w.varint(1, mode)
        w.varint(2, s.fan.rawValue)
        w.varint(3, s.mopStrength.rawValue)
        w.varint(4, s.water.rawValue)
        if let route = s.route {
            w.varint(8, route.rawValue)
        }
        for tag in passTags {
            w.varint(tag, s.passes)
        }
    }
}
