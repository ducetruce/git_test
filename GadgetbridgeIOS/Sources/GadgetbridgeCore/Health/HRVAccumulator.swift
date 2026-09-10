import Foundation

/// Collects RR intervals across many notifications and emits an `HRVSample`
/// once a window's worth has arrived.
///
/// This exists because a single `0x2A37` notification carries only one or
/// two beat-to-beat intervals — enough to compute an RMSSD arithmetically,
/// but not enough for the number to mean anything. HRV is only interpretable
/// over a window of consecutive beats, so intervals are buffered and a
/// reading is emitted per window.
public final class HRVAccumulator {
    private let window: TimeInterval
    private let minimumBeats: Int
    private var intervals: [Double] = []
    private var windowStartedAt: Date?

    public init(window: TimeInterval = 60, minimumBeats: Int = 20) {
        self.window = window
        self.minimumBeats = minimumBeats
    }

    /// Adds intervals from one notification. Returns a sample when the
    /// window closes with enough beats in it, otherwise nil.
    public func add(_ newIntervals: [Double], deviceId: UUID, now: Date = Date()) -> HRVSample? {
        guard !newIntervals.isEmpty else { return nil }

        if windowStartedAt == nil {
            windowStartedAt = now
        }
        intervals.append(contentsOf: newIntervals)

        guard let start = windowStartedAt, now.timeIntervalSince(start) >= window else { return nil }

        defer {
            intervals.removeAll()
            windowStartedAt = nil
        }

        let usable = HeartRateVariability.filterArtefacts(intervals)
        guard usable.count >= minimumBeats else { return nil }
        return HeartRateVariability.sample(deviceId: deviceId, timestamp: now, intervals: usable)
    }

    public func reset() {
        intervals.removeAll()
        windowStartedAt = nil
    }
}
