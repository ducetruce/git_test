import Foundation

public struct Alarm: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var deviceId: UUID
    public var hour: Int   // 0...23
    public var minute: Int // 0...59
    public var repeatDays: Set<Weekday>
    public var isEnabled: Bool
    public var label: String?

    public init(
        id: UUID = UUID(),
        deviceId: UUID,
        hour: Int,
        minute: Int,
        repeatDays: Set<Weekday> = [],
        isEnabled: Bool = true,
        label: String? = nil
    ) {
        self.id = id
        self.deviceId = deviceId
        self.hour = hour
        self.minute = minute
        self.repeatDays = repeatDays
        self.isEnabled = isEnabled
        self.label = label
    }
}

public enum Weekday: Int, Codable, CaseIterable, Sendable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday
}
