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

    private let repository: ActivityRepository
    private var deviceId: UUID?

    init(repository: ActivityRepository) {
        self.repository = repository
    }

    func refresh(for device: Device?) {
        deviceId = device?.id
        reload()
    }

    private func reload() {
        guard let deviceId else {
            samples = []
            latest = nil
            minimum = nil
            maximum = nil
            resting = nil
            hrv = nil
            return
        }

        let end = Date()
        let start = end.addingTimeInterval(-range.duration)
        let fetched = (try? repository.heartRateSamples(for: deviceId, in: start...end)) ?? []

        samples = fetched.sorted { $0.timestamp < $1.timestamp }
        let values = samples.map(\.beatsPerMinute)
        latest = samples.last?.beatsPerMinute
        minimum = values.min()
        maximum = values.max()
        resting = HeartRateStatistics.restingHeartRate(from: samples)
        hrv = (try? repository.hrvSamples(for: deviceId, in: start...end))?
            .max { $0.timestamp < $1.timestamp }?
            .rmssdMilliseconds
    }
}
