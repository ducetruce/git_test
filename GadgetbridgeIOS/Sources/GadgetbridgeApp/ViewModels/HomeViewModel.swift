import Foundation
import GadgetbridgeCore

enum TimeRange: String, CaseIterable, Identifiable {
    case hour = "1H"
    case sixHours = "6H"
    case day = "24H"

    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .hour: return 3600
        case .sixHours: return 6 * 3600
        case .day: return 24 * 3600
        }
    }
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var range: TimeRange = .hour {
        didSet { reload() }
    }

    @Published private(set) var samples: [HeartRateSample] = []
    @Published private(set) var latest: Int?
    @Published private(set) var minimum: Int?
    @Published private(set) var maximum: Int?
    @Published private(set) var resting: Int?
    /// Most recent HRV reading in the window, as RMSSD in milliseconds.
    @Published private(set) var hrv: Double?
    /// Zone of the latest reading, when a maximum heart rate is configured.
    @Published private(set) var zone: HeartRateZone?

    private let repository: ActivityRepository
    private let settings: UserSettings
    private var deviceId: UUID?

    init(repository: ActivityRepository, settings: UserSettings) {
        self.repository = repository
        self.settings = settings
    }

    /// Full reload from storage. Only for changes that invalidate the whole
    /// window — a different device, a different range, or first appearance.
    func refresh(for device: Device?) {
        deviceId = device?.id
        reload()
    }

    /// The live path. Readings arrive about once a second, so re-reading the
    /// whole window from storage each time would mean decoding the entire
    /// range on every heartbeat; appending is O(1) and gives the same series.
    func append(_ sample: HeartRateSample) {
        guard sample.deviceId == deviceId else { return }
        samples.append(sample)
        dropSamplesOutsideRange()
        recomputeDerivedValues()
    }

    /// HRV lands about once a minute, so reading just that series back is
    /// cheap enough to do directly.
    func refreshHRV() {
        guard let deviceId else { return }
        let end = Date()
        let start = end.addingTimeInterval(-range.duration)
        hrv = (try? repository.hrvSamples(for: deviceId, in: start...end))?
            .max { $0.timestamp < $1.timestamp }?
            .rmssdMilliseconds
    }

    private func reload() {
        guard let deviceId else {
            samples = []
            latest = nil
            minimum = nil
            maximum = nil
            resting = nil
            hrv = nil
            zone = nil
            return
        }

        let end = Date()
        let start = end.addingTimeInterval(-range.duration)
        samples = ((try? repository.heartRateSamples(for: deviceId, in: start...end)) ?? [])
            .sorted { $0.timestamp < $1.timestamp }

        recomputeDerivedValues()
        refreshHRV()
    }

    private func dropSamplesOutsideRange() {
        let cutoff = Date().addingTimeInterval(-range.duration)
        guard let firstInside = samples.firstIndex(where: { $0.timestamp >= cutoff }), firstInside > 0 else { return }
        samples.removeFirst(firstInside)
    }

    private func recomputeDerivedValues() {
        let values = samples.map(\.beatsPerMinute)
        latest = samples.last?.beatsPerMinute
        minimum = values.min()
        maximum = values.max()
        resting = HeartRateStatistics.restingHeartRate(from: samples)
        zone = latest.flatMap { bpm in
            settings.maximumHeartRate.flatMap { HeartRateZone.zone(forBPM: bpm, maximumHeartRate: $0) }
        }
    }
}
