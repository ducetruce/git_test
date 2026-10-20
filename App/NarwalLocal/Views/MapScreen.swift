import NarwalKit
import SwiftUI

struct MapScreen: View {
    @Environment(RobotStore.self) private var store
    enum Mode: String, CaseIterable { case rooms = "Rooms", zones = "Zones" }

    @State private var mode = Mode.rooms
    /// Selection order is cleaning order.
    @State private var selected: [Int] = []
    @State private var zones: [Payloads.Zone] = []
    @State private var showingSetup = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let map = store.map {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding([.horizontal, .top])
                    MapCanvas(
                        map: map,
                        selected: mode == .rooms ? selected : [],
                        pose: store.pose,
                        trail: store.trail,
                        zones: mode == .zones ? zones : [],
                        onTapRoom: { room in
                            if let index = selected.firstIndex(of: room) {
                                selected.remove(at: index)
                            } else {
                                selected.append(room)
                            }
                        },
                        onDrawZone: mode == .zones ? { (zone: Payloads.Zone) in zones.append(zone) } : nil
                    )
                    .padding()
                    if let age = poseAge, store.isCleaning, age > 30 {
                        Label("Live position is \(Int(age)) s old. Reconnecting the feed…", systemImage: "antenna.radiowaves.left.and.right.slash")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .padding(.bottom, 4)
                    }
                    bottomBar(map)
                } else {
                    ContentUnavailableView {
                        Label("No map yet", systemImage: "map")
                    } description: {
                        Text("The robot sends its map once it's awake.")
                    } actions: {
                        Button("Load map") { Task { await store.reloadMap() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Map")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await store.reloadMap() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(store.busyAction != nil)
                }
            }
            .sheet(isPresented: $showingSetup) {
                if let map = store.map {
                    CleanSetupSheet(map: map, rooms: $selected, zones: mode == .zones ? zones : [])
                }
            }
            .onChange(of: store.map?.mapId) { _, _ in
                // A different map means different room ids and coordinates.
                let valid = Set(store.map?.rooms.map(\.id) ?? [])
                selected.removeAll { !valid.contains($0) }
                zones = []
            }
        }
    }

    private func hint(_ map: RobotMap) -> String {
        switch mode {
        case .rooms:
            return selected.isEmpty
                ? "Tap rooms to choose them. They'll be cleaned in the order you tap."
                : selected.compactMap { id in map.rooms.first { $0.id == id }?.displayName }.joined(separator: " → ")
        case .zones:
            return zones.isEmpty ? "Drag on the map to draw a rectangle to clean." : "\(zones.count) zone\(zones.count == 1 ? "" : "s"). Drag to add more."
        }
    }

    private var buttonTitle: String {
        switch mode {
        case .rooms:
            return selected.isEmpty ? "Clean whole house…" : "Clean \(selected.count) room\(selected.count == 1 ? "" : "s")…"
        case .zones:
            return "Clean \(zones.count) zone\(zones.count == 1 ? "" : "s")…"
        }
    }

    private var poseAge: TimeInterval? {
        store.poseUpdatedAt.map { Date().timeIntervalSince($0) }
    }

    @ViewBuilder
    private func bottomBar(_ map: RobotMap) -> some View {
        VStack(spacing: 8) {
            Text(hint(map))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                if mode == .rooms ? !selected.isEmpty : !zones.isEmpty {
                    Button("Clear") {
                        if mode == .rooms { selected = [] } else { zones = [] }
                    }
                    .buttonStyle(.bordered)
                }
                if mode == .zones, !zones.isEmpty {
                    Button("Undo") { zones.removeLast() }.buttonStyle(.bordered)
                }
                Button {
                    showingSetup = true
                } label: {
                    Text(buttonTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.busyAction != nil || store.isCleaning || (mode == .zones && zones.isEmpty))
            }
        }
        .padding()
        .background(.bar)
    }
}

struct CleanSetupSheet: View {
    @Environment(RobotStore.self) private var store
    @Environment(PresetStore.self) private var presets
    @Environment(\.dismiss) private var dismiss

    let map: RobotMap
    @Binding var rooms: [Int]
    /// Non-empty means a zone clean; rooms are ignored.
    var zones: [Payloads.Zone] = []

    @State private var settings = CleanSettings()
    @State private var perRoom: [Int: CleanSettings] = [:]
    @State private var presetName = ""
    @State private var savingPreset = false

    var body: some View {
        NavigationStack {
            Form {
                if !zones.isEmpty {
                    Section("Zones") {
                        Text("\(zones.count) drawn zone\(zones.count == 1 ? "" : "s")")
                    }
                } else {
                Section {
                    if rooms.isEmpty {
                        Text("Whole house")
                    } else {
                        ForEach(rooms, id: \.self) { id in
                            let room = map.rooms.first { $0.id == id }
                            NavigationLink {
                                RoomOverrideView(name: room?.displayName ?? "Room \(id)",
                                                 base: settings,
                                                 override: Binding(get: { perRoom[id] }, set: { perRoom[id] = $0 }))
                            } label: {
                                HStack {
                                    Circle().fill(MapPalette.color(forRoom: id)).frame(width: 10, height: 10)
                                    Text(room?.displayName ?? "Room \(id)")
                                    Spacer()
                                    if let custom = perRoom[id] {
                                        Text(custom.workMode.label).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .onMove { rooms.move(fromOffsets: $0, toOffset: $1) }
                    }
                } header: {
                    HStack {
                        Text("Rooms (in order)")
                        Spacer()
                        if rooms.count > 1 { EditButton().font(.caption) }
                    }
                }
                }
                SettingsFields(settings: $settings)
                Section {
                    Button("Save as routine…") { savingPreset = true }
                }
            }
            .navigationTitle("Clean setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        Task {
                            if !zones.isEmpty {
                                await store.cleanZones(zones, settings: settings)
                            } else if rooms.isEmpty {
                                await store.cleanAll(settings: settings)
                            } else {
                                await store.cleanRooms(rooms, settings: settings, perRoom: perRoom)
                            }
                            if store.lastError == nil { dismiss() }
                        }
                    }
                    .disabled(store.busyAction != nil)
                }
            }
            .alert("Save routine", isPresented: $savingPreset) {
                TextField("Name", text: $presetName)
                Button("Save") {
                    presets.save(CleanPreset(name: presetName.isEmpty ? "Routine" : presetName,
                                             rooms: zones.isEmpty ? rooms : [], settings: settings,
                                             perRoom: zones.isEmpty ? perRoom : [:],
                                             zones: zones.isEmpty ? nil : zones))
                    presetName = ""
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

struct SettingsFields: View {
    @Binding var settings: CleanSettings

    var body: some View {
        Section("Mode") {
            Picker("Mode", selection: $settings.workMode) {
                ForEach(WorkMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Stepper("Passes: \(settings.passes)", value: $settings.passes, in: 1...3)
            Picker("Route", selection: Binding(
                get: { settings.route ?? .standard },
                set: { settings.route = $0 }
            )) {
                ForEach(CleaningRoute.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        }
        if settings.workMode != .mop {
            Section("Vacuum") {
                Picker("Suction", selection: $settings.fan) {
                    ForEach(FanLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
        }
        if settings.workMode != .vacuum {
            Section("Mop") {
                Picker("Water", selection: $settings.water) {
                    ForEach(MopHumidity.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Scrubbing", selection: $settings.mopStrength) {
                    ForEach(MopStrength.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
        }
    }
}

private struct RoomOverrideView: View {
    let name: String
    let base: CleanSettings
    @Binding var override: CleanSettings?

    var body: some View {
        Form {
            Toggle("Custom settings for this room", isOn: Binding(
                get: { override != nil },
                set: { override = $0 ? base : nil }
            ))
            if override != nil {
                SettingsFields(settings: Binding(get: { override ?? base }, set: { override = $0 }))
            }
        }
        .navigationTitle(name)
    }
}
