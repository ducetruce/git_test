import Foundation

/// A single step-count/activity-level reading, analogous to Gadgetbridge's
/// `ActivitySample` database rows.
public struct ActivitySample: Codable, Hashable, Sendable {
    public var deviceId: UUID
    public var timestamp: Date
    public var steps: Int
    public var intensity: Double? // 0.0...1.0, device-reported activity intensity if available

    public init(deviceId: UUID, timestamp: Date, steps: Int, intensity: Double? = nil) {
        self.deviceId = deviceId
        self.timestamp = timestamp
        self.steps = steps
        self.intensity = intensity
    }
}

public struct HeartRateSample: Codable, Hashable, Sendable {
    public var deviceId: UUID
    public var timestamp: Date
    public var beatsPerMinute: Int

    public init(deviceId: UUID, timestamp: Date, beatsPerMinute: Int) {
        self.deviceId = deviceId
        self.timestamp = timestamp
        self.beatsPerMinute = beatsPerMinute
    }
}

public struct SleepSession: Codable, Hashable, Sendable {
    public var deviceId: UUID
    public var start: Date
    public var end: Date
    public var isDeepSleep: Bool

    public init(deviceId: UUID, start: Date, end: Date, isDeepSleep: Bool) {
        self.deviceId = deviceId
        self.start = start
        self.end = end
        self.isDeepSleep = isDeepSleep
    }
}
