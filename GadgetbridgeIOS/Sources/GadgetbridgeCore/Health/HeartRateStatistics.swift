import Foundation

public enum HeartRateStatistics {
    /// Resting heart rate, estimated as the 10th percentile of the samples
    /// in the window.
    ///
    /// A plain minimum is too fragile — one dropout or motion artefact sets
    /// it — while a mean is dragged up by any activity in the window. The
    /// low decile tracks the sustained floor, which is what "resting"
    /// actually means. It needs a reasonable number of samples to mean
    /// anything, so it returns nil below that.
    public static func restingHeartRate(from samples: [HeartRateSample], minimumSamples: Int = 10) -> Int? {
        guard samples.count >= minimumSamples else { return nil }
        let sorted = samples.map(\.beatsPerMinute).sorted()
        let index = max(0, Int(Double(sorted.count - 1) * 0.10))
        return sorted[index]
    }

    public static func average(of samples: [HeartRateSample]) -> Int? {
        guard !samples.isEmpty else { return nil }
        let total = samples.reduce(0) { $0 + $1.beatsPerMinute }
        return Int((Double(total) / Double(samples.count)).rounded())
    }
}

/// The five-zone model used across sports science, expressed as fractions
/// of maximum heart rate.
public enum HeartRateZone: Int, CaseIterable, Codable, Sendable {
    case recovery = 1
    case aerobicBase
    case aerobic
    case threshold
    case maximum

    public var name: String {
        switch self {
        case .recovery: return "Recovery"
        case .aerobicBase: return "Base"
        case .aerobic: return "Aerobic"
        case .threshold: return "Threshold"
        case .maximum: return "Max"
        }
    }

    /// Lower bound as a fraction of maximum heart rate.
    public var lowerFraction: Double {
        switch self {
        case .recovery: return 0.50
        case .aerobicBase: return 0.60
        case .aerobic: return 0.70
        case .threshold: return 0.80
        case .maximum: return 0.90
        }
    }

    public static func zone(forBPM bpm: Int, maximumHeartRate: Int) -> HeartRateZone? {
        guard maximumHeartRate > 0 else { return nil }
        let fraction = Double(bpm) / Double(maximumHeartRate)
        guard fraction >= HeartRateZone.recovery.lowerFraction else { return nil }
        return HeartRateZone.allCases.last { fraction >= $0.lowerFraction }
    }

    /// The common age-based estimate. It's a population average with wide
    /// individual spread, so it's a starting point for a user setting
    /// rather than a measurement.
    public static func estimatedMaximum(forAge age: Int) -> Int {
        max(100, 220 - age)
    }
}
