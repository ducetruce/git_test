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
                    let station = store.status?.station
                    if station?.readings.isEmpty ?? true {
                        Text("Not reported yet").foregroundStyle(.secondary)
                    }
                    ForEach(station?.readings ?? [], id: \.part) { reading in
                        LabeledContent(reading.part) {
                            Text(reading.state)
                                .foregroundStyle(reading.alert != nil ? Color.orange : reading.state == "Unknown" ? Color.secondary : Color.green)
                        }
                    }
                    if let health = station?.dustBagHealth, health.isFinite {
                        LabeledContent("Station bag health", value: "\(Int(health))%")
                    }
                    if let detergent = station?.detergentRemaining {
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
}
