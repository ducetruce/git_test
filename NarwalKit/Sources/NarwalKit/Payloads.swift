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

    /// config/set with SetConfig.Request field 1, `volumePercentage`.
    /// SetConfig.Request is a oneof (one setting per request), so 0 is still
    /// sent explicitly.
    public static func setVoiceVolume(_ percent: Int) -> [UInt8] {
        singleVarint(min(max(percent, 0), 100), field: 1)
    }

    /// config/set for one catalog setting. Off (0) is sent explicitly, or
    /// the request would be empty.
    public static func setConfig(_ key: RobotSettingKey, _ value: Int) -> [UInt8] {
        singleVarint(value, field: key.setField)
    }

    /// config/set field 5, DisturbMode {1 enabled, 2 beginTime, 3 endTime},
    /// times in seconds after midnight.
    public static func setDoNotDisturb(_ dnd: RobotSettings.DoNotDisturb) -> [UInt8] {
        var w = ProtoWriter()
        w.message(5) { m in
            m.varint(1, dnd.enabled ? 1 : 0)
            m.varint(2, dnd.begin)
            m.varint(3, dnd.end)
        }
        return w.bytes
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

    /// A rectangle in robot world coordinates (map grid + origin; the same
    /// units as the live robot position). Corner order doesn't matter.
    public struct Zone: Equatable, Hashable, Sendable, Codable {
        public var x1: Int, y1: Int, x2: Int, y2: Int

        public init(x1: Int, y1: Int, x2: Int, y2: Int) {
            self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
        }

        var minX: Int { min(x1, x2) }
        var maxX: Int { max(x1, x2) }
        var minY: Int { min(y1, y2) }
        var maxY: Int { max(y1, y2) }
    }

    /// clean/start_clean for drawn rectangles. Shape copied from the task the
    /// robot itself reports after an app zone clean (validated on a Flow,
    /// fw v01.08.03.07):
    ///
    ///     CleanItem{1: ZoneOption{1: 2 (zone), 2: index, 3: [4 corners], 4: [coverage path]},
    ///               2: CleanParam{1: mode, 2: fan, 3: mop strength, 4: water, 7: passes, 8: 1, 9: 1},
    ///               3: order}
    ///     TaskOption{1: 1}
    ///
    /// The robot requires a coverage path but doesn't check it against its
    /// own planner, so a serpentine over the interior is sent.
    public static func zoneClean(mapId: Int, zones: [Zone], settings: CleanSettings = CleanSettings()) -> [UInt8] {
        var w = ProtoWriter()
        w.message(1) { task in
            task.varint(1, mapId)
            for (index, zone) in zones.enumerated() {
                task.message(2) { item in
                    item.message(1) { option in
                        option.varint(1, 2)
                        option.varint(2, index + 1)
                        let corners = [(zone.minX, zone.maxY), (zone.maxX, zone.maxY),
                                       (zone.maxX, zone.minY), (zone.minX, zone.minY)]
                        for (x, y) in corners {
                            option.message(3) { p in p.varint(1, x); p.varint(2, y) }
                        }
                        for (x, y) in zoneCoverage(zone) {
                            option.message(4) { p in p.varint(1, x); p.varint(2, y) }
                        }
                    }
                    item.message(2) { param in
                        param.varint(1, settings.workMode.cleanParam.mode)
                        param.varint(2, settings.fan.rawValue)
                        param.varint(3, settings.mopStrength.rawValue)
                        param.varint(4, settings.water.rawValue)
                        param.varint(7, settings.passes)
                        param.varint(8, 1)
                        param.varint(9, 1)
                    }
                    item.varint(3, index + 1)
                }
            }
            task.message(3) { option in option.varint(1, 1) }
            task.varint(5, settings.workMode.rawValue)
        }
        return w.bytes
    }

    /// Serpentine over the rectangle's interior, every second row.
    static func zoneCoverage(_ zone: Zone, step: Int = 2) -> [(Int, Int)] {
        var points: [(Int, Int)] = []
        var forward = true
        var y = zone.minY + 1
        while y < zone.maxY {
            let xs = Array(zone.minX + 1 ..< max(zone.minX + 1, zone.maxX))
            for x in forward ? xs : Array(xs.reversed()) { points.append((x, y)) }
            forward.toggle()
            y += step
        }
        if points.isEmpty { points.append(((zone.minX + zone.maxX) / 2, (zone.minY + zone.maxY) / 2)) }
        return points
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
