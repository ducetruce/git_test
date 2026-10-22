import NarwalKit
import SwiftUI

/// The station in 3D, its supplies as rings, and its actions.
struct StationView: View {
    @Environment(RobotStore.self) private var store
    @AppStorage("dockLight") private var dockLight = AmbientLightMode.off.rawValue

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Theme.label(store.isDocked ? "Robot docked" : "Robot away")
                        Text("Station").font(.system(size: 28)).foregroundStyle(Theme.text)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)

                    RobotModelView(shot: .station, mood: store.status?.isCharging == true ? .charging : .idle)
                        .frame(height: 250)
                        .accessibilityLabel("The station")

                    VStack(spacing: 14) {
                        rings.padding(.bottom, 8)
                        if let note = comingUp { note }
                        actions.padding(.vertical, 8)
                        if !store.isDocked {
                            Text("Station actions need the robot on its dock.")
                                .font(.system(size: 13)).foregroundStyle(Theme.tertiary)
                        }
                        maintenance
                        settings
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .refreshable { await store.refreshAll() }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var readings: [StationState.Reading] { store.status?.station.readings ?? [] }

    private func reading(_ part: String) -> StationState.Reading? {
        readings.first { $0.part.localizedCaseInsensitiveContains(part) }
    }

    private var rings: some View {
        HStack {
            tankRing(reading("Clean water"), label: "Clean water", color: Theme.blue)
            Spacer()
            tankRing(reading("Dirty water"), label: "Dirty water", color: Theme.teal)
            Spacer()
            let bag = store.status?.station.dustBagHealth.flatMap { $0.isFinite ? Double($0) : nil }
            ScoreRing(value: bag.map { "\(Int($0.rounded()))" } ?? "–", label: "Bag health",
                      fraction: bag.map { $0 / 100 }, color: Theme.amber)
        }
        .padding(.horizontal, 8)
    }

    /// Tanks report a state, not a level: a full ring when fine, short and
    /// amber when they need you.
    private func tankRing(_ reading: StationState.Reading?, label: String, color: Color) -> some View {
        guard let reading else {
            return ScoreRing(value: "–", label: label, fraction: nil, color: color)
        }
        let fine = !reading.needsCare && reading.state != "Unknown"
        return ScoreRing(value: fine ? "OK" : reading.state, label: label,
                         fraction: fine ? 1 : 0.15, color: fine ? color : Theme.amber)
    }

    private var comingUp: Card<AnyView>? {
        let problems = readings.filter(\.needsCare)
        guard !problems.isEmpty else { return nil }
        return Card {
            AnyView(VStack(alignment: .leading, spacing: 8) {
                Theme.label(problems.contains { $0.alert != nil } ? "Needs you" : "Coming up", color: Theme.amber)
                ForEach(problems, id: \.part) { p in
                    Text("\(p.part): \(p.state.lowercased())").font(.system(size: 17)).foregroundStyle(Theme.text)
                }
                if !problems.contains(where: { $0.alert != nil }) {
                    Text("Nothing to do yet. You'll get one alert when it actually needs you.")
                        .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                }
            })
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            RoundAction(title: "Wash mops", icon: "drop") { run("Wash mops") { try await $0.washMop() } }
            RoundAction(title: "Dry mops", icon: "wind") { run("Dry mops") { try await $0.dryMop() } }
            RoundAction(title: "Empty bin", icon: "arrow.down.to.line") { run("Empty dustbin") { try await $0.emptyDustbin() } }
            Menu {
                Button("Dry the dust bag") { run("Dry dust bag") { try await $0.dryDustBag() } }
                Button("Dry the station bag") { run("Dry station bag") { try await $0.dryStationBag() } }
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "sun.max")
                        .font(.system(size: 19))
                        .frame(width: 54, height: 54)
                        .background(Theme.card, in: Circle())
                        .foregroundStyle(Theme.text)
                    Text("Dry bags").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .disabled(store.busyAction != nil || !store.isDocked)
    }

    private func run(_ title: String, _ action: @escaping (NarwalConnection) async throws -> Void) {
        Task { await store.run(title, action) }
    }

    private var maintenance: some View {
        Card {
            Theme.label("Parts")
            if let alerts = store.consumables {
                if alerts.maintain.isEmpty && alerts.replace.isEmpty {
                    Text("Nothing needs attention.").font(.system(size: 16)).foregroundStyle(Theme.text)
                }
                ForEach(alerts.replaceLabels, id: \.self) {
                    Text("Replace \($0)").font(.system(size: 16)).foregroundStyle(Theme.amber)
                }
                ForEach(alerts.maintainLabels, id: \.self) {
                    Text("Clean \($0)").font(.system(size: 16)).foregroundStyle(Theme.text)
                }
            } else {
                Text("Not loaded yet.").font(.system(size: 16)).foregroundStyle(Theme.secondary)
            }
            if let detergent = store.status?.station.detergentRemaining {
                Text("Detergent \(detergent)%").font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
        }
    }

    private var settings: some View {
        Card {
            Theme.label("Station settings")
            ForEach(RobotSettingKey.all.filter { $0.group == .mopping }) { key in
                RobotSettingRow(key: key)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.text)
                    .tint(Theme.teal)
                    .padding(.vertical, 2)
            }
            HStack {
                Text("Station light").font(.system(size: 15)).foregroundStyle(Theme.text)
                Spacer()
                Picker("Station light", selection: Binding(
                    get: { AmbientLightMode(rawValue: store.status?.dockLightMode ?? dockLight) ?? .off },
                    set: { mode in
                        dockLight = mode.rawValue
                        Task { await store.run("Station light") { try await $0.setAmbientLight(mode) } }
                    }
                )) {
                    Text("Off").tag(AmbientLightMode.off)
                    Text("Night light").tag(AmbientLightMode.nightLight)
                    Text("Warm").tag(AmbientLightMode.winterWarmth)
                    Text("Purple").tag(AmbientLightMode.purple)
                }
                .pickerStyle(.menu)
                .tint(Theme.secondary)
            }
        }
        .task { if store.robotSettings == nil { await store.reloadSettings() } }
    }
}
