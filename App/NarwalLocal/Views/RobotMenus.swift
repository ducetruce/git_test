import NarwalKit
import SwiftUI

/// One robot setting: a switch, or a row that opens its choices. Shows the
/// current value only until the owner turns on "Change robot settings".
struct SettingRow: View {
    @Environment(RobotStore.self) private var store
    @AppStorage("allowRobotWrites") private var allowWrites = false
    let setting: RobotSetting

    var body: some View {
        let settings = store.robotSettings
        Group {
            if let settings, allowWrites {
                if setting.isToggle {
                    Toggle(setting.title, isOn: Binding(
                        get: { setting.choice(in: settings)?.label == "On" },
                        set: { on in Task { await store.changeSetting(setting, to: setting.choices[on ? 1 : 0]) } }
                    ))
                } else {
                    NavigationLink {
                        ChoiceList(setting: setting)
                    } label: {
                        LabeledContent(setting.title, value: setting.label(in: settings))
                    }
                }
            } else {
                LabeledContent(setting.title, value: settings.map { setting.label(in: $0) } ?? "–")
            }
        }
        .disabled(store.busyAction != nil)
    }
}

/// A setting's choices with Narwal's descriptions, like its bottom sheets.
struct ChoiceList: View {
    @Environment(RobotStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let setting: RobotSetting

    var body: some View {
        let selected = store.robotSettings.flatMap { setting.choice(in: $0) }
        List {
            Section {
                ForEach(setting.choices, id: \.self) { choice in
                    Button {
                        Task {
                            await store.changeSetting(setting, to: choice)
                            dismiss()
                        }
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(choice.label).foregroundStyle(choice == selected ? Theme.teal : Theme.text)
                                if let detail = choice.detail {
                                    Text(detail).font(.footnote).foregroundStyle(Theme.secondary)
                                }
                            }
                            Spacer()
                            if choice == selected { Image(systemName: "checkmark").foregroundStyle(Theme.teal) }
                        }
                    }
                    .disabled(store.busyAction != nil)
                }
            } footer: {
                if let note = setting.footnote { Text(note) }
            }
        }
        .navigationTitle(setting.title)
        .navigationBarTitleDisplayMode(.inline)
        .themedList()
    }
}

/// One of the Narwal app's settings menus.
struct RobotMenuView: View {
    @Environment(RobotStore.self) private var store
    let menu: RobotSetting.Menu

    var body: some View {
        List {
            ForEach(RobotSetting.menu(menu)) { setting in
                Section {
                    SettingRow(setting: setting)
                } footer: {
                    if let note = setting.footnote { Text(note) }
                }
            }
        }
        .navigationTitle(menu.rawValue)
        .themedList()
        .refreshable { await store.reloadSettings() }
        .task { if store.robotSettings == nil { await store.reloadSettings() } }
    }
}

/// General: Do Not Disturb, Plateau Mode, Child Lock, Auto Power-Off.
struct GeneralMenuView: View {
    @Environment(RobotStore.self) private var store
    @AppStorage("allowRobotWrites") private var allowWrites = false

    var body: some View {
        List {
            QuietHoursSection(settings: store.robotSettings, editable: allowWrites && store.robotSettings != nil)
                .disabled(store.busyAction != nil)
            ForEach(RobotSetting.menu(.general)) { setting in
                Section {
                    SettingRow(setting: setting)
                } footer: {
                    if let note = setting.footnote { Text(note) }
                }
            }
        }
        .navigationTitle("General")
        .themedList()
        .task { if store.robotSettings == nil { await store.reloadSettings() } }
    }
}

/// Navo Voice Assistant: the assistant, robot language and volume.
struct VoiceMenuView: View {
    @Environment(RobotStore.self) private var store
    @AppStorage("allowRobotWrites") private var allowWrites = false
    @State private var volume: Double?

    var body: some View {
        let settings = store.robotSettings
        List {
            Section {
                if let assistant = RobotSetting.named("speechControlEnabled") { SettingRow(setting: assistant) }
            } footer: {
                Text("Say \"Hey, Nawa\", wait for its reply, then give a command.")
            }
            Section {
                if let language = RobotSetting.named("language") { SettingRow(setting: language) }
                if allowWrites, let settings {
                    VStack(alignment: .leading) {
                        LabeledContent("Volume", value: "\(Int(volume ?? Double(settings.voiceVolume)))%")
                        // Controls stay in place while a write runs: swapping a
                        // slider out mid-drag lost the next change.
                        Slider(value: Binding(get: { volume ?? Double(settings.voiceVolume) }, set: { volume = $0 }),
                               in: 0...100, step: 1, onEditingChanged: { editing in
                            guard !editing, let volume else { return }
                            Task {
                                await store.changeVolume(to: Int(volume))
                                self.volume = nil
                            }
                        })
                        .disabled(store.busyAction != nil)
                    }
                } else {
                    LabeledContent("Volume", value: settings.map { "\($0.voiceVolume)%" } ?? "–")
                }
            } footer: {
                Text("Switching to a language the robot doesn't have installed needs the Narwal app, which downloads it. Voice tone (male or female) is changed there too.")
            }
        }
        .navigationTitle("Navo Voice Assistant")
        .themedList()
        .task { if store.robotSettings == nil { await store.reloadSettings() } }
    }
}

/// Device: location, locate, restart, firmware and battery.
struct DeviceView: View {
    @Environment(RobotStore.self) private var store
    @AppStorage("allowRobotWrites") private var allowWrites = false
    @State private var confirmRestart = false

    var body: some View {
        List {
            Section {
                LabeledContent("Device Location", value: store.robotSettings?.timeZone ?? "–")
                Button("Locate Robot") { Task { await store.run("Locate") { try await $0.locate() } } }
                Button("Restart Robot") { confirmRestart = true }
                    .disabled(!allowWrites)
            } footer: {
                Text("Locate plays a voice prompt so you can find the robot.")
            }
            Section("Firmware") {
                LabeledContent("Robot", value: store.firmware?.robot ?? store.deviceInfo?.firmware ?? "–")
                ForEach(store.firmware?.parts ?? [], id: \.self) { part in
                    LabeledContent(part.name, value: part.version)
                }
            }
            Section {
                if let battery = store.battery {
                    if let health = battery.capacityPercent { LabeledContent("Capacity", value: "\(health)%") }
                    if let cycles = battery.cycles { LabeledContent("Charge cycles", value: "\(cycles)") }
                    if let temperature = battery.temperature, temperature.isFinite {
                        LabeledContent("Temperature", value: String(format: "%.0f °C", temperature))
                    }
                } else {
                    Text("Not reported.").foregroundStyle(Theme.secondary)
                }
            } header: {
                Text("Battery")
            } footer: {
                Text("Firmware updates need the Narwal app; it downloads them from Narwal.")
            }
        }
        .navigationTitle("Device")
        .themedList()
        .task { await store.reloadDeviceInfo() }
        .refreshable { await store.reloadDeviceInfo() }
        .confirmationDialog("Restart the robot?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart", role: .destructive) { Task { await store.reboot() } }
        } message: {
            Text("It stops what it's doing and is offline for about a minute.")
        }
    }
}

/// Map management: maps, cleaning order, No stairs, mapping.
struct MapManagementView: View {
    @Environment(RobotStore.self) private var store
    @AppStorage("allowRobotWrites") private var allowWrites = false
    @State private var confirm: Confirm?

    enum Confirm: Identifiable {
        case newMap, remap, delete(MapSummary), switchTo(MapSummary)
        var id: String {
            switch self {
            case .newMap: return "new"
            case .remap: return "remap"
            case .delete(let m): return "delete\(m.id)"
            case .switchTo(let m): return "switch\(m.id)"
            }
        }
    }

    var body: some View {
        let current = store.map
        List {
            if let current {
                Section {
                    LabeledContent("Map", value: current.customName.isEmpty
                                   ? (current.isMainMap || current.hasStation ? "Main Map" : "Secondary map") : current.customName)
                    NavigationLink("Cleaning order") { CleaningOrderView() }
                    Toggle("No stairs", isOn: Binding(
                        get: { store.robotSettings?.noStairs(mapId: current.mapId) ?? false },
                        set: { on in Task { await store.changeNoStairs(on, mapId: current.mapId) } }
                    ))
                    .disabled(!allowWrites || store.robotSettings == nil || store.busyAction != nil)
                    Button("Rotate map 90°") {
                        Task { await store.applyMapEdit(.rotateMap(degrees: (current.rotation + 90) % 360), "Rotate map") }
                    }
                    .disabled(!allowWrites)
                    Button("Remapping") { confirm = .remap }.disabled(!allowWrites)
                } header: {
                    Text("Map in use")
                } footer: {
                    Text("No stairs: the robot climbs thresholds more boldly. Leave it off if this floor has stairs, so the robot keeps watching for drops. Map editing is in the Clean tab.")
                }
            }

            Section {
                ForEach(store.maps ?? []) { map in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(map.title)
                            Text(map.hasDock ? "With dock" : "No dock")
                                .font(.footnote).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        if map.id == current?.mapId {
                            Text("In use").font(.footnote).foregroundStyle(Theme.teal)
                        } else {
                            Menu {
                                Button("Use this map") { confirm = .switchTo(map) }
                                if !map.isMain { Button("Delete", role: .destructive) { confirm = .delete(map) } }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .disabled(!allowWrites)
                        }
                    }
                }
                if (store.maps?.count ?? 0) < 4 {
                    Button("New secondary map") { confirm = .newMap }.disabled(!allowWrites)
                }
            } header: {
                Text("Saved maps")
            } footer: {
                Text("Up to 4 maps. Secondary maps are for another floor or a closed-off area: they have no dock, can't have schedules and can't become the main map.")
            }
        }
        .navigationTitle("Map management")
        .themedList()
        .task {
            await store.reloadMaps()
            if store.robotSettings == nil { await store.reloadSettings() }
        }
        .refreshable { await store.reloadMaps() }
        .alert(title, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button(actionTitle, role: isDestructive ? .destructive : nil) { act() }
            Button("Cancel", role: .cancel) { confirm = nil }
        } message: {
            Text(message)
        }
    }

    private var title: String {
        switch confirm {
        case .newMap: return "New secondary map?"
        case .remap: return "Remap this floor?"
        case .delete(let m): return "Delete \(m.title)?"
        case .switchTo(let m): return "Use \(m.title)?"
        case nil: return ""
        }
    }

    private var actionTitle: String {
        switch confirm {
        case .newMap, .remap: return "Start mapping"
        case .delete: return "Delete"
        default: return "Use map"
        }
    }

    private var isDestructive: Bool {
        if case .delete = confirm { return true }
        if case .remap = confirm { return true }
        return false
    }

    private var message: String {
        switch confirm {
        case .newMap:
            return "Carry the robot to the new area and set it down in an open spot. It maps from there and returns to that spot when done. Open the doors of rooms to map and close the others."
        case .remap:
            return "The robot maps this floor again from the dock. Rooms, zones and furniture you've set may need redoing."
        case .delete:
            return "The map and its rooms, zones and settings are removed from the robot."
        case .switchTo:
            return "The robot uses this map from now on. Put it on that floor first."
        case nil:
            return ""
        }
    }

    private func act() {
        guard let pending = confirm else { return }
        confirm = nil
        Task {
            switch pending {
            case .newMap: await store.startMapping(rebuildCurrent: false)
            case .remap: await store.startMapping(rebuildCurrent: true)
            case .delete(let m): await store.deleteMap(m.id)
            case .switchTo(let m): await store.switchMap(to: m.id)
            }
        }
    }
}

/// House Cleaning Order: drag rooms into the order whole-house cleans use.
struct CleaningOrderView: View {
    @Environment(RobotStore.self) private var store
    @AppStorage("allowRobotWrites") private var allowWrites = false
    @State private var order: [Int] = []

    var body: some View {
        List {
            Section {
                ForEach(Array(order.enumerated()), id: \.element) { index, id in
                    HStack(spacing: 14) {
                        Text("\(index + 1)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.teal)
                            .frame(width: 24)
                        Text(store.map?.rooms.first { $0.id == id }?.displayName ?? "Room \(id)")
                    }
                }
                .onMove { order.move(fromOffsets: $0, toOffset: $1) }
            } footer: {
                Text("Drag rooms to set the order whole-house cleans follow.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("House Cleaning Order")
        .themedList()
        .toolbar {
            Button("Save") { Task { await store.saveCleaningOrder(order) } }
                .disabled(!allowWrites || order == store.cleaningOrder || store.busyAction != nil)
        }
        .onAppear { order = store.cleaningOrder }
    }
}

/// Parts and Consumables: hours left, cartridges and parts to wipe.
struct PartsView: View {
    @Environment(RobotStore.self) private var store
    @State private var editing: PartLife?
    @State private var hoursText = ""
    @State private var replacing: PartLife?
    @State private var refresh = 0

    var body: some View {
        List {
            Section {
                ForEach(PartLife.all) { part in
                    let left = part.hoursLeft(store.ledger, store.history)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(part.name)
                            Spacer()
                            Menu {
                                Button("Replaced it") { replacing = part }
                                Button("Set hours from the Narwal app") {
                                    hoursText = left.map { String(Int($0.rounded())) } ?? ""
                                    editing = part
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle").foregroundStyle(Theme.secondary)
                            }
                        }
                        if let left {
                            Text("\(Int(left.rounded())) hours left until replacement")
                                .font(.footnote).foregroundStyle(left < 10 ? Theme.amber : Theme.secondary)
                            ProgressView(value: min(1, left / part.ratedHours)).tint(left < 10 ? Theme.amber : Theme.teal)
                        } else {
                            Text("Not counting yet. Set the hours the Narwal app shows, or tap Replaced when you fit a new one.")
                                .font(.footnote).foregroundStyle(Theme.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .id("\(part.id)-\(refresh)")
                }
                if let health = store.status?.station.dustBagHealth, health.isFinite {
                    LabeledContent("Base station disinfection dust bag", value: "\(Int(health.rounded()))% health")
                }
            } header: {
                Text("Replace")
            } footer: {
                Text("The robot doesn't report hours to this app, so it counts cleaning time itself: the cleans it saw, plus the robot's other cleans at their usual length.")
            }

            Section("Cartridges") {
                let cartridges = store.status?.station.cartridges ?? []
                if cartridges.isEmpty { Text("Not reported yet.").foregroundStyle(Theme.secondary) }
                ForEach(cartridges) { c in
                    LabeledContent(c.name, value: c.label)
                        .foregroundStyle(c.needsCare ? Theme.amber : Theme.text)
                }
            }

            Section {
                let due = store.consumables?.maintainLabels ?? []
                ForEach(due, id: \.self) { label in
                    LabeledContent(label.capitalized, value: "Clean now").foregroundStyle(Theme.amber)
                }
                if due.isEmpty, store.consumables != nil {
                    Text("Nothing needs cleaning right now.").foregroundStyle(Theme.secondary)
                }
            } header: {
                Text("Clean regularly")
            } footer: {
                Text("Wipe the cleaning tray, sensors and caster, and rinse the sponge filter, every few weeks. The robot flags them here when they need it.")
            }
        }
        .navigationTitle("Parts and Consumables")
        .themedList()
        .refreshable { await store.refreshAll() }
        .alert("Hours left", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Hours", text: $hoursText).keyboardType(.numberPad)
            Button("Save") {
                if let part = editing, let hours = Double(hoursText) { part.setStart(hoursLeft: hours) }
                editing = nil
                refresh += 1
            }
            Button("Cancel", role: .cancel) { editing = nil }
        } message: {
            Text("Enter the hours the Narwal app shows for \(editing?.name ?? "this part").")
        }
        .confirmationDialog("Replaced the \(replacing?.name.lowercased() ?? "part")?", isPresented: Binding(
            get: { replacing != nil }, set: { if !$0 { replacing = nil } }), titleVisibility: .visible) {
            Button("Yes, start counting again") {
                if let part = replacing { Task { await store.replacedPart(part); refresh += 1 } }
                replacing = nil
            }
        } message: {
            Text("Starts its count again and tells the robot.")
        }
    }
}
