import SwiftUI
import GadgetbridgeCore

struct PairingView: View {
    @ObservedObject var viewModel: DeviceListViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text("Scanning finds devices that speak standard Bluetooth GATT profiles (heart-rate straps, generic fitness bands). Proprietary devices like Mi Band or Amazfit aren't supported yet — see the README.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Nearby devices") {
                if viewModel.discovered.isEmpty {
                    HStack {
                        ProgressView()
                        Text(viewModel.isScanning ? "Scanning…" : "Not scanning")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(viewModel.discovered) { peripheral in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(peripheral.name ?? "Unnamed device")
                                Text("RSSI \(peripheral.rssi) dBm")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if viewModel.isSupported(peripheral) {
                                Button("Pair") {
                                    viewModel.pair(peripheral)
                                    dismiss()
                                }
                                .buttonStyle(.borderedProminent)
                            } else {
                                Text("Unsupported")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Add device")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .onAppear { viewModel.startScanning() }
        .onDisappear { viewModel.stopScanning() }
    }
}
