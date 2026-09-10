import SwiftUI
import GadgetbridgeCore

struct DashboardView: View {
    let device: Device
    let repository: ActivityRepository
    @StateObject private var viewModel: DashboardViewModel

    init(device: Device, repository: ActivityRepository) {
        self.device = device
        self.repository = repository
        _viewModel = StateObject(wrappedValue: DashboardViewModel(device: device, repository: repository))
    }

    var body: some View {
        List {
            Section("Last hour") {
                if let bpm = viewModel.latestBPM {
                    LabeledContent("Latest heart rate", value: "\(bpm) BPM")
                } else {
                    Text("No heart-rate data received yet. Connect the device and wait for a reading.")
                        .foregroundStyle(.secondary)
                }
            }

            if !viewModel.recentHeartRate.isEmpty {
                Section("Readings") {
                    ForEach(Array(viewModel.recentHeartRate.reversed().enumerated()), id: \.offset) { _, sample in
                        HStack {
                            Text(sample.timestamp.formatted(date: .omitted, time: .standard))
                            Spacer()
                            Text("\(sample.beatsPerMinute) BPM")
                        }
                    }
                }
            }
        }
        .navigationTitle("Dashboard")
        .refreshable { viewModel.refresh() }
        .onAppear { viewModel.refresh() }
    }
}
