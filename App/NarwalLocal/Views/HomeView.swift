import NarwalKit
import SwiftUI

struct HomeView: View {
    @Environment(RobotStore.self) private var store
    @Environment(PresetStore.self) private var presets

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatusHeader()
                }

                if store.autoConnectPaused {
                    Section {
                        Text("The app closed unexpectedly last time, so it didn't connect automatically. Check the address in Settings, then connect.")
                            .font(.callout)
                        Button("Connect now") { store.resumeAutoConnect() }
                        Button("Pick the robot again", role: .destructive) { store.forgetRobot() }
                    }
                }

                if !store.alerts.active.isEmpty {
                    Section("Needs attention") {
                        ForEach(store.alerts.active) { alert in
                            Label {
                                VStack(alignment: .leading) {
                                    Text(alert.title)
                                    if !alert.detail.isEmpty {
                                        Text(alert.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                        }
                    }
                }

                if store.isCleaning, let progress = store.progress {
                    Section("This clean") {
                        if let pct = progress.progressPercent {
                            ProgressView(value: Double(pct), total: 100) { Text("\(pct)%") }
                        }
                        if let room = store.currentRoomName {
                            LabeledContent("Current room", value: room)
                        }
                        if let area = progress.areaSquareMeters {
                            LabeledContent("Area", value: String(format: "%.1f m²", area))
                        }
                        if let elapsed = progress.elapsedSeconds {
                            LabeledContent("Elapsed", value: Duration.seconds(elapsed).formatted(.units(allowed: [.hours, .minutes])))
                        }
                        if let remaining = progress.remainingSeconds, remaining > 0 {
                            LabeledContent("Remaining", value: Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes])))
                        }
                    }
                    LiveTuning()
                }

                Section("Controls") {
                    ControlButtons()
                }

                Section("Routines") {
                    if presets.presets.isEmpty {
                        Text("Save a routine from the Map tab to start it with one tap.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(presets.presets) { preset in
                        Button {
                            Task { await start(preset) }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(preset.name)
                                Text(summary(preset)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(store.busyAction != nil)
                    }
                    .onDelete { presets.delete(at: $0) }
                }
            }
            .navigationTitle(store.deviceInfo == nil ? "Narwal" : "Freo Z10 Ultra")
            .refreshable { await store.refreshAll() }
        }
    }

    private func start(_ preset: CleanPreset) async {
        if let zones = preset.zones, !zones.isEmpty {
            await store.cleanZones(zones, settings: preset.settings)
        } else if preset.rooms.isEmpty {
            await store.cleanAll(settings: preset.settings)
        } else {
            await store.cleanRooms(preset.rooms, settings: preset.settings, perRoom: preset.perRoom)
        }
    }

    private func summary(_ preset: CleanPreset) -> String {
        let rooms: String
        if let zones = preset.zones, !zones.isEmpty {
            rooms = "\(zones.count) zone\(zones.count == 1 ? "" : "s")"
        } else if preset.rooms.isEmpty {
            rooms = "Whole house"
        } else {
            let names = preset.rooms.map { id in store.map?.rooms.first { $0.id == id }?.displayName ?? "Room \(id)" }
            rooms = names.joined(separator: " → ")
        }
        return "\(rooms) · \(preset.settings.workMode.label) · \(preset.settings.fan.label)"
    }
}

private struct StatusHeader: View {
    @Environment(RobotStore.self) private var store

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(color.opacity(0.15)).frame(width: 56, height: 56)
                Image(systemName: icon).font(.title2).foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(store.statusText).font(.title3.weight(.semibold))
                HStack(spacing: 12) {
                    if let battery = store.status?.battery {
                        Label("\(battery)%", systemImage: batteryIcon(battery))
                    }
                    Label(connectionText, systemImage: "wifi")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if store.connectionState == .connecting || store.connectionState == .disconnected,
                   let last = store.log.last {
                    Text(last).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer()
            if store.busyAction != nil { ProgressView() }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        if store.status?.errors.isEmpty == false { return "exclamationmark.triangle.fill" }
        if store.isCleaning { return store.isPaused ? "pause.fill" : "sparkles" }
        if store.isDocked { return "bolt.fill" }
        return "circle.dashed"
    }

    private var color: Color {
        if store.status?.errors.isEmpty == false { return .orange }
        if store.connectionState == .disconnected { return .gray }
        return store.isCleaning ? .blue : .green
    }

    private var connectionText: String {
        switch store.connectionState {
        case .awake: return "Live"
        case .connected: return "Connected"
        case .asleep: return "Robot asleep"
        case .connecting: return "Connecting"
        case .disconnected: return "Offline"
        }
    }

    private func batteryIcon(_ level: Int) -> String {
        switch level {
        case 88...: return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default: return "battery.0"
        }
    }
}

private struct ControlButtons: View {
    @Environment(RobotStore.self) private var store
    @AppStorage("defaultWorkMode") private var workMode = WorkMode.vacuumAndMop.rawValue

    var body: some View {
        let busy = store.busyAction != nil
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                if store.isCleaning {
                    if store.isPaused {
                        action("Resume", "play.fill") { try await $0.resume() }
                    } else {
                        action("Pause", "pause.fill") { try await $0.pause() }
                    }
                    action("Stop", "stop.fill") { try await $0.stopTask() }
                } else {
                    Button {
                        Task { await store.cleanAll(settings: CleanSettings(workMode: WorkMode(rawValue: workMode) ?? .vacuumAndMop)) }
                    } label: {
                        tile("Clean all", "sparkles")
                    }
                    action("Quick clean", "hare.fill") { try await $0.quickClean() }
                }
            }
            GridRow {
                action("Dock", "house.fill") { try await $0.returnToDock() }
                action("Locate", "speaker.wave.2.fill") { try await $0.locate() }
            }
        }
        .buttonStyle(.borderless)
        .disabled(busy || store.connectionState == .disconnected)
        .padding(.vertical, 4)
    }

    private func action(_ title: String, _ icon: String,
                        _ perform: @escaping (NarwalConnection) async throws -> Void) -> some View {
        Button {
            Task { await store.run(title, perform) }
        } label: {
            tile(title, icon)
        }
    }

    private func tile(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title2)
            Text(title).font(.footnote.weight(.medium))
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Live suction/water changes while a clean is running.
private struct LiveTuning: View {
    @Environment(RobotStore.self) private var store

    var body: some View {
        Section("Adjust now") {
            Picker("Suction", selection: Binding(
                get: { store.status?.fanLevel ?? .standard },
                set: { level in Task { await store.run("Suction") { try await $0.setFanLevel(level) } } }
            )) {
                // The live command tops out at Super Powerful.
                ForEach(FanLevel.allCases.filter { $0 != .ultraPowerful }, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Water", selection: Binding(
                get: { store.status?.mopHumidity ?? .normal },
                set: { level in Task { await store.run("Water") { try await $0.setMopHumidity(level) } } }
            )) {
                ForEach(MopHumidity.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        }
    }
}
