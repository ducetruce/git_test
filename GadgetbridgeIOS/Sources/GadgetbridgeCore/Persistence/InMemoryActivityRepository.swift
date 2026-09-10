import Foundation

/// Simple in-process store, useful for previews, tests, and as a reference
/// implementation of `ActivityRepository`.
public final class InMemoryActivityRepository: ActivityRepository {
    private let lock = NSLock()
    private var activitySamples: [ActivitySample] = []
    private var heartRateSamples: [HeartRateSample] = []
    private var sleepSessions: [SleepSession] = []

    public init() {}

    public func save(_ sample: ActivitySample) throws {
        lock.withLock { activitySamples.append(sample) }
    }

    public func save(_ sample: HeartRateSample) throws {
        lock.withLock { heartRateSamples.append(sample) }
    }

    public func save(_ session: SleepSession) throws {
        lock.withLock { sleepSessions.append(session) }
    }

    public func activitySamples(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [ActivitySample] {
        lock.withLock {
            activitySamples.filter { $0.deviceId == deviceId && range.contains($0.timestamp) }
        }
    }

    public func heartRateSamples(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [HeartRateSample] {
        lock.withLock {
            heartRateSamples.filter { $0.deviceId == deviceId && range.contains($0.timestamp) }
        }
    }

    public func sleepSessions(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [SleepSession] {
        lock.withLock {
            sleepSessions.filter { $0.deviceId == deviceId && range.overlaps($0.start...$0.end) }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
