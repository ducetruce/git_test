import SwiftUI
import GadgetbridgeCore

struct PairingView: View {
    @ObservedObject var viewModel: DeviceListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var pairingSecrets: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if viewModel.discovered.isEmpty {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small).tint(Instrument.amber)
                        Text(viewModel.isScanning ? "Scanning…" : "Not scanning")
                            .font(Instrument.mono(11))
                            .foregroundStyle(Instrument.faint)
                    }
                    .padding(.vertical, 20)
                } else {
                    ForEach(viewModel.discovered) { peripheral in
                        resultRow(for: peripheral)
                        Divider().overlay(Instrument.rule)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    SectionLabel(title: "Why some devices can't pair")
                    Text("Standard GATT profiles pair straight away. Vendor protocols need a coordinator implementation — anything without one is listed but not offered.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Instrument.faint)
                }
                .padding(.top, 22)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .background(Instrument.ground)
        .navigationTitle("Add device")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Instrument.ground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }.tint(Instrument.amber)
            }
        }
        .onAppear { viewModel.startScanning() }
        .onDisappear { viewModel.stopScanning() }
    }

    @ViewBuilder
    private func resultRow(for peripheral: DiscoveredPeripheral) -> some View {
        let needsKey = viewModel.requiresPairingSecret(peripheral)
        let supported = viewModel.isSupported(peripheral)

        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(peripheral.name ?? "Unnamed device")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Instrument.ink)
                        .lineLimit(1)
                    Text(metaLine(for: peripheral, supported: supported))
                        .font(Instrument.mono(10))
                        .foregroundStyle(Instrument.faint)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if !supported {
                    Text("No coordinator")
                        .font(.system(size: 11))
                        .foregroundStyle(Instrument.faint)
                } else if needsKey {
                    StatusPill(text: "Key needed", isGood: false)
                } else {
                    Button("Pair") {
                        viewModel.pair(peripheral)
                        dismiss()
                    }
                    .buttonStyle(CompactButtonStyle())
                }
            }

            if supported, needsKey {
                keyEntry(for: peripheral)
            }
        }
        .padding(.vertical, 12)
    }

    private func metaLine(for peripheral: DiscoveredPeripheral, supported: Bool) -> String {
        let service = peripheral.advertisedServiceUUIDs.first.map { "0x\($0.uuidString.prefix(4))" } ?? "no service"
        let mode: String
        if !supported {
            mode = "unknown"
        } else if viewModel.isBroadcasting(peripheral) {
            mode = "broadcast · no key"
        } else if viewModel.requiresPairingSecret(peripheral) {
            mode = "Zepp OS"
        } else {
            mode = "standard GATT"
        }
        return "\(peripheral.rssi) dBm · \(service) · \(mode)"
    }

    private func keyEntry(for peripheral: DiscoveredPeripheral) -> some View {
        let binding = Binding(
            get: { pairingSecrets[peripheral.id] ?? "" },
            set: { pairingSecrets[peripheral.id] = $0 }
        )
        let entered = binding.wrappedValue.replacingOccurrences(of: " ", with: "")

        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                TextField("pairing key", text: binding)
                    .font(Instrument.mono(11.5))
                    .foregroundStyle(Instrument.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .tint(Instrument.amber)
                Text("\(entered.count)/32")
                    .font(Instrument.mono(11.5))
                    .monospacedDigit()
                    .foregroundStyle(Instrument.faint)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .instrumentWell()
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Instrument.amber.opacity(0.22), lineWidth: 1)
            )

            Text("Pairing key from your Zepp account. Huami's servers issue it at first pairing — it can't be derived here.")
                .font(.system(size: 11))
                .foregroundStyle(Instrument.faint)

            Button("Pair") {
                viewModel.pair(peripheral, pairingSecretHex: binding.wrappedValue)
                dismiss()
            }
            .buttonStyle(CompactButtonStyle())
            .disabled(entered.count != 32)
            .opacity(entered.count == 32 ? 1 : 0.45)
        }
    }
}

struct CompactButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color(hex: 0x180F02))
            .padding(.horizontal, 15)
            .padding(.vertical, 7)
            .background(
                LinearGradient(colors: [Color(hex: 0xF2AE4B), Color(hex: 0xDE9227)], startPoint: .top, endPoint: .bottom)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
