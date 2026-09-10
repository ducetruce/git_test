import SwiftUI
import GadgetbridgeCore

struct DeviceDetailView: View {
    let device: Device
    @ObservedObject var viewModel: DeviceListViewModel
    let repository: ActivityRepository

    #if canImport(HealthKit)
    @StateObject private var healthExporter = HealthKitExporter()
    @State private var exportStatus: String?
    #endif

    /// Always read through the view model so the screen tracks live state
    /// rather than the snapshot it was pushed with.
    private var current: Device {
        viewModel.pairedDevices.first { $0.id == device.id } ?? device
    }

    private var isLinked: Bool {
        current.connectionState == .connected || current.connectionState == .syncing
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(current.family.rawValue)
                        .instrumentLabel()
                    Spacer()
                    StatusPill(text: current.connectionState.rawValue.capitalized, isGood: isLinked)
                }

                batteryPanel

                section(title: "Identity", trailing: "0x180A", raw: true) {
                    detailRow("Manufacturer", current.manufacturer ?? "Unknown")
                    detailRow("Model", current.modelNumber ?? "Unknown")
                    detailRow("Firmware", current.firmwareVersion ?? "Unknown")
                    detailRow("Peripheral", shortIdentifier)
                }

                section(title: "Link", trailing: isLinked ? "live" : nil) {
                    detailRow("Auth", current.family == .amazfit ? "ECDH B-163" : "None", tint: isLinked ? Instrument.linked : Instrument.dim)
                    if let lastSync = current.lastSyncDate {
                        detailRow("Last sync", lastSync.formatted(date: .omitted, time: .shortened))
                    }
                }

                #if canImport(HealthKit)
                healthSection
                #endif

                VStack(spacing: 9) {
                    Button(isLinked ? "Disconnect" : "Connect") {
                        isLinked ? viewModel.disconnect(current) : viewModel.connect(current)
                    }
                    .buttonStyle(InstrumentButtonStyle(role: .ghost))

                    Button("Remove device", role: .destructive) {
                        viewModel.unpair(current)
                    }
                    .buttonStyle(InstrumentButtonStyle(role: .danger))
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .background(Instrument.ground)
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Instrument.ground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    #if canImport(HealthKit)
    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Apple Health")
            Text("Copies this device's readings into your health record. Heart rate and HRV only, one-directional, and nothing leaves the phone.")
                .font(.system(size: 11.5))
                .foregroundStyle(Instrument.faint)

            Button("Export last 24 hours") {
                Task { await exportRecentSamples() }
            }
            .buttonStyle(InstrumentButtonStyle(role: .ghost))

            if let exportStatus {
                Text(exportStatus)
                    .font(Instrument.mono(10.5))
                    .foregroundStyle(Instrument.dim)
            }
            if let error = healthExporter.lastError {
                Text(error)
                    .font(Instrument.mono(10.5))
                    .foregroundStyle(Instrument.discarded)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private func exportRecentSamples() async {
        await healthExporter.requestAuthorization()
        guard healthExporter.isAuthorized else { return }

        let end = Date()
        let start = end.addingTimeInterval(-24 * 3600)
        let heartRates = (try? repository.heartRateSamples(for: current.id, in: start...end)) ?? []
        let hrvs = (try? repository.hrvSamples(for: current.id, in: start...end)) ?? []

        await healthExporter.export(heartRate: heartRates, deviceName: current.name)
        await healthExporter.export(hrv: hrvs)

        exportStatus = "Exported \(heartRates.count) heart rate and \(hrvs.count) HRV samples."
    }
    #endif

    private var shortIdentifier: String {
        let id = current.peripheralIdentifier
        guard id.count > 9 else { return id }
        return "\(id.prefix(4))…\(id.suffix(4))"
    }

    private var batteryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(
                title: "Battery",
                trailing: current.battery.map { "read \(relativeTime(from: $0.updatedAt))" }
            )
            HStack(spacing: 11) {
                BatteryCells(level: current.battery?.level ?? 0)
                Text(current.battery.map { "\($0.level)%" } ?? "––")
                    .font(Instrument.mono(16))
                    .monospacedDigit()
                    .foregroundStyle(Instrument.amber)
                    .shadow(color: Instrument.amber.opacity(0.3), radius: 8)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private func relativeTime(from date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        return minutes < 60 ? "\(minutes)m ago" : "\(minutes / 60)h ago"
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        trailing: String? = nil,
        raw: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(title: title, trailing: trailing, trailingIsRaw: raw)
            VStack(spacing: 0) { content() }
        }
    }

    private func detailRow(_ key: String, _ value: String, tint: Color = Instrument.ink) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(key)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Instrument.dim)
                Spacer(minLength: 12)
                Text(value)
                    .font(Instrument.mono(12.5))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 10)
            Divider().overlay(Instrument.rule)
        }
    }
}

// MARK: - Pieces

struct StatusPill: View {
    let text: String
    let isGood: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(isGood ? Instrument.linked : Instrument.amber)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(
                Capsule().fill((isGood ? Instrument.linked : Instrument.amber).opacity(0.11))
            )
            .overlay(
                Capsule().strokeBorder((isGood ? Instrument.linked : Instrument.amber).opacity(0.27), lineWidth: 1)
            )
    }
}

/// Battery as discrete cells rather than a continuous bar — it reads as
/// instrumentation, and matches how coarse the underlying 0x2A19 reading is.
private struct BatteryCells: View {
    let level: Int

    private let cellCount = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<cellCount, id: \.self) { index in
                let threshold = Double(index + 1) / Double(cellCount) * 100
                let partial = Double(level) > threshold - (100.0 / Double(cellCount))
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Instrument.amber.opacity(Double(level) >= threshold ? 1 : (partial ? 0.45 : 0.12)))
                    .frame(height: 10)
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity)
        .instrumentWell(cornerRadius: 5)
    }
}

struct InstrumentButtonStyle: ButtonStyle {
    enum Role { case primary, ghost, danger }
    let role: Role

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14.5, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(role == .primary ? .clear : Instrument.rule, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }

    private var foreground: Color {
        switch role {
        case .primary: return Color(hex: 0x180F02)
        case .ghost: return Instrument.amber
        case .danger: return Instrument.danger
        }
    }

    @ViewBuilder
    private var background: some View {
        switch role {
        case .primary:
            LinearGradient(colors: [Color(hex: 0xF2AE4B), Color(hex: 0xDE9227)], startPoint: .top, endPoint: .bottom)
        case .ghost:
            Instrument.panel
        case .danger:
            Color.clear
        }
    }
}
