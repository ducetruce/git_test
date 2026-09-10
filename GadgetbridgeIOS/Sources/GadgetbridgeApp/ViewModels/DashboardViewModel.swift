import Foundation
import GadgetbridgeCore

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var recentHeartRate: [HeartRateSample] = []
    @Published private(set) var latestBPM: Int?

    private let device: Device
    private let repository: ActivityRepository

    init(device: Device, repository: ActivityRepository) {
        self.device = device
        self.repository = repository
    }

    func refresh() {
        let end = Date()
        let start = end.addingTimeInterval(-3600)
        recentHeartRate = (try? repository.heartRateSamples(for: device.id, in: start...end))?
            .sorted { $0.timestamp < $1.timestamp } ?? []
        latestBPM = recentHeartRate.last?.beatsPerMinute
    }
}
