import SwiftUI
import GadgetbridgeCore

struct DeviceListView: View {
    @ObservedObject var viewModel: DeviceListViewModel
    let repository: ActivityRepository
    @State private var isShowingPairingSheet = false

    var body: some View {
        List {
            if viewModel.pairedDevices.isEmpty {
                Section {
                    Text("No devices paired yet. Tap \"Add device\" to scan for nearby wearables.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("My devices") {
                    ForEach(viewModel.pairedDevices) { device in
                        NavigationLink {
                            DeviceDetailView(
                                device: device,
                                viewModel: viewModel,
                                repository: repository
                            )
                        } label: {
                            DeviceRow(device: device)
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            viewModel.unpair(viewModel.pairedDevices[index])
                        }
                    }
                }
            }

            Section {
                NavigationLink("Protocol log") {
                    ProtocolLogView()
                }
            } footer: {
                Text("Raw bytes exchanged with devices. Useful when a vendor handshake fails — see the README.")
            }
        }
        .navigationTitle("Gadgetbridge")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingPairingSheet = true
                } label: {
                    Label("Add device", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isShowingPairingSheet) {
            NavigationStack {
                PairingView(viewModel: viewModel)
            }
        }
        .alert(
            "Connection error",
            isPresented: Binding(
                get: { viewModel.lastError != nil },
                set: { if !$0 { viewModel.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.lastError ?? "")
        }
    }
}

private struct DeviceRow: View {
    let device: Device

    var body: some View {
        HStack {
            Image(systemName: "applewatch.watchface")
                .foregroundStyle(device.connectionState == .connected ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(device.name).font(.headline)
                Text(device.connectionState.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let battery = device.battery {
                Label("\(battery.level)%", systemImage: "battery.100")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
