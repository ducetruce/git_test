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
    @State private var showingPixelTypes = false
    @State private var highlightPixelType: Int?
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
                        Map3DView(map: map, selected: selected, pose: store.pose)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .bottom) {
                                RoomChips(map: map, selected: $selected)
                            }
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
                        highlightPixelType: highlightPixelType,
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
                    .clipped()
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
                        // The counts say whether the robot sent any, which
                        // tells an empty layer apart from a drawing bug.
                        Section(store.map.map {
                            "Robot map: \($0.carpetCellCount) carpet cells, \($0.carpets.count) carpet shapes, \($0.furniture.count) furniture"
                        } ?? "Layers") {
                            Toggle("Carpets", isOn: $showCarpets)
                            Toggle("Furniture", isOn: $showFurniture)
                        }
                        Button("Carpets…") { showingCarpets = true }
                        Button("Map key…") { showingPixelTypes = true }
                    } label: {
                        Image(systemName: "square.3.layers.3d")
                    }
                    .accessibilityLabel("Map layers")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(show3D ? "2D" : "3D") { show3D.toggle() }
                        .font(.system(size: 14, weight: .semibold))
                        .accessibilityLabel(show3D ? "Show flat map" : "Show 3D map")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await store.reloadMap() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(store.busyAction != nil)
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
            .sheet(isPresented: $showingCarpets, onDismiss: { highlightCarpet = nil }) {
                if let map = store.map {
                    CarpetsSheet(map: map, highlight: $highlightCarpet)
                        .presentationDetents([.medium, .large])
                        .presentationBackgroundInteraction(.enabled)
                }
            }
            .sheet(isPresented: $showingPixelTypes) {
                if let map = store.map {
                    PixelTypesSheet(map: map, highlight: $highlightPixelType)
                        .presentationDetents([.medium])
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
            Text(store.allowsWrites ? tool.hint : "Turn on Settings > Change robot settings to edit the map.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(Theme.background)
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
        .background(Theme.background)
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
                            .font(.system(size: 14, weight: order == nil ? .regular : .semibold))
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

    static let options: [(Int, String)] = [
        (0, "Same as all carpets"), (1, "Cross over"), (2, "Boost suction"), (3, "Ignore"), (4, "Avoid"),
    ]

    var body: some View {
        let current = store.map ?? map
        NavigationStack {
            List {
                if current.carpets.isEmpty {
                    Text("The robot's map has no individual carpets. Carpets it only marks on the floor (the dotted areas) can't be set one by one.")
                        .foregroundStyle(.secondary)
                }
                ForEach(current.carpets) { carpet in
                    Section {
                        if store.allowsWrites {
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
                        } else {
                            LabeledContent("When cleaning", value: Self.options.first { $0.0 == carpet.cleanOption }?.1 ?? "Not set")
                        }
                        Button(highlight == carpet.id ? "Shown on map" : "Show on map") { highlight = carpet.id }
                    } header: {
                        Text(title(carpet, in: current))
                    }
                }
            }
            .navigationTitle("Carpets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .safeAreaInset(edge: .bottom) {
                if !store.allowsWrites {
                    Text("Turn on Settings > Change robot settings to edit carpets.")
                        .font(.footnote).foregroundStyle(.secondary).padding()
                }
            }
        }
    }

    private func title(_ carpet: CarpetArea, in map: RobotMap) -> String {
        let room = carpet.roomId.flatMap { id in map.rooms.first { $0.id == id }?.displayName }
        let squareMeters = carpet.area * pow(Double(map.resolution) / 1000, 2)
        let size = squareMeters > 0 ? " · " + AreaFormat.string(squareMeters: squareMeters) : ""
        return (room.map { "Carpet in \($0)" } ?? "Carpet \(carpet.id)") + size
    }
}

/// Lists the map's pixel types; tapping one paints it magenta on the map,
/// to match types against what the Narwal app shows (carpets, etc.).
struct PixelTypesSheet: View {
    let map: RobotMap
    @Binding var highlight: Int?
    @Environment(\.dismiss) private var dismiss

    /// What each kind of map square means, as far as it's been worked out.
    static func meaning(_ type: Int) -> String {
        switch type {
        case 0x20: return "Floor outside any room"
        case 0x28: return "Obstacle"
        default:
            var parts: [String] = []
            parts.append(type & Int(RobotMap.carpetFlag) != 0 ? "Carpet" : "Floor")
            if type & 0x10 != 0 { parts.append("lighter area") }
            if type & ~(0x10 | Int(RobotMap.carpetFlag)) != 0 { parts.append("unknown marking") }
            return parts.joined(separator: ", ")
        }
    }

    var body: some View {
        NavigationStack {
            List(map.pixelTypeCounts(), id: \.type) { entry in
                Button {
                    highlight = highlight == entry.type ? nil : entry.type
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(Self.meaning(entry.type))
                            Text(String(format: "Type 0x%02lX", entry.type))
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(entry.count) cells").foregroundStyle(.secondary)
                        if highlight == entry.type {
                            Image(systemName: "checkmark").foregroundStyle(Color.pink)
                        }
                    }
                }
                .tint(.primary)
            }
            .navigationTitle("Map key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { highlight = nil; dismiss() }
            }
        }
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
