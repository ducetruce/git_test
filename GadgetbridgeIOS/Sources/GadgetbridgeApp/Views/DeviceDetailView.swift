import SwiftUI
import GadgetbridgeCore

struct DeviceDetailView: View {
    let device: Device
    @ObservedObject var viewModel: DeviceListViewModel
    let repository: ActivityRepository

    private var current: Device {
        viewModel.pairedDevices.first { $0.id == device.id } ?? device
    }

    var body: some View {
        List {
            Section("Status") {
                LabeledContent("Connection", value: current.connectionState.rawValue.capitalized)
                if let battery = current.battery {
                    LabeledContent("Battery", value: "\(battery.level)%\(battery.isCharging ? " (charging)" : "")")
                }
                if let lastSync = current.lastSyncDate {
                    LabeledContent("Last synced", value: lastSync.formatted(date: .abbreviated, time: .shortened))
                }
            }

            Section("Device info") {
                LabeledContent("Manufacturer", value: current.manufacturer ?? "Unknown")
                LabeledContent("Model", value: current.modelNumber ?? "Unknown")
                LabeledContent("Firmware", value: current.firmwareVersion ?? "Unknown")
            }

            Section {
                if current.connectionState == .connected || current.connectionState == .syncing {
                    Button("Disconnect") { viewModel.disconnect(current) }
                } else {
                    Button("Connect") { viewModel.connect(current) }
                }
                NavigationLink("Heart rate dashboard") {
                    DashboardView(device: current, repository: repository)
                }
            }

            Section {
                Button("Remove device", role: .destructive) {
                    viewModel.unpair(current)
                }
            }
        }
        .navigationTitle(current.name)
    }
}
