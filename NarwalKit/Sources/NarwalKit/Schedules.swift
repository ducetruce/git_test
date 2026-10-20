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
