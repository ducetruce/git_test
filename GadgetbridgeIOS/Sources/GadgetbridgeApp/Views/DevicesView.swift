import SwiftUI
import GadgetbridgeCore

/// Device management, moved off the root screen: pairing, link state, and
/// the way into each device's detail.
struct DevicesView: View {
    @ObservedObject var viewModel: DeviceListViewModel
    let repository: ActivityRepository
    @ObservedObject var settings: UserSettings
    @State private var isShowingPairingSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if viewModel.pairedDevices.isEmpty {
                    Text("No devices paired yet. Scan to find nearby trackers.")
                        .font(.system(size: 13))
                        .foregroundStyle(Instrument.faint)
                        .padding(.top, 8)
                } else {
                    SectionLabel(title: "Paired")
                    VStack(spacing: 9) {
                        ForEach(viewModel.pairedDevices) { device in
                            NavigationLink {
                                DeviceDetailView(device: device, viewModel: viewModel, repository: repository)
                            } label: {
                                DeviceCard(device: device)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button {
                    isShowingPairingSheet = true
                } label: {
                    Text("Scan for devices")
                        .font(.system(size: 14.5, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Instrument.amber)
                .instrumentPanel(cornerRadius: 12)
                .padding(.top, 4)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .background(Instrument.ground)
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Instrument.ground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    SettingsView(settings: settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .tint(Instrument.amber)
            }
        }
        .sheet(isPresented: $isShowingPairingSheet) {
            NavigationStack {
                PairingView(viewModel: viewModel)
            }
            .preferredColorScheme(.dark)
        }
    }
}

private struct DeviceCard: View {
    let device: Device

    private var isLinked: Bool {
        device.connectionState == .connected || device.connectionState == .syncing
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isLinked ? Instrument.linked : Instrument.faint)
                .frame(width: 7, height: 7)
                .shadow(color: isLinked ? Instrument.linked.opacity(0.55) : .clear, radius: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Instrument.ink)
                Text("\(device.connectionState.rawValue.capitalized) · \(device.family.rawValue)")
                    .font(Instrument.mono(10))
                    .foregroundStyle(Instrument.faint)
            }

            Spacer(minLength: 8)

            if let battery = device.battery {
                Text("\(battery.level)%")
                    .font(Instrument.mono(12))
                    .monospacedDigit()
                    .foregroundStyle(Instrument.amber)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Instrument.faint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .instrumentPanel(cornerRadius: 13)
    }
}
