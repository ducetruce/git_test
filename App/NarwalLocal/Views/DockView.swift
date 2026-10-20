import NarwalKit
import SwiftUI

struct DockView: View {
    @Environment(RobotStore.self) private var store
    @AppStorage("dockLight") private var dockLight = AmbientLightMode.off.rawValue

    var body: some View {
        NavigationStack {
            List {
                Section("Station") {
                    station("Wash mop", "drop.triangle") { try await $0.washMop() }
                    station("Dry mop", "wind") { try await $0.dryMop() }
                    station("Empty dustbin", "arrow.down.to.line") { try await $0.emptyDustbin() }
                    station("Dry dust bag", "sun.max") { try await $0.dryDustBag() }
                    station("Dry station bag", "sun.max.fill") { try await $0.dryStationBag() }
                }
                .disabled(store.busyAction != nil || !store.isDocked)

                if !store.isDocked {
                    Text("Station actions need the robot on its dock.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Tanks & bags") {
                    let s = store.status?.station
                    tank("Clean water", s?.cleanWaterTank, bad: 2...4)
                    tank("Dirty water", s?.sewageTank, bad: 2...3)
                    tank("Dust bag", s?.dustBag, bad: 2...4)
                    tank("Station bag", s?.stationBag, bad: 2...4)
                    if let health = s?.dustBagHealth, health.isFinite {
                        LabeledContent("Dust bag health", value: "\(Int(health))%")
                    }
                    if let detergent = s?.detergentRemaining {
                        LabeledContent("Detergent", value: "\(detergent)%")
                    }
                }

                Section {
                    if let alerts = store.consumables {
                        if alerts.maintain.isEmpty && alerts.replace.isEmpty {
                            Label("Nothing needs attention", systemImage: "checkmark.circle")
                        }
                        ForEach(alerts.replaceLabels, id: \.self) { Label("Replace \($0)", systemImage: "arrow.triangle.2.circlepath") }
                        ForEach(alerts.maintainLabels, id: \.self) { Label("Clean \($0)", systemImage: "sparkles") }
                    } else {
                        Text("Not loaded yet").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Maintenance")
                } footer: {
                    Text("The robot reports which parts want attention, not how worn they are. Remaining-life percentages only come from Narwal's cloud.")
                }

                Section("Station light") {
                    Picker("Light", selection: Binding(
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
                }
            }
            .navigationTitle("Station")
            .refreshable { await store.refreshAll() }
        }
    }

    private func station(_ title: String, _ icon: String,
                         _ perform: @escaping (NarwalConnection) async throws -> Void) -> some View {
        Button {
            Task { await store.run(title, perform) }
        } label: {
            Label(title, systemImage: icon)
        }
    }

    @ViewBuilder
    private func tank(_ name: String, _ value: Int?, bad: ClosedRange<Int>) -> some View {
        LabeledContent(name) {
            switch value {
            case nil: Text("Unknown").foregroundStyle(.secondary)
            case let v? where bad.contains(v): Text("Check").foregroundStyle(.orange)
            case _?: Text("OK").foregroundStyle(.green)
            }
        }
    }
}
