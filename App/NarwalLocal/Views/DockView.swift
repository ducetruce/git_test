import NarwalKit
import SwiftUI

/// The station in 3D, its supplies as rings, and its actions.
struct StationView: View {
    @Environment(RobotStore.self) private var store

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
                        if let minutes = store.dryingMinutesLeft {
                            Card {
                                Theme.label("Drying mops", color: Theme.teal)
                                Text("\(minutes) min left").font(.system(size: 19)).foregroundStyle(Theme.text)
                            }
                        }
                        actions.padding(.vertical, 8)
                        if !store.isDocked {
                            Text("Station actions need the robot on its dock.")
                                .font(.system(size: 13)).foregroundStyle(Theme.tertiary)
                        }
                        cartridges
                        maintenance
                        settings
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .refreshable {
                await store.refreshAll()
                await store.reloadDryingTime()
            }
            .task { await store.reloadDryingTime() }
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

    private var cartridges: some View {
        Card {
            Theme.label("Cartridges")
            let list = store.status?.station.cartridges ?? []
            if list.isEmpty {
                Text("Not reported yet.").font(.system(size: 16)).foregroundStyle(Theme.secondary)
            }
            ForEach(list) { c in
                HStack {
                    Text(c.name).font(.system(size: 16)).foregroundStyle(Theme.text)
                    Spacer()
                    Text(c.label).font(.system(size: 14)).foregroundStyle(c.needsCare ? Theme.amber : Theme.secondary)
                }
            }
            Text("The Wood Floor Maintenance Solution and the Heavy-duty Stain Remover share one slot.")
                .font(.system(size: 13)).foregroundStyle(Theme.tertiary)
        }
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
            NavigationLink {
                PartsView()
            } label: {
                HStack {
                    Text("Parts and Consumables").font(.system(size: 15)).foregroundStyle(Theme.teal)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.top, 4)
        }
    }

    private var settings: some View {
        Card {
            Theme.label("Dock settings")
            ForEach(RobotSetting.menu(.dock)) { setting in
                SettingRow(setting: setting)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.text)
                    .tint(Theme.teal)
                    .padding(.vertical, 2)
            }
            Button {
                Task { await store.drainDockBase() }
            } label: {
                Text("Dock Base Drainage").font(.system(size: 15)).foregroundStyle(Theme.teal)
            }
            .disabled(!store.allowsWrites || store.busyAction != nil)
            .padding(.vertical, 2)
        }
        .task { if store.robotSettings == nil { await store.reloadSettings() } }
    }
}
