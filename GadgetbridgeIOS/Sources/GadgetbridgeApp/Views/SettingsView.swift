import SwiftUI
import GadgetbridgeCore

struct SettingsView: View {
    @ObservedObject var settings: UserSettings
    @State private var maximumText: String = ""
    @State private var ageText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                maximumHeartRateSection
                if settings.maximumHeartRate != nil {
                    zoneTable
                }
                retentionSection
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Instrument.ground)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Instrument.ground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear {
            maximumText = settings.maximumHeartRate.map(String.init) ?? ""
        }
    }

    private var maximumHeartRateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Maximum heart rate", trailing: "bpm")
            Text("Zones are fractions of this. Nothing on a wrist strap can measure it, so until it's set, zones stay hidden rather than being guessed at.")
                .font(.system(size: 11.5))
                .foregroundStyle(Instrument.faint)

            HStack(spacing: 10) {
                TextField("not set", text: $maximumText)
                    .font(Instrument.mono(15))
                    .foregroundStyle(Instrument.ink)
                    .keyboardType(.numberPad)
                    .tint(Instrument.amber)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 10)
                    .instrumentWell()
                    .onChange(of: maximumText) { newValue in
                        let digits = newValue.filter(\.isNumber)
                        settings.maximumHeartRate = Int(digits).flatMap { $0 > 0 ? $0 : nil }
                    }

                Button("Clear") {
                    maximumText = ""
                    settings.maximumHeartRate = nil
                }
                .font(.system(size: 13))
                .foregroundStyle(Instrument.amber)
            }

            HStack(spacing: 10) {
                TextField("age", text: $ageText)
                    .font(Instrument.mono(13))
                    .foregroundStyle(Instrument.ink)
                    .keyboardType(.numberPad)
                    .tint(Instrument.amber)
                    .frame(width: 70)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .instrumentWell()

                Button("Estimate from age") {
                    guard let age = Int(ageText.filter(\.isNumber)), age > 0 else { return }
                    settings.applyAgeBasedEstimate(age: age)
                    maximumText = settings.maximumHeartRate.map(String.init) ?? ""
                }
                .font(.system(size: 13))
                .foregroundStyle(Instrument.amber)
            }

            Text("The 220-minus-age estimate is a population average with wide individual spread. Treat it as a starting point, not a measurement.")
                .font(.system(size: 11))
                .foregroundStyle(Instrument.faint)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private var zoneTable: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(title: "Zones")
            ForEach(HeartRateZone.allCases, id: \.self) { zone in
                HStack {
                    Text(zone.name)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Instrument.dim)
                    Spacer()
                    Text(bounds(for: zone))
                        .font(Instrument.mono(12.5))
                        .monospacedDigit()
                        .foregroundStyle(Instrument.ink)
                }
                .padding(.vertical, 9)
                Divider().overlay(Instrument.rule)
            }
        }
    }

    private func bounds(for zone: HeartRateZone) -> String {
        guard let maximum = settings.maximumHeartRate else { return "––" }
        let lower = Int((zone.lowerFraction * Double(maximum)).rounded())
        guard let next = HeartRateZone(rawValue: zone.rawValue + 1) else { return "\(lower)+" }
        let upper = Int((next.lowerFraction * Double(maximum)).rounded()) - 1
        return "\(lower)–\(upper)"
    }

    private var retentionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Keep history for", trailing: "\(settings.retentionDays) days", trailingIsRaw: true)
            Text("Older readings are deleted on the next connection. Readings are stored about once every 15 seconds; the live display is not affected.")
                .font(.system(size: 11.5))
                .foregroundStyle(Instrument.faint)

            HStack(spacing: 8) {
                ForEach([7, 30, 90, 365], id: \.self) { days in
                    Button {
                        settings.retentionDays = days
                    } label: {
                        Text(days == 365 ? "1y" : "\(days)d")
                            .font(Instrument.mono(12))
                            .foregroundStyle(settings.retentionDays == days ? Instrument.amber : Instrument.faint)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(settings.retentionDays == days ? Instrument.amberSoft : Color.clear)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .instrumentWell(cornerRadius: 10)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }
}
