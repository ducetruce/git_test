import Foundation

/// Storage for time-series data recorded from devices. Kept as a protocol
/// so the app can swap in a Core Data or SQLite-backed store later without
/// touching `DeviceManager` or the UI layer.
public protocol ActivityRepository: AnyObject {
    func save(_ sample: ActivitySample) throws
    func save(_ sample: HeartRateSample) throws
    func save(_ session: SleepSession) throws

    func activitySamples(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [ActivitySample]
    func heartRateSamples(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [HeartRateSample]
    func sleepSessions(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [SleepSession]
}
