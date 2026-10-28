import NarwalKit
import SwiftUI

struct MapScreen: View {
    @Environment(RobotStore.self) private var store
    enum Mode: String, CaseIterable { case rooms = "Rooms", zones = "Zones", edit = "Edit" }

    enum EditTool: String, CaseIterable, Identifiable {
        case select = "Select", noGo = "No-go zone", wall = "Virtual wall", carpet = "Add carpet",
             noCarpet = "Not a carpet", split = "Split room"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .select: return "hand.tap"
            case .noGo: return "nosign"
            case .wall: return "line.diagonal"
            case .carpet: return "square.grid.3x3.fill"
            case .noCarpet: return "square.slash"
            case .split: return "scissors"
            }
        }
        var hint: String {
            switch self {
            case .select: return "Tap a room, carpet, no-go zone, wall or piece of furniture to change it."
            case .noGo: return "Drag a rectangle the robot must stay out of."
            case .wall: return "Drag a line the robot must not cross."
            case .carpet: return "Drag a rectangle over a carpet the robot missed."
            case .noCarpet: return "Drag over a spot the robot wrongly thinks is carpet."
            case .split: return "Drag a line across a room to split it in two."
            }
        }
    }

    @State private var mode = Mode.rooms
    /// Selection order is cleaning order.
    @State private var selected: [Int] = []
    @State private var zones: [Payloads.Zone] = []
    @State private var showingSetup = false
    @AppStorage("mapShowFurniture") private var showFurniture = true
    @AppStorage("mapShowCarpets") private var showCarpets = true
    @AppStorage("map3D") private var show3D = true
    @State private var showingCarpets = false
    @State private var highlightCarpet: Int?
    @State private var tool = EditTool.select
    @State private var noGoKind = NoGoZone.Kind.noVacuumOrMop
    @State private var picked: MapItem?
    @State private var pending: PendingEdit?
    @State private var renaming: Room?
    @State private var newName = ""
    @State private var merging: Room?
    @State private var retyping: Furniture?
    @State private var flooring: Room?
    @State private var typing: Room?
    @State private var showingMaintenance = false

    struct PendingEdit: Identifiable {
        let id = UUID()
        let edit: MapEdit
        let title: String
    }
    // Pinch to zoom; drag to pan (in Rooms mode, where a drag isn't drawing).
    @State private var zoom: CGFloat = 1
    @State private var zoomAtGestureStart: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panAtGestureStart: CGSize = .zero

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let map = store.map {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding([.horizontal, .top])
                    if show3D && mode == .rooms {
                        // The room tiles get their own row under the map, never
                        // on top of it.
                        Map3DView(map: map, selected: selected, pose: store.pose)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .layoutPriority(-1)
                        RoomChips(map: map, selected: $selected)
                            .frame(height: 56)
                            .background(Theme.background)
                            .zIndex(1)
                    } else {
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
                        onDrawZone: drawZoneHandler(map),
                        zoom: zoom,
                        showFurniture: showFurniture,
                        showCarpets: showCarpets,
                        highlightCarpet: highlightCarpet,
                        onDrawLine: mode == .edit && (tool == .wall || tool == .split)
                            ? { a, b in drewLine(a, b, map) } : nil,
                        onTapPoint: mode == .edit && tool == .select
                            ? { p in picked = map.item(at: p) } : nil
                    )
                    .padding()
                    .scaleEffect(zoom)
                    .offset(pan)
                    .contentShape(Rectangle())
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in zoom = min(max(zoomAtGestureStart * value.magnification, 1), 8) }
                            .onEnded { _ in
                                zoomAtGestureStart = zoom
                                if zoom == 1 { resetZoom() }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                guard zoom > 1 else { return }
                                pan = CGSize(width: panAtGestureStart.width + value.translation.width,
                                             height: panAtGestureStart.height + value.translation.height)
                            }
                            .onEnded { _ in panAtGestureStart = pan },
                        including: mode == .rooms || (mode == .edit && tool == .select) ? .all : .subviews
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .layoutPriority(-1)
                    .overlay(alignment: .topTrailing) {
                        if zoom > 1 {
                            Button {
                                withAnimation(.easeOut(duration: 0.25)) { resetZoom() }
                            } label: {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                    .padding(10)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .padding()
                            .accessibilityLabel("Reset zoom")
                        }
                    }
                    }
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
            .navigationTitle("Clean")
            .background(Theme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Toggle("Carpets", isOn: $showCarpets)
                        Toggle("Furniture", isOn: $showFurniture)
                        Button("Carpet settings…") { showingCarpets = true }
                    } label: {
                        Image(systemName: "square.3.layers.3d")
                    }
                    .accessibilityLabel("Map layers")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(show3D ? "2D" : "3D") { show3D.toggle() }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityLabel(show3D ? "Show flat map" : "Show 3D map")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await store.reloadMap() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(store.busyAction != nil)
                        .accessibilityLabel("Reload map")
                }
            }
            .confirmationDialog(pickedTitle, isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } }),
                                titleVisibility: .visible, presenting: picked) { item in
                pickedActions(item)
            }
            .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                titleVisibility: .visible, presenting: pending) { change in
                Button("Save to robot") { Task { await store.applyMapEdit(change.edit, change.title) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The app reads the map back afterwards and tells you if the robot didn't apply it.")
            }
            .alert("Rename room", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") {
                    if let room = renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        Task { await store.applyMapEdit(.renameRoom(room, to: name), "Rename to \(name)") }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $merging) { room in
                if let map = store.map {
                    RoomPicker(title: "Merge \(room.displayName) with…", rooms: map.rooms.filter { $0.id != room.id }) { other in
                        confirmAfterSheet(PendingEdit(edit: .mergeRooms(room.id, other.id),
                                                      title: "Merge \(room.displayName) and \(other.displayName)?"))
                    }
                }
            }
            .sheet(item: $retyping) { item in
                FurnitureTypePicker(current: item.type) { type in
                    confirmAfterSheet(PendingEdit(edit: .retypeFurniture(item, to: type),
                                                  title: "Change \(item.name) to \(Furniture.names[type] ?? "Object")?"))
                }
            }
            .sheet(item: $flooring) { room in
                FloorMaterialPicker(room: room) { floor, angle in
                    confirmAfterSheet(PendingEdit(edit: .setFloor(room, floor, angle: angle),
                                                  title: "Set \(room.displayName) to \(floor.label)?"))
                }
            }
            .sheet(item: $typing) { room in
                RoomTypePicker(current: room.roomType) { type in
                    confirmAfterSheet(PendingEdit(edit: .setRoomType(room, type),
                                                  title: "Make \(room.displayName) a \(RoomType.names[type] ?? "room")?"))
                }
            }
            .sheet(isPresented: $showingMaintenance) {
                if let map = store.map {
                    FloorMaintenanceSheet(map: map, preselected: selected)
                }
            }
            .sheet(isPresented: $showingCarpets, onDismiss: { highlightCarpet = nil }) {
                if let map = store.map {
                    CarpetsSheet(map: map, highlight: $highlightCarpet)
                        .presentationDetents([.medium, .large])
                        .presentationBackgroundInteraction(.enabled)
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

    // MARK: Editing

    private func drawZoneHandler(_ map: RobotMap) -> ((Payloads.Zone) -> Void)? {
        switch mode {
        case .zones: return { zones.append($0) }
        case .edit where tool == .noGo || tool == .carpet || tool == .noCarpet: return { drewZone($0, map) }
        default: return nil
        }
    }

    private func drewZone(_ zone: Payloads.Zone, _ map: RobotMap) {
        let corners = RobotMap.corners(zone)
        let origin = (x: map.originX, y: map.originY)
        switch tool {
        case .noGo:
            pending = PendingEdit(edit: .addNoGoZone(id: map.nextId(map.noGoZones.map(\.id)), kind: noGoKind, corners: corners),
                                  title: "Add this \(noGoKind.label.lowercased()) zone?")
        case .carpet:
            pending = PendingEdit(edit: .addCarpet(id: map.nextId(map.carpets.map(\.id)), corners: corners,
                                                   gridInPixels: map.carpetGridInPixels, origin: origin),
                                  title: "Add a carpet here?")
        case .noCarpet:
            pending = PendingEdit(edit: .addNoCarpetArea(id: map.nextId(map.noCarpetAreaIds), corners: corners,
                                                         gridInPixels: map.carpetGridInPixels, origin: origin),
                                  title: "Mark this area as not carpet?")
        default: break
        }
    }

    /// A dialog can't open while a sheet is still closing.
    private func confirmAfterSheet(_ edit: PendingEdit) {
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            pending = edit
        }
    }

    private func drewLine(_ a: MapPoint, _ b: MapPoint, _ map: RobotMap) {
        if tool == .wall {
            pending = PendingEdit(edit: .addWall(id: map.nextId(map.virtualWalls.map(\.id)), from: a, to: b),
                                  title: "Add this virtual wall?")
            return
        }
        let mid = map.gridPoint(for: MapPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
        guard let roomId = map.roomId(atGridX: Int(mid.x), y: Int(mid.y)),
              let room = map.rooms.first(where: { $0.id == roomId }) else {
            store.lastError = "Draw the line across the middle of a room."
            return
        }
        pending = PendingEdit(edit: .splitRoom(room.id, from: a, to: b), title: "Split \(room.displayName) along this line?")
    }

    private var pickedTitle: String {
        switch picked {
        case .noGoZone(let zone): return zone.kind.label + " zone"
        case .wall: return "Virtual wall"
        case .furniture(let item): return item.name
        case .carpet: return "Carpet"
        case .room(let room): return room.displayName
        case nil: return ""
        }
    }

    @ViewBuilder
    private func pickedActions(_ item: MapItem) -> some View {
        switch item {
        case .noGoZone(let zone):
            Button("Delete zone", role: .destructive) {
                pending = PendingEdit(edit: .deleteNoGoZone(zone), title: "Delete this zone?")
            }
        case .wall(let wall):
            Button("Delete wall", role: .destructive) {
                pending = PendingEdit(edit: .deleteWall(wall), title: "Delete this wall?")
            }
        case .furniture(let furniture):
            Button("Change type…") { retyping = furniture }
            Button("Delete \(furniture.name)", role: .destructive) {
                pending = PendingEdit(edit: .deleteFurniture(furniture), title: "Delete \(furniture.name) from the map?")
            }
        case .carpet(let carpet):
            Button("Carpet settings…") { highlightCarpet = carpet.id; showingCarpets = true }
            if carpet.roomId != nil {
                Button(carpet.isFullRoom ? "Not the whole room" : "Whole room is carpet") {
                    pending = PendingEdit(edit: .setWholeRoomCarpet(carpet, !carpet.isFullRoom),
                                          title: carpet.isFullRoom ? "Stop treating the whole room as carpet?" : "Treat the whole room as carpet?")
                }
            }
            Button("Delete carpet", role: .destructive) {
                pending = PendingEdit(edit: .deleteCarpet(carpet.id), title: "Delete this carpet?")
            }
        case .room(let room):
            Button("Rename…") { newName = room.userName; renaming = room }
            Button("Floor material…") { flooring = room }
            Button(room.isHeavilySoiled ? "Room character: No character" : "Room character: Heavily Soiled Room") {
                pending = PendingEdit(edit: .setHeavilySoiled(room, !room.isHeavilySoiled),
                                      title: room.isHeavilySoiled ? "Set \(room.displayName) to No character?"
                                          : "Mark \(room.displayName) as a Heavily Soiled Room?")
            }
            Button("Room type…") { typing = room }
            Button("Merge with…") { merging = room }
        }
        Button("Cancel", role: .cancel) {}
    }

    private func hint(_ map: RobotMap) -> String {
        switch mode {
        case .edit:
            return tool.hint
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
        case .edit:
            return ""
        case .rooms:
            return selected.isEmpty ? "Clean whole house…" : "Clean \(selected.count) room\(selected.count == 1 ? "" : "s")…"
        case .zones:
            return "Clean \(zones.count) zone\(zones.count == 1 ? "" : "s")…"
        }
    }

    private func resetZoom() {
        zoom = 1
        zoomAtGestureStart = 1
        pan = .zero
        panAtGestureStart = .zero
    }

    private var poseAge: TimeInterval? {
        store.poseUpdatedAt.map { Date().timeIntervalSince($0) }
    }

    @ViewBuilder
    private func bottomBar(_ map: RobotMap) -> some View {
        if mode == .edit {
            editBar(map)
        } else {
            cleanBar(map)
        }
    }

    private func editBar(_ map: RobotMap) -> some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Tool", selection: $tool) {
                    ForEach(EditTool.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.menu)
                if tool == .noGo {
                    Picker("Keep out", selection: $noGoKind) {
                        Text("Vacuum & mop").tag(NoGoZone.Kind.noVacuumOrMop)
                        Text("Mopping").tag(NoGoZone.Kind.noMop)
                        Text("Vacuuming").tag(NoGoZone.Kind.noVacuum)
                    }
                    .pickerStyle(.menu)
                }
            }
            Text(tool.hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.background)
        .zIndex(1)
        .disabled(store.busyAction != nil)
    }

    @ViewBuilder
    private func cleanBar(_ map: RobotMap) -> some View {
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
                if mode == .rooms, selected.isEmpty || store.woodRooms.contains(where: { selected.contains($0.id) }) {
                    Button {
                        showingMaintenance = true
                    } label: {
                        Label("Floor care", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.busyAction != nil || store.isCleaning)
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
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.background)
        .zIndex(1)
    }
}

/// In 3D, rooms are picked from chips (in cleaning order) rather than taps.
struct RoomChips: View {
    let map: RobotMap
    @Binding var selected: [Int]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(map.rooms) { room in
                    let order = selected.firstIndex(of: room.id).map { $0 + 1 }
                    Button {
                        if let i = selected.firstIndex(of: room.id) { selected.remove(at: i) } else { selected.append(room.id) }
                    } label: {
                        Text(order.map { "\($0) · \(room.displayName)" } ?? room.displayName)
                            .font(.subheadline.weight(order == nil ? .regular : .semibold))
                            .foregroundStyle(order == nil ? Theme.text : Theme.background)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background {
                                if order == nil { Capsule().stroke(Theme.hairline) } else { Capsule().fill(Theme.teal) }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

/// Picks one room, e.g. to merge with.
struct RoomPicker: View {
    let title: String
    let rooms: [Room]
    let onPick: (Room) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(rooms) { room in
                Button(room.displayName) { dismiss(); onPick(room) }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }
}

/// Picks a furniture type from the app's list.
struct FurnitureTypePicker: View {
    let current: Int
    let onPick: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(Furniture.names.sorted { $0.value < $1.value }, id: \.key) { entry in
                Button {
                    dismiss()
                    if entry.key != current { onPick(entry.key) }
                } label: {
                    HStack {
                        Text(entry.value)
                        Spacer()
                        if entry.key == current { Image(systemName: "checkmark") }
                    }
                }
                .tint(.primary)
            }
            .navigationTitle("Furniture type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }
}

/// Each carpet the robot knows, with how it should treat that one carpet.
struct CarpetsSheet: View {
    @Environment(RobotStore.self) private var store
    let map: RobotMap
    @Binding var highlight: Int?
    @Environment(\.dismiss) private var dismiss

    /// CarpetCleanOption, in the Narwal app's order and words; 0 follows
    /// the setting for all carpets.
    static let options: [(Int, String)] = [
        (0, "Default"), (2, "Clean"), (4, "Avoid"), (1, "Cross"), (3, "Vacuum & Mop"),
    ]

    var body: some View {
        let current = store.map ?? map
        NavigationStack {
            List {
                if current.carpets.isEmpty {
                    Text("The robot hasn't mapped any carpets yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(current.carpets) { carpet in
                    Section {
                        Button("Show on map") { highlight = carpet.id }
                            .foregroundStyle(highlight == carpet.id ? Theme.teal : Theme.text)
                        Picker("When cleaning", selection: Binding(
                            get: { carpet.cleanOption },
                            set: { option in
                                highlight = carpet.id
                                Task { await store.setCarpetOption(carpet.id, to: option) }
                            }
                        )) {
                            ForEach(Self.options, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .disabled(store.busyAction != nil)
                    } header: {
                        Text(title(carpet, in: current))
                    }
                }
            }
            .navigationTitle("Carpet settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func title(_ carpet: CarpetArea, in map: RobotMap) -> String {
        let room = carpet.roomId.flatMap { id in map.rooms.first { $0.id == id }?.displayName }
        let squareMeters = carpet.area * pow(Double(map.resolution) / 1000, 2)
        let size = squareMeters > 0 ? " · " + AreaFormat.string(squareMeters: squareMeters) : ""
        return (room.map { "Carpet in \($0)" } ?? "Carpet \(carpet.id)") + size
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
    @State private var options = CleanOptions()
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
                if zones.isEmpty {
                    Section {
                        Toggle("Freo Mind", isOn: $options.freoMind)
                        if store.status?.station.hasWoodFloorSolution == true {
                            Toggle("Maintain wood floors afterwards", isOn: $options.maintainFloorsAfter)
                        }
                    } footer: {
                        Text(options.freoMind
                             ? "The robot chooses suction, water and coverage for each area, using the Freo Mind Mode settings in More."
                             : "Freo Mind lets the robot choose suction, water and coverage itself.")
                    }
                }
                SettingsFields(settings: $settings, freoMind: options.freoMind && zones.isEmpty)
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
                                await store.cleanAll(settings: settings, options: options)
                            } else {
                                await store.cleanRooms(rooms, settings: settings, perRoom: perRoom, options: options)
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
    /// Freo Mind picks suction, water and coverage itself.
    var freoMind = false

    var body: some View {
        Section("Mode") {
            Picker("Mode", selection: $settings.workMode) {
                ForEach(WorkMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if !freoMind {
                Stepper("Passes: \(settings.passes)", value: $settings.passes, in: 1...3)
                Picker("Coverage precision", selection: Binding(
                    get: { settings.route ?? .standard },
                    set: { settings.route = $0 }
                )) {
                    ForEach(CleaningRoute.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
        }
        if freoMind {
            EmptyView()
        } else if settings.workMode != .mop {
            Section("Vacuum") {
                Picker("Suction", selection: $settings.fan) {
                    ForEach(FanLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
        }
        if !freoMind, settings.workMode != .vacuum {
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

/// Narwal's Floor maintenance: wood rooms, optionally cleaned first.
struct FloorMaintenanceSheet: View {
    @Environment(RobotStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let map: RobotMap
    var preselected: [Int] = []

    @State private var rooms: Set<Int> = []
    @State private var cleanFirst = true

    var body: some View {
        let wood = map.rooms.filter { $0.floor == .wood }
        let solution = store.status?.station.cartridges.first { $0.name.hasPrefix("Wood") }
        NavigationStack {
            Form {
                Section {
                    if wood.isEmpty {
                        Text("No room is set to Wood Floor. In the Clean tab's Edit mode, tap a room and choose Floor material.")
                            .foregroundStyle(Theme.secondary)
                    }
                    ForEach(wood) { room in
                        Button {
                            if rooms.contains(room.id) { rooms.remove(room.id) } else { rooms.insert(room.id) }
                        } label: {
                            HStack {
                                Text(room.displayName).foregroundStyle(Theme.text)
                                Spacer()
                                if rooms.contains(room.id) { Image(systemName: "checkmark").foregroundStyle(Theme.teal) }
                            }
                        }
                    }
                } header: {
                    Text("Wood floor rooms")
                } footer: {
                    Text("Only rooms with wood floors can be maintained. Setting the wood's pattern direction gives better results.")
                }
                Section {
                    Toggle("Cleaning before maintenance", isOn: $cleanFirst)
                } footer: {
                    Text("The robot runs Vacuum and mop with Freo Mind on these rooms first. Put things away from the floor so more of it is maintained.")
                }
                Section {
                    LabeledContent("Wood Floor Maintenance Solution", value: solution?.label ?? "Not reported")
                }
            }
            .navigationTitle("Floor maintenance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        let ordered = store.cleaningOrder.filter(rooms.contains)
                        Task {
                            await store.startFloorMaintenance(rooms: ordered.isEmpty ? Array(rooms) : ordered,
                                                              cleanFirst: cleanFirst)
                            if store.lastError == nil { dismiss() }
                        }
                    }
                    .disabled(rooms.isEmpty || store.busyAction != nil)
                }
            }
            .onAppear {
                let woodIds = Set(wood.map(\.id))
                let picked = preselected.filter(woodIds.contains)
                rooms = Set(picked.isEmpty ? Array(woodIds) : picked)
            }
        }
    }
}

/// Narwal's Floor material choices, plus the wood's pattern direction.
struct FloorMaterialPicker: View {
    @Environment(\.dismiss) private var dismiss
    let room: Room
    let pick: (FloorMaterial, Int?) -> Void

    @State private var floor: FloorMaterial = .defaultMaterial
    @State private var angle = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Floor material", selection: $floor) {
                        ForEach(FloorMaterial.narwalOrder, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } footer: {
                    Text("Freo Mind adjusts how it mops each material. Only Wood Floor rooms get floor maintenance.")
                }
                if floor == .wood {
                    Section {
                        Picker("Pattern direction", selection: $angle) {
                            Text("Across").tag(0)
                            Text("Diagonal ↗").tag(45)
                            Text("Along").tag(90)
                            Text("Diagonal ↖").tag(135)
                        }
                    } footer: {
                        Text("Which way the boards run on the map. The robot maintains along the grain.")
                    }
                }
            }
            .navigationTitle(room.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        pick(floor, floor == .wood ? angle : nil)
                        dismiss()
                    }
                }
            }
            .onAppear {
                floor = room.floor
                angle = room.floorAngle
            }
        }
    }
}

/// Room type, which Freo Mind uses (kitchens and bathrooms get more care).
struct RoomTypePicker: View {
    @Environment(\.dismiss) private var dismiss
    let current: Int
    let pick: (Int) -> Void

    var body: some View {
        NavigationStack {
            List(RoomType.names.sorted { $0.key < $1.key }.filter { $0.key > 0 }, id: \.key) { entry in
                Button {
                    pick(entry.key)
                    dismiss()
                } label: {
                    HStack {
                        Text(entry.value).foregroundStyle(Theme.text)
                        Spacer()
                        if entry.key == current { Image(systemName: "checkmark").foregroundStyle(Theme.teal) }
                    }
                }
            }
            .navigationTitle("Room type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

