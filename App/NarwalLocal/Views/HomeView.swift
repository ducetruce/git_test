import NarwalKit
import SwiftUI

/// Today: the robot in 3D, three score rings, and one plain-English card
/// about what matters now.
struct TodayView: View {
    @Environment(RobotStore.self) private var store
    @Environment(PresetStore.self) private var presets
    @AppStorage("defaultWorkMode") private var workMode = WorkMode.vacuumAndMop.rawValue
    @State private var now = Date()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    RobotModelView(shot: store.isCleaning ? .robot : .docked, mood: mood)
                        .frame(height: store.isCleaning ? 220 : 270)
                        .accessibilityLabel(store.isCleaning ? "The robot, cleaning" : "The robot in its station")

                    VStack(spacing: 14) {
                        if store.isCleaning, let progress = store.progress {
                            CleaningCard(progress: progress)
                        } else {
                            rings.padding(.bottom, 8)
                        }

                        ForEach(store.alerts.active) { alert in
                            FaultCard(alert: alert)
                        }

                        if let task = store.continuable, !store.isCleaning { ResumeCard(task: task) }
                        ForEach(store.status?.station.cartridges.filter(\.needsCare) ?? []) { cartridge in
                            Card {
                                Theme.label("Dock", color: Theme.amber)
                                Text("\(cartridge.name): \(cartridge.label.lowercased())")
                                    .font(.system(size: 17)).foregroundStyle(Theme.text)
                            }
                        }

                        if showSilentHint { SilentRobotHint() }
                        if store.autoConnectPaused { PausedCard() }

                        if !store.isCleaning, store.alerts.active.isEmpty {
                            insightCard
                        }

                        quickActions.padding(.vertical, 8)

                        if !presets.presets.isEmpty { routines }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .refreshable { await store.refreshAll() }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                if store.history == nil { await store.reloadHistory() }
                await store.checkForInterruptedClean()
                while !Task.isCancelled {
                    now = Date()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Theme.label(statusLine, color: statusColor)
                Text(store.deviceInfo == nil ? "Narwal" : "Freo Z10 Ultra")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Theme.text)
            }
            Spacer()
            if store.busyAction != nil {
                ProgressView().tint(Theme.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    private var statusLine: String {
        var parts = [store.statusText]
        if let battery = store.status?.battery { parts.append("\(battery)%") }
        if store.connectionState == .disconnected { parts = ["Offline"] }
        return parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        if !(store.status?.errors.isEmpty ?? true) { return Theme.amber }
        return store.isCleaning ? Theme.teal : Theme.tertiary
    }

    private var mood: RobotModelView.Mood {
        if !(store.status?.errors.isEmpty ?? true) { return .attention }
        if store.isCleaning { return .cleaning }
        if store.status?.isCharging == true { return .charging }
        return .idle
    }

    private var rings: some View {
        HStack {
            let battery = store.status?.battery
            ScoreRing(value: battery.map(String.init) ?? "–", label: "Battery",
                      fraction: battery.map { Double($0) / 100 }, color: Theme.blue)
            Spacer()
            let week = areaThisWeek
            ScoreRing(value: week.value, label: week.label, fraction: week.fraction, color: Theme.teal)
            Spacer()
            let bag = store.status?.station.dustBagHealth.flatMap { $0.isFinite ? Double($0) : nil }
            ScoreRing(value: bag.map { "\(Int($0.rounded()))" } ?? "–", label: "Bag",
                      fraction: bag.map { $0 / 100 }, color: Theme.amber)
        }
        .padding(.horizontal, 8)
    }

    /// Area cleaned in the last 7 days. A full ring is the whole mapped
    /// floor once. Counts cleans this app saw finish.
    private var areaThisWeek: (value: String, label: String, fraction: Double?) {
        let squareMeters = store.squareMetersThisWeek
        let text = AreaFormat.string(squareMeters: squareMeters)
        let number = text.split(separator: " ").first.map(String.init) ?? text
        let unit = text.hasSuffix("sq ft") ? "Sq ft / wk" : "m² / wk"
        let floor = store.map?.floorSquareMeters ?? 0
        return (squareMeters > 0 ? number : "0", unit, floor > 0 ? squareMeters / floor : nil)
    }

    /// The room left longest without a clean, if the history says.
    private var stalestRoom: (room: Room, days: Int?)? {
        guard let map = store.map, let history = store.history, !map.rooms.isEmpty else { return nil }
        let last = history.lastCleaned()
        guard !last.isEmpty else { return nil }
        let room = map.rooms.min { (last[$0.id] ?? .distantPast) < (last[$1.id] ?? .distantPast) }!
        let days = last[room.id].map { Int(now.timeIntervalSince($0) / 86_400) }
        return (room, days)
    }

    @ViewBuilder
    private var insightCard: some View {
        Card {
            Theme.label("Today", color: Theme.teal)
            if let stale = stalestRoom, (stale.days ?? 99) >= 2 {
                Text(stale.days.map { "The \(stale.room.displayName) hasn't been cleaned in \($0) days." }
                     ?? "The \(stale.room.displayName) hasn't been cleaned recently.")
                    .font(.system(size: 19)).foregroundStyle(Theme.text)
                HStack(spacing: 10) {
                    Button("Clean it now") {
                        Task { await store.cleanRooms([stale.room.id], settings: CleanSettings(workMode: currentMode), perRoom: [:]) }
                    }
                    .buttonStyle(PillButtonStyle())
                    Button("Clean all") { Task { await store.cleanAll(settings: CleanSettings(workMode: currentMode)) } }
                        .buttonStyle(PillButtonStyle(filled: false))
                }
                .padding(.top, 6)
                .disabled(store.busyAction != nil || store.connectionState == .disconnected)
            } else {
                Text(store.isDocked ? "All rooms are up to date." : "Ready when you are.")
                    .font(.system(size: 19)).foregroundStyle(Theme.text)
                Text("Start a clean below, or pick rooms in Clean.")
                    .font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
        }
    }

    private var currentMode: WorkMode { WorkMode(rawValue: workMode) ?? .vacuumAndMop }

    private var quickActions: some View {
        HStack(spacing: 4) {
            if store.isCleaning {
                if store.isPaused {
                    RoundAction(title: "Resume", icon: "play.fill") { run("Resume") { try await $0.resume() } }
                } else {
                    RoundAction(title: "Pause", icon: "pause.fill") { run("Pause") { try await $0.pause() } }
                }
                RoundAction(title: "Stop", icon: "stop.fill") { run("Stop") { try await $0.stopTask() } }
            } else {
                RoundAction(title: "Clean all", icon: "play.fill") {
                    Task { await store.cleanAll(settings: CleanSettings(workMode: currentMode)) }
                }
                RoundAction(title: "Quick", icon: "hare") { run("Quick clean") { try await $0.quickClean() } }
            }
            RoundAction(title: "Dock", icon: "house") { run("Dock") { try await $0.returnToDock() } }
            RoundAction(title: "Locate", icon: "speaker.wave.2") { run("Locate") { try await $0.locate() } }
        }
        .disabled(store.busyAction != nil || store.connectionState == .disconnected)
    }

    private func run(_ title: String, _ action: @escaping (NarwalConnection) async throws -> Void) {
        Task { await store.run(title, action) }
    }

    private var routines: some View {
        Card {
            Theme.label("Routines")
            ForEach(presets.presets) { preset in
                Button {
                    Task { await start(preset) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preset.name).font(.system(size: 16)).foregroundStyle(Theme.text)
                            Text(summary(preset)).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        Image(systemName: "play.circle").font(.title3).foregroundStyle(Theme.secondary)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .disabled(store.busyAction != nil)
            }
        }
    }

    /// The robot accepted the connection but has said nothing for 20 s.
    private var showSilentHint: Bool {
        guard store.connectionState == .connecting, store.deviceInfo == nil,
              let since = store.waitingSince else { return false }
        return now.timeIntervalSince(since) > 20
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
        return "\(rooms) · \(preset.settings.workMode.label)"
    }
}

/// While cleaning: progress ring, time left, and live suction and water.
private struct CleaningCard: View {
    @Environment(RobotStore.self) private var store
    let progress: WorkingProgress

    var body: some View {
        Card {
            HStack(spacing: 20) {
                ScoreRing(value: progress.progressPercent.map { "\($0)%" } ?? "–", label: "Done",
                          fraction: progress.progressPercent.map { Double($0) / 100 }, size: 100)
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.currentRoomName ?? "Cleaning")
                        .font(.system(size: 19)).foregroundStyle(Theme.text)
                    if let remaining = progress.remainingSeconds, remaining > 0 {
                        Text("About \(Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes]))) left")
                            .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    }
                    if let area = progress.areaSquareMeters {
                        Text("\(AreaFormat.string(squareMeters: Double(area))) so far")
                            .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    }
                }
            }
            Divider().overlay(Theme.hairline).padding(.vertical, 6)
            LiveTuning()
        }
    }
}

/// A robot fault, named plainly, with what to do and buttons to do it.
private struct FaultCard: View {
    @Environment(RobotStore.self) private var store
    let alert: AlertMonitor.Alert

    var body: some View {
        Card {
            Theme.label("Needs you", color: Theme.amber)
            Text(alert.title).font(.system(size: 19)).foregroundStyle(Theme.text)
            if !alert.detail.isEmpty {
                Text(alert.detail).font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
            if alert.code != nil {
                HStack(spacing: 10) {
                    // The Narwal app's "issue resolved": the robot clears the
                    // fault and tries again.
                    Button("Mark resolved") { Task { await store.confirmWarning() } }
                        .buttonStyle(PillButtonStyle())
                    if alert.isDockSearch {
                        Button("Go to dock") { Task { await store.run("Go to dock") { try await $0.returnToDock() } } }
                            .buttonStyle(PillButtonStyle(filled: false))
                    } else if store.isPaused {
                        Button("Resume") { Task { await store.run("Resume") { try await $0.resume() } } }
                            .buttonStyle(PillButtonStyle(filled: false))
                    }
                }
                .padding(.top, 6)
                .disabled(store.busyAction != nil)
            }
            if let code = alert.code {
                Text("Error \(code)").font(.caption2.monospaced()).foregroundStyle(Theme.tertiary)
            }
        }
    }
}

/// Live suction/water changes while a clean is running.
private struct LiveTuning: View {
    @Environment(RobotStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            row("Suction") {
                Picker("Suction", selection: Binding(
                    get: { store.status?.fanLevel ?? .standard },
                    set: { level in Task { await store.run("Suction") { try await $0.setFanLevel(level) } } }
                )) {
                    // The live command tops out at Super Powerful.
                    ForEach(FanLevel.allCases.filter { $0 != .ultraPowerful }, id: \.self) { Text($0.label).tag($0) }
                }
            }
            row("Water") {
                Picker("Water", selection: Binding(
                    get: { store.status?.mopHumidity ?? .normal },
                    set: { level in Task { await store.run("Water") { try await $0.setMopHumidity(level) } } }
                )) {
                    ForEach(MopHumidity.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
        }
    }

    private func row<P: View>(_ title: String, @ViewBuilder _ picker: () -> P) -> some View {
        HStack {
            Text(title).font(.system(size: 15)).foregroundStyle(Theme.text)
            Spacer()
            picker().pickerStyle(.menu).tint(Theme.secondary)
        }
    }
}

/// Shown when the robot accepts the connection but never answers: usually
/// it's asleep, or it ignores us until it's been told its device ID.
private struct SilentRobotHint: View {
    var body: some View {
        Card {
            Theme.label("The robot isn't answering yet", color: Theme.amber)
            Text("""
            It may be asleep, or it may need its device ID first. Try this once:
            1. Open the Narwal app and wait until it shows your robot's status.
            2. Switch straight back here (don't close the Narwal app).
            This app then reads the device ID from the robot and remembers it.
            """)
            .font(.system(size: 14)).foregroundStyle(Theme.secondary)
        }
    }
}

private struct PausedCard: View {
    @Environment(RobotStore.self) private var store

    var body: some View {
        Card {
            Theme.label("Not connected", color: Theme.amber)
            Text("The app closed unexpectedly last time, so it didn't connect automatically.")
                .font(.system(size: 14)).foregroundStyle(Theme.secondary)
            HStack(spacing: 10) {
                Button("Connect now") { store.resumeAutoConnect() }.buttonStyle(PillButtonStyle())
                Button("Pick the robot again") { store.forgetRobot() }.buttonStyle(PillButtonStyle(filled: false))
            }
        }
    }
}

/// An interrupted clean the robot can pick up where it stopped.
private struct ResumeCard: View {
    @Environment(RobotStore.self) private var store
    let task: ContinuableTask

    var body: some View {
        Card {
            Theme.label("Unfinished clean", color: Theme.amber)
            Text(task.stoppedAt.map { "A clean stopped \($0.formatted(.relative(presentation: .named)))." }
                 ?? "A clean stopped before it finished.")
                .font(.system(size: 19)).foregroundStyle(Theme.text)
            HStack(spacing: 10) {
                Button("Continue") { Task { await store.continueInterruptedClean(true) } }
                    .buttonStyle(PillButtonStyle())
                Button("Dismiss") { Task { await store.continueInterruptedClean(false) } }
                    .buttonStyle(PillButtonStyle(filled: false))
            }
            .padding(.top, 6)
            .disabled(store.busyAction != nil)
        }
    }
}

