import Foundation

/// Robot-stored cleaning schedules (decode only).
///
///     GetCleanSchedules.Response {1: errorCode, 2: cleanSchedules (repeated)}
///     CleanSchedule {1: taskId, 2: CleanScheduleParam}
///     CleanScheduleParam {1: crontab, 2: cleanPlanId, 3: cleanMode,
///                         4: isCustomPlan, 5: customName}
///     Crontab {1: cron, 2: remindingTime, 3: enabled}
///
/// Field numbers from docs/schema (CleanSchedule.pb.dart). The Z10 Ultra
/// hasn't answered schedule/clean_schedule/get yet, so this is untested on
/// hardware.
public struct CleanSchedule: Equatable, Sendable, Identifiable {
    public var id: Int
    public var cron: String
    public var enabled: Bool
    public var remindingTime: Int
    public var planId: Int
    /// CleanMode (2 vacuum, 3 mop, 4 both, 5 vacuum then mop).
    public var cleanMode: Int
    public var isCustomPlan: Bool
    public var name: String

    /// Decodes a GetCleanSchedules response. Empty when there are none.
    public static func list(response: ProtoMessage) -> [CleanSchedule] {
        response.messages(2).map(CleanSchedule.init)
    }

    /// "09:30, Mon Wed Fri" for a standard cron line; nil if it isn't one.
    /// Accepts 5 fields (min hour day month weekday) or 6 (leading seconds).
    public var summary: String? {
        var fields = cron.split(separator: " ").map(String.init)
        if fields.count == 6 { fields.removeFirst() }
        guard fields.count == 5, let minute = Int(fields[0]), let hour = Int(fields[1]),
              (0..<60).contains(minute), (0..<24).contains(hour) else { return nil }
        let time = String(format: "%02d:%02d", hour, minute)
        let weekdays = fields[4]
        if weekdays == "*" || weekdays == "?" { return "\(time), every day" }
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        var days: [String] = []
        for part in weekdays.split(separator: ",") {
            let bounds = part.split(separator: "-").compactMap { Int($0) }
            guard !bounds.isEmpty, bounds.count <= 2, bounds.allSatisfy({ (0...7).contains($0) }),
                  bounds.first! <= bounds.last! else { return nil }
            let range = bounds.count == 2 ? Array(bounds[0]...bounds[1]) : [bounds[0]]
            days += range.map { names[$0] }
        }
        return "\(time), \(days.joined(separator: " "))"
    }
}

extension CleanSchedule {
    init(_ m: ProtoMessage) {
        id = m.int(1) ?? 0
        let param = m.message(2)
        let crontab = param?.message(1)
        cron = crontab?.string(1) ?? ""
        remindingTime = crontab?.int(2) ?? 0
        enabled = crontab?.int(3) == 1
        planId = param?.int(2) ?? 0
        cleanMode = param?.int(3) ?? 0
        isCustomPlan = param?.int(4) == 1
        name = param?.string(5) ?? ""
    }
}

// MARK: Writing schedules

/// A robot-stored clean plan (clean/plan/get): what a schedule runs.
///
///     CleanPlan {1 id, 2 mapId, 3 cleanMode, 4 isCustomPlan, 5 customName,
///                6 shownInStation, 7 performTimes, 8 order,
///                9 cleanAreaOptions, 10 cleanParam}
public struct CleanPlan: Equatable, Sendable, Identifiable {
    public var id: Int
    public var mapId: Int
    public var cleanMode: Int
    public var isCustomPlan: Bool
    public var name: String

    /// GetCleanPlans.Response {1 result, 2 cleanPlans}.
    public static func list(response: ProtoMessage) -> [CleanPlan] {
        response.messages(2).map {
            CleanPlan(id: $0.int(1) ?? 0, mapId: $0.int(2) ?? 0, cleanMode: $0.int(3) ?? 0,
                      isCustomPlan: $0.int(4) == 1, name: $0.string(5) ?? "")
        }
    }
}

extension CleanSchedule {
    /// A cron line for a time and weekdays (0 = Sunday), written like the
    /// robot's existing schedules when there are any (5 fields, or 6 with a
    /// leading seconds field). Every day when `weekdays` is empty or all 7.
    public static func cron(hour: Int, minute: Int, weekdays: Set<Int>, like existing: [String] = []) -> String {
        let days = weekdays.isEmpty || weekdays.count == 7 ? "*" : weekdays.sorted().map(String.init).joined(separator: ",")
        let line = "\(minute) \(hour) * * \(days)"
        let sixFields = existing.contains { $0.split(separator: " ").count == 6 }
        return sixFields ? "0 " + line : line
    }

    /// Hour, minute and weekdays (0 = Sunday) back from a cron line.
    public var time: (hour: Int, minute: Int, weekdays: Set<Int>)? {
        var fields = cron.split(separator: " ").map(String.init)
        if fields.count == 6 { fields.removeFirst() }
        guard fields.count == 5, let minute = Int(fields[0]), let hour = Int(fields[1]) else { return nil }
        if fields[4] == "*" || fields[4] == "?" { return (hour, minute, Set(0...6)) }
        var days = Set<Int>()
        for part in fields[4].split(separator: ",") {
            let bounds = part.split(separator: "-").compactMap { Int($0) }
            guard !bounds.isEmpty, bounds.first! <= bounds.last! else { return nil }
            for d in bounds.first!...bounds.last! { days.insert(d % 7) }
        }
        return (hour, minute, days)
    }
}

extension Payloads {
    /// CleanMode for a set of work modes; COMPOSITE (6) when rooms differ.
    public static func cleanMode(_ modes: Set<WorkMode>) -> Int {
        modes.count == 1 ? modes.first!.cleanParam.mode : 6
    }

    /// clean/plan/set: SetCleanPlan.Request {1 CleanPlan}. Rooms in order;
    /// no rooms means the whole house. `id` 0 creates a plan.
    public static func setCleanPlan(id: Int = 0, mapId: Int, name: String, rooms: [Int],
                                    settings: CleanSettings, perRoom: [Int: CleanSettings] = [:],
                                    freoMind: Bool = false) -> [UInt8] {
        let resolved = rooms.map { perRoom[$0] ?? settings }
        let mode = cleanMode(Set(rooms.isEmpty ? [settings.workMode] : resolved.map(\.workMode)))
        var w = ProtoWriter()
        w.message(1) { plan in
            if id != 0 { plan.varint(1, id) }
            plan.varint(2, mapId)
            plan.varint(3, mode)
            plan.varint(4, 1)
            plan.string(5, name)
            if rooms.isEmpty {
                plan.message(9) { option in
                    option.varint(2, 3)  // CLEAN_ZONE_TYPE_WHOLE_HOUSE
                    areaOption(&option, settings)
                }
            }
            for (index, room) in rooms.enumerated() {
                plan.message(9) { option in
                    option.varint(1, room)
                    option.varint(2, 1)  // CLEAN_ZONE_TYPE_ROOM
                    areaOption(&option, resolved[index])
                }
            }
            // CleanPlan 10 cleanParam: CleanTaskParam {1 enableSmartClean}.
            if freoMind { plan.message(10) { $0.varint(1, 1) } }
        }
        return w.bytes
    }

    /// StartEasyClean.Request {1 cleanMode, 2 mapId, 3 cleanAreaOptions}:
    /// the whole house (CleanAreaOption 2 = CLEAN_ZONE_TYPE_WHOLE_HOUSE) in
    /// one mode, with that mode's suction, water and passes.
    public static func easyClean(mapId: Int, settings: CleanSettings) -> [UInt8] {
        var w = ProtoWriter()
        w.varint(1, cleanMode([settings.workMode]))
        w.varint(2, mapId)
        w.message(3) { option in
            option.varint(2, 3)
            areaOption(&option, settings)
        }
        return w.bytes
    }

    /// CleanAreaOption 4-7: the per-mode option (SweepAreaOption {1 fan,
    /// 2 count}, MopAreaOption {1 strength, 2 humidity, 3 count},
    /// SweepMopSyncAreaOption {1 fan, 2 strength, 3 humidity, 4 count},
    /// SweepThenMopAreaOption {1 sweep, 2 mop}).
    static func areaOption(_ w: inout ProtoWriter, _ s: CleanSettings) {
        func sweep(_ m: inout ProtoWriter) { m.varint(1, s.fan.rawValue); m.varint(2, s.passes) }
        func mop(_ m: inout ProtoWriter) {
            m.varint(1, s.mopStrength.rawValue); m.varint(2, s.water.rawValue); m.varint(3, s.passes)
        }
        switch s.workMode {
        case .vacuum: w.message(4, sweep)
        case .mop: w.message(5, mop)
        case .vacuumAndMop:
            w.message(6) { m in
                m.varint(1, s.fan.rawValue); m.varint(2, s.mopStrength.rawValue)
                m.varint(3, s.water.rawValue); m.varint(4, s.passes)
            }
        case .vacuumThenMop:
            w.message(7) { m in m.message(1, sweep); m.message(2, mop) }
        }
    }

    /// CleanScheduleParam {1 Crontab {1 cron, 3 enabled}, 2 cleanPlanId,
    /// 3 cleanMode, 4 isCustomPlan, 5 customName}.
    static func scheduleParam(_ w: inout ProtoWriter, cron: String, enabled: Bool, planId: Int,
                              cleanMode: Int, name: String) {
        w.message(1) { tab in
            tab.string(1, cron)
            tab.varint(3, enabled ? 1 : 0)
        }
        w.varint(2, planId)
        w.varint(3, cleanMode)
        w.varint(4, 1)
        w.string(5, name)
    }

    /// schedule/clean_schedule/add: AddCleanSchedule.Request {1 CleanScheduleParam}.
    public static func addSchedule(cron: String, enabled: Bool, planId: Int, cleanMode: Int, name: String) -> [UInt8] {
        var w = ProtoWriter()
        w.message(1) { scheduleParam(&$0, cron: cron, enabled: enabled, planId: planId, cleanMode: cleanMode, name: name) }
        return w.bytes
    }

    /// schedule/clean_schedule/update: UpdateCleanSchedule.Request {1 CleanSchedule {1 taskId, 2 param}}.
    public static func updateSchedule(_ s: CleanSchedule) -> [UInt8] {
        var w = ProtoWriter()
        w.message(1) { schedule in
            schedule.varint(1, s.id)
            schedule.message(2) {
                scheduleParam(&$0, cron: s.cron, enabled: s.enabled, planId: s.planId,
                              cleanMode: s.cleanMode, name: s.name)
            }
        }
        return w.bytes
    }

    /// schedule/clean_schedule/delete: DeleteCleanSchedules.Request {1 taskIds}.
    public static func deleteSchedules(_ ids: [Int]) -> [UInt8] {
        var w = ProtoWriter()
        for id in ids { w.varint(1, id) }
        return w.bytes
    }
}

/// Schedule replies carry ScheduleErrorCode {1 code} in field 1 instead of
/// a result: 1 is success.
public enum ScheduleReply {
    public static func failure(_ m: ProtoMessage) -> Int? {
        guard let code = m.message(1)?.int(1), code != 1, code != 0 else { return nil }
        return code
    }
}
