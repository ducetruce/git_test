import Foundation

/// Cleaning history: GetCleanTimeLine.Response {1: result, 2: TimeLineStatus},
/// also broadcast on status/time_line_status as a bare TimeLineStatus.
///
///     TimeLineStatus {1: robotEventList (repeated RobotEventNode)}
///     RobotEventNode {1: eventTime, 2: primaryTask, 3: secondaryCleanEvent,
///                     4: secondarySelfCheck, 5: taskResult, 6: errorCode,
///                     7: isPrimaryNode, 8: nodeKey}
///
/// Field numbers from docs/schema (TimeLineStatus.pb.dart).
public struct CleaningHistory: Equatable, Sendable {
    public var events: [CleaningEvent]

    /// A get_clean_time_line response; nil for a bare status reply.
    public init?(response: ProtoMessage) {
        guard let status = response.message(2) else { return nil }
        self.init(timeLine: status)
    }

    init(events: [CleaningEvent]) {
        self.events = events
    }

    public init(timeLine: ProtoMessage) {
        events = timeLine.messages(1).enumerated().map { CleaningEvent($1, index: $0) }
    }
}

public struct CleaningEvent: Equatable, Sendable, Identifiable {
    /// nodeKey when the robot sends one, otherwise the position in the list.
    public var id: Int
    /// eventTime as sent. Its unit isn't in the schema; see `date`.
    public var rawTime: Int
    public var task: Int
    public var result: Int?
    public var isPrimary: Bool
    public var errorCode: Int?
    /// SecondaryCleanEvent.zoneInfo: the room or zone being cleaned.
    public var zoneId: Int?
    /// CleanMode of that zone (2 vacuum, 3 mop, 4 both, 5 vacuum then mop).
    public var cleanMode: Int?

    /// eventTime read as epoch milliseconds or seconds, if either gives a
    /// date between 2015 and tomorrow; nil otherwise. A Z10 Ultra sent values
    /// that fit neither (they read as the year 5,828,963), so the unit is
    /// still unknown and the app shows the raw value instead.
    public var date: Date? { Self.plausibleDate(rawTime) }

    static func plausibleDate(_ raw: Int, now: Date = Date()) -> Date? {
        let earliest = Date(timeIntervalSince1970: 1_420_070_400)   // 2015-01-01
        let latest = now.addingTimeInterval(86_400)
        for seconds in [Double(raw) / 1000, Double(raw)] {
            let date = Date(timeIntervalSince1970: seconds)
            if date >= earliest, date <= latest { return date }
        }
        return nil
    }

    /// PrimaryTaskType.
    public var taskLabel: String {
        switch task {
        case 1: return "Self-check"
        case 2: return "Leaving the dock"
        case 3: return "Washing mop before cleaning"
        case 4: return "Cleaning"
        case 5: return "Paused unexpectedly"
        case 6: return "Finished"
        case 7: return "Area not cleaned"
        case 8: return "Floor maintenance"
        case 9: return "Emptying dustbin"
        case 10: return "Updating map"
        default: return "Event \(task)"
        }
    }

    /// TaskResult, or nil while the task hasn't ended.
    public var resultLabel: String? {
        guard let result, result != 0 else { return nil }
        switch result {
        case 1: return "Completed"
        case 2: return "Stopped by you"
        case 3: return "Stopped: robot shut down"
        case 4: return "Stopped: low battery"
        case 5: return "Stopped: water overflow"
        case 6: return "Stopped: paused too long"
        case 7: return "Stopped: system error"
        case 8: return "Stopped at the station"
        case 9: return "Stopped from the app"
        case 10: return "Sent back to the dock"
        case 11: return "Completed; map update failed"
        case 12: return "Stopped: map didn't match"
        case 13, 14: return "Stopped: couldn't find its position"
        case 15: return "Stopped: error before starting"
        case 16: return "Stopped for a scheduled task"
        case 17: return "Not run"
        case 18: return "Pet not found"
        default: return "Result \(result)"
        }
    }

    public var succeeded: Bool { result == 1 || result == 11 }
}

extension CleaningEvent {
    init(_ m: ProtoMessage, index: Int) {
        id = m.int(8) ?? index
        rawTime = m.int(1) ?? 0
        task = m.int(2) ?? 0
        result = m.int(5)
        isPrimary = m.int(7) == 1
        errorCode = m.message(6)?.int(1).flatMap { $0 != 0 ? $0 : nil }
        let zone = m.message(3)?.message(2)
        zoneId = zone?.int(2)
        cleanMode = zone?.int(4)
    }
}
