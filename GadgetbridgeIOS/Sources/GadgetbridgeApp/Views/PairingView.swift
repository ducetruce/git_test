import SwiftUI
import GadgetbridgeCore

struct PairingView: View {
    @ObservedObject var viewModel: DeviceListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var pairingSecrets: [String: String] = [:]

    var body: some View {
        List {
            Section {
                Text("Scanning finds standard Bluetooth GATT devices (heart-rate straps, generic fitness bands) and Amazfit/Zepp OS devices. Amazfit pairing needs the 16-byte key from your Zepp app account — see the README. Other proprietary devices (Mi Band, Pebble, etc.) aren't supported yet.")
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
                        deviceRow(for: peripheral)
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

    @ViewBuilder
    private func deviceRow(for peripheral: DiscoveredPeripheral) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
                        viewModel.pair(peripheral, pairingSecretHex: pairingSecrets[peripheral.id])
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canPair(peripheral))
                } else {
                    Text("Unsupported")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if viewModel.isSupported(peripheral), viewModel.requiresPairingSecret(peripheral) {
                TextField(
                    "32-character pairing key (hex)",
                    text: Binding(
                        get: { pairingSecrets[peripheral.id] ?? "" },
                        set: { pairingSecrets[peripheral.id] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            }
        }
    }

    private func canPair(_ peripheral: DiscoveredPeripheral) -> Bool {
        guard viewModel.requiresPairingSecret(peripheral) else { return true }
        let hex = pairingSecrets[peripheral.id] ?? ""
        return hex.replacingOccurrences(of: " ", with: "").count == 32
    }
}
