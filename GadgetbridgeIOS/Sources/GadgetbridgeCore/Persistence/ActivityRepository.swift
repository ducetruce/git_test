import Foundation

/// Storage for time-series data recorded from devices. Kept as a protocol
/// so the app can swap in a Core Data or SQLite-backed store later without
/// touching `DeviceManager` or the UI layer.
public protocol ActivityRepository: AnyObject {
    func save(_ sample: ActivitySample) throws
    func save(_ sample: HeartRateSample) throws
    func save(_ sample: HRVSample) throws
    func save(_ session: SleepSession) throws

    func activitySamples(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [ActivitySample]
    func heartRateSamples(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [HeartRateSample]
    func hrvSamples(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [HRVSample]
    func sleepSessions(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [SleepSession]

    /// Discards everything recorded before `date`. Without this a device
    /// streaming readings all day grows the store without bound.
    func prune(before date: Date) throws
}
