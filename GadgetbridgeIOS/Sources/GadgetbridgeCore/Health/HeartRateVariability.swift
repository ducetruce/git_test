import Foundation

/// A heart-rate-variability reading computed from a window of beat-to-beat
/// (RR) intervals.
public struct HRVSample: Codable, Hashable, Sendable {
    public var deviceId: UUID
    public var timestamp: Date
    /// Root mean square of successive differences, in milliseconds. The
    /// standard short-window HRV metric, and what Apple Health stores.
    public var rmssdMilliseconds: Double
    /// Standard deviation of NN intervals, in milliseconds.
    public var sdnnMilliseconds: Double
    /// How many intervals the figures were computed from — a reading built
    /// from a handful of beats is not comparable to one built from minutes.
    public var beatCount: Int

    public init(
        deviceId: UUID,
        timestamp: Date,
        rmssdMilliseconds: Double,
        sdnnMilliseconds: Double,
        beatCount: Int
    ) {
        self.deviceId = deviceId
        self.timestamp = timestamp
        self.rmssdMilliseconds = rmssdMilliseconds
        self.sdnnMilliseconds = sdnnMilliseconds
        self.beatCount = beatCount
    }
}

public enum HeartRateVariability {
    /// Intervals outside this range are dropped as artefacts — a missed or
    /// double-counted beat produces an interval far outside any plausible
    /// human heart rate (roughly 30-200 bpm), and one artefact can dominate
    /// RMSSD entirely.
    static let plausibleIntervalRange: ClosedRange<Double> = 0.30...2.0

    /// RMSSD in milliseconds: the root mean square of successive
    /// differences between adjacent intervals. Needs at least two intervals.
    public static func rmssd(intervals: [Double]) -> Double? {
        let clean = filterArtefacts(intervals)
        guard clean.count >= 2 else { return nil }

        var sumOfSquares = 0.0
        for index in 1..<clean.count {
            let difference = (clean[index] - clean[index - 1]) * 1000
            sumOfSquares += difference * difference
        }
        return (sumOfSquares / Double(clean.count - 1)).squareRoot()
    }

    /// SDNN in milliseconds: the standard deviation of the intervals
    /// themselves.
    public static func sdnn(intervals: [Double]) -> Double? {
        let clean = filterArtefacts(intervals)
        guard clean.count >= 2 else { return nil }

        let millis = clean.map { $0 * 1000 }
        let mean = millis.reduce(0, +) / Double(millis.count)
        let variance = millis.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(millis.count - 1)
        return variance.squareRoot()
    }

    public static func sample(
        deviceId: UUID,
        timestamp: Date = Date(),
        intervals: [Double]
    ) -> HRVSample? {
        let clean = filterArtefacts(intervals)
        guard let rmssd = rmssd(intervals: clean), let sdnn = sdnn(intervals: clean) else { return nil }
        return HRVSample(
            deviceId: deviceId,
            timestamp: timestamp,
            rmssdMilliseconds: rmssd,
            sdnnMilliseconds: sdnn,
            beatCount: clean.count
        )
    }

    static func filterArtefacts(_ intervals: [Double]) -> [Double] {
        intervals.filter { plausibleIntervalRange.contains($0) }
    }
}
