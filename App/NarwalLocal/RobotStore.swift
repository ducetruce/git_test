import Foundation
import NarwalKit
import Observation
import os

/// App-wide robot state. Owns the connection and turns its events into
/// UI state; every command goes through `run` so failures are shown, never
/// swallowed.
@MainActor
@Observable
final class RobotStore {
    // Connection
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var deviceInfo: DeviceInfo?
    // Normalized on load too: an earlier build could save "a.b.c.d%en0".
    private(set) var host = NarwalConnection.normalizedHost(UserDefaults.standard.string(forKey: "robotHost") ?? "")

    // Live state
    private(set) var status: BaseStatus?
    private(set) var statusUpdatedAt: Date?
    private(set) var progress: WorkingProgress?
    private(set) var pose: LivePose?
    private(set) var poseUpdatedAt: Date?
    /// Path driven during the current task, in display coordinates.
    private(set) var trail: [MapPoint] = []

    // Fetched state
    private(set) var map: RobotMap?
    private(set) var consumables: ConsumableAlerts?
    /// Recent cleaning events: fetched on demand and updated by broadcasts.
    private(set) var history: CleaningHistory?
    /// config/get, read-only until writes are confirmed on the robot.
    private(set) var robotSettings: RobotSettings?
    /// Robot-stored schedules; nil until loaded (or if the robot never answers).
    private(set) var schedules: [CleanSchedule]?
    private(set) var schedulesError: String?

    // UI
    private(set) var busyAction: String?
    var lastError: String?
    private(set) var log: [String] = []

    let alerts = AlertMonitor()

    private var connection: NarwalConnection?
    /// Reads the robot's Bonjour TXT record, which may carry its device id.
    private var bonjourProbe: RobotDiscovery?
    /// When the current connection attempt started waiting for its first data.
    private(set) var waitingSince: Date?
    private var eventTask: Task<Void, Never>?

    /// The robot only answers its own model's key, and a Z10 Ultra hangs up
    /// on any other, so this is chosen, never guessed.
    private(set) var model = NarwalModel(rawValue: UserDefaults.standard.string(forKey: "robotModel") ?? "")
        ?? .freoZ10Ultra
    /// Optional: normally learned from the robot.
    /// A saved id that isn't a plausible id (an older build could save a
    /// binary blob) is dropped.
    private(set) var deviceIdOverride = UserDefaults.standard.string(forKey: "robotDeviceId")
        .flatMap { DeviceInfo.isPlausibleId($0) ? $0 : nil } ?? ""

    func setModel(_ newModel: NarwalModel) {
        guard newModel != model else { return }
        model = newModel
        UserDefaults.standard.set(newModel.rawValue, forKey: "robotModel")
        connect()
    }

    /// Saves a device id learned from the robot without reconnecting.
    private func rememberDeviceId(_ id: String, source: String) {
        guard DeviceInfo.isPlausibleId(id), id != deviceIdOverride else { return }
        deviceIdOverride = id
        UserDefaults.standard.set(id, forKey: "robotDeviceId")
        appendLog("Saved device ID from \(source)")
    }

    func setDeviceIdOverride(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != deviceIdOverride else { return }
        deviceIdOverride = trimmed
        UserDefaults.standard.set(trimmed, forKey: "robotDeviceId")
        connect()
    }

    func setHost(_ newHost: String) {
        host = NarwalConnection.normalizedHost(newHost)
        UserDefaults.standard.set(host, forKey: "robotHost")
    }

    var isConfigured: Bool { !host.isEmpty }

    /// Set after a crash during the previous launch: wait for the user.
    private(set) var autoConnectPaused = false

    func pauseAutoConnect() {
        autoConnectPaused = true
        appendLog("The app closed unexpectedly last time; not connecting automatically.")
    }

    func resumeAutoConnect() {
        connect()
    }

    var workingStatus: WorkingStatus { status?.workingStatus ?? .unknown }
    var isCleaning: Bool { workingStatus.isActiveCleaning }
    var isPaused: Bool { status?.isPaused ?? false }
    var isDocked: Bool { status?.isDocked ?? workingStatus.isOnDock }

    var statusText: String {
        switch connectionState {
        case .disconnected: return "Offline"
        case .connecting: return "Connecting…"
        default: break
        }
        guard let status else { return "Waking robot…" }
        if let error = status.errors.first { return RobotErrorText.message(for: error.code) }
        if status.isRelocalizing { return "Finding its position" }
        if let activity = status.activity { return activity }
        if status.isReturning { return "Returning to dock" }
        if status.isPaused { return "Paused" }
        switch status.workingStatus {
        case .cleaning, .cleaningV2, .cleaningAlt, .customCleaning: return "Cleaning"
        case .remapping: return "Mapping"
        case .taskCompleted: return "Finished, heading home"
        case .charged: return "Docked"
        case .docked, .dockedV2:
            // Charging only on the robot's word, else by battery as before.
            if let charging = status.isCharging { return charging ? "Charging" : "Docked" }
            return status.battery == 100 ? "Docked" : "Charging"
        case .standby: return status.isDocked == true ? "Docked" : "Idle"
        case .unknown: return "Status unknown"
        }
    }

    var currentRoomName: String? {
        guard let id = progress?.currentRoomId else { return nil }
        return map?.rooms.first { $0.id == id }?.displayName
    }

    // MARK: Connection

    func connect() {
        guard isConfigured else { return }
        autoConnectPaused = false
        disconnect()
        startBonjourProbe()
        let connection = NarwalConnection(host: host, productKey: model.productKey, deviceId: deviceIdOverride)
        self.connection = connection
        eventTask = Task { [weak self] in
            for await event in connection.events {
                self?.apply(event)
            }
        }
        Task { await connection.start() }
    }

    private func startBonjourProbe() {
        guard bonjourProbe == nil else { return }
        let probe = RobotDiscovery()
        probe.onFound = { [weak self] robot in
            guard let self else { return }
            let txt = robot.txt.isEmpty ? "none"
                : robot.txt.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            self.appendLog("Bonjour: \(robot.name) at \(robot.host), TXT: \(txt)")
            if robot.host == self.host, self.deviceIdOverride.isEmpty, let id = robot.deviceIdCandidate {
                self.rememberDeviceId(id, source: "Bonjour")
                self.connect()
            }
        }
        probe.start()
        bonjourProbe = probe
    }

    func disconnect() {
        eventTask?.cancel()
        eventTask = nil
        if let connection { Task { await connection.stop() } }
        connection = nil
        connectionState = .disconnected
    }

    func forgetRobot() {
        disconnect()
        setHost("")
        deviceInfo = nil
        status = nil
        map = nil
        consumables = nil
        trail = []
    }

    /// Foreground: re-wake immediately instead of waiting for the keepalive.
    func appBecameActive() {
        // Only refreshes: the initial connect happens at launch, behind the
        // crash-loop guard.
        guard !autoConnectPaused, let connection else { return }
        Task {
            await connection.refresh()
            await refreshAll()
        }
    }

    func refreshAll() async {
        guard let connection else { return }
        if let polled = try? await connection.baseStatus() { applyStatus(polled) }
        if map == nil, let fetched = try? await connection.fetchMap() { map = fetched }
        if robotSettings == nil, let fetched = try? await connection.settings() { robotSettings = fetched }
        if let fetched = try? await connection.consumableAlerts() {
            consumables = fetched
            alerts.consumablesChanged(fetched)
        }
    }

    func reloadHistory() async {
        await run("Loading history") { connection in
            let fetched = try await connection.cleaningHistory()
            await MainActor.run { self.history = fetched }
        }
    }

    /// Quiet on failure: settings are a nice-to-have, not worth an error banner.
    func reloadSettings() async {
        guard let connection else { return }
        if let fetched = try? await connection.settings() { robotSettings = fetched }
    }

    /// Off until the owner turns on Settings > Change robot settings:
    /// writes haven't been tried on a real robot yet.
    var allowsWrites: Bool { UserDefaults.standard.bool(forKey: "allowRobotWrites") }

    func changeSetting(_ key: RobotSettingKey, to value: Int) async {
        await write(key.title, expecting: { $0.value(key) == value }) { try await $0.setSetting(key, value) }
    }

    func changeVolume(to percent: Int) async {
        await write("Voice volume", expecting: { $0.voiceVolume == percent }) { try await $0.setVoiceVolume(percent) }
    }

    func changeDoNotDisturb(to dnd: RobotSettings.DoNotDisturb) async {
        await write("Quiet hours", expecting: { $0.doNotDisturb == dnd }) { try await $0.setDoNotDisturb(dnd) }
    }

    func setCarpetOption(_ carpetId: Int, to option: Int) async {
        guard allowsWrites, let current = map else { return }
        await run("Carpet") { connection in
            let updated = try await connection.setCarpetCleanOption(carpetId, to: option, on: current)
            await MainActor.run {
                self.map = updated
                if updated.carpets.first(where: { $0.id == carpetId })?.cleanOption != option {
                    self.lastError = "The robot didn't apply the change to that carpet."
                    self.appendLog("Carpet \(carpetId): not applied after map/operation")
                }
            }
        }
    }

    /// Sends one map edit, fetches the map back and checks the edit shows.
    func applyMapEdit(_ edit: MapEdit, _ title: String) async {
        guard allowsWrites, let before = map else { return }
        await run(title) { connection in
            let after = try await connection.editMap([edit], on: before)
            await MainActor.run {
                self.map = after
                if !edit.isApplied(before: before, after: after) {
                    self.lastError = "The robot didn't apply this change: \(title)."
                    self.appendLog("\(title): not applied after map/operation")
                }
            }
        }
    }

    // MARK: Schedules

    /// Plans this app created for its schedules, deleted with them.
    private var ownPlanIds: Set<Int> {
        get { Set(UserDefaults.standard.array(forKey: "ownPlanIds") as? [Int] ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "ownPlanIds") }
    }

    func reloadSchedules() async {
        guard let connection else { return }
        do {
            schedules = try await connection.cleanSchedules()
            schedulesError = nil
        } catch {
            schedulesError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            appendLog("Schedules: \(schedulesError ?? "")")
        }
    }

    /// Saves the routine on the robot as a clean plan, then schedules it.
    func addSchedule(name: String, rooms: [Int], settings: CleanSettings, perRoom: [Int: CleanSettings],
                     hour: Int, minute: Int, weekdays: Set<Int>) async {
        guard allowsWrites, let map else { return }
        let before = schedules?.count ?? 0
        let existing = schedules?.map(\.cron) ?? []
        await run("New schedule") { connection in
            let planId = try await connection.saveCleanPlan(
                Payloads.setCleanPlan(mapId: map.mapId, name: name, rooms: rooms, settings: settings, perRoom: perRoom))
            await MainActor.run { self.ownPlanIds.insert(planId) }
            let mode = Payloads.cleanMode(Set(rooms.isEmpty ? [settings.workMode] : rooms.map { (perRoom[$0] ?? settings).workMode }))
            let cron = CleanSchedule.cron(hour: hour, minute: minute, weekdays: weekdays, like: existing)
            let after = try await connection.changeSchedules(
                Topic.addCleanSchedule,
                Payloads.addSchedule(cron: cron, enabled: true, planId: planId, cleanMode: mode, name: name))
            await MainActor.run {
                self.schedules = after
                if after.count <= before {
                    self.lastError = "The robot didn't add the schedule."
                    self.appendLog("New schedule: not in the list afterwards")
                }
            }
        }
    }

    func setSchedule(_ schedule: CleanSchedule, enabled: Bool) async {
        guard allowsWrites else { return }
        var changed = schedule
        changed.enabled = enabled
        await run(enabled ? "Turn on schedule" : "Turn off schedule") { connection in
            let after = try await connection.changeSchedules(Topic.updateCleanSchedule, Payloads.updateSchedule(changed))
            await MainActor.run {
                self.schedules = after
                if after.first(where: { $0.id == schedule.id })?.enabled != enabled {
                    self.lastError = "The robot didn't apply the change to that schedule."
                }
            }
        }
    }

    func deleteSchedule(_ schedule: CleanSchedule) async {
        guard allowsWrites else { return }
        await run("Delete schedule") { connection in
            let after = try await connection.changeSchedules(Topic.deleteCleanSchedules, Payloads.deleteSchedules([schedule.id]))
            let ours = await MainActor.run { self.ownPlanIds.contains(schedule.planId) }
            if ours, !after.contains(where: { $0.planId == schedule.planId }) {
                try? await connection.deleteCleanPlan(schedule.planId)
                await MainActor.run { self.ownPlanIds.remove(schedule.planId) }
            }
            await MainActor.run {
                self.schedules = after
                if after.contains(where: { $0.id == schedule.id }) {
                    self.lastError = "The robot didn't delete that schedule."
                }
            }
        }
    }

    /// The robot's photo of a recognised obstacle; nil if it has none locally.
    func obstaclePhoto(_ id: Int) async throws -> Data? {
        guard let connection else { throw NarwalError.notConnected }
        return try await connection.obstaclePhoto(id)
    }

    func confirmWarning() async {
        let faults = Set(status?.errors.map(\.code) ?? [])
        await run("Mark resolved") { try await $0.confirmWarning() }
        try? await Task.sleep(for: .seconds(3))
        await refreshAll()
        // The payload is a guess; say so plainly if the robot ignored it.
        if !faults.isEmpty, !faults.isDisjoint(with: status?.errors.map(\.code) ?? []) {
            lastError = "The robot still reports this fault. Use \"Go to dock\", or the Narwal app's \"issue resolved\" for now, and note it in the test checklist."
            appendLog("Mark resolved: fault still reported afterwards")
        }
    }

    /// Sends a write, then checks the read-back: the robot can accept a
    /// request without applying it.
    private func write(_ title: String, expecting applied: @escaping (RobotSettings) -> Bool,
                       _ send: @escaping (NarwalConnection) async throws -> RobotSettings?) async {
        guard allowsWrites else { return }
        await run(title) { connection in
            let after: RobotSettings?
            do {
                after = try await send(connection)
            } catch NarwalError.notConnected {
                // The socket dropped mid-write; setting a value twice is
                // harmless, so try once more on the new connection.
                after = try await send(connection)
            }
            await MainActor.run {
                if let after { self.robotSettings = after }
                if after.map(applied) != true {
                    self.lastError = "The robot didn't apply the change to \(title)."
                    self.appendLog("\(title): not applied after write")
                }
            }
        }
    }

    func reloadMap() async {
        await run("Loading map") { connection in
            let fetched = try await connection.fetchMap()
            await MainActor.run { self.map = fetched }
        }
    }

    private func apply(_ event: NarwalEvent) {
        switch event {
        case .connection(let state):
            connectionState = state
            if state == .connecting {
                waitingSince = Date()
            } else if state != .disconnected {
                waitingSince = nil
            }
            appendLog("Connection: \(state)")
            if state == .awake || state == .connected {
                Task { await refreshAll() }
            }
        case .identity(_, let id):
            rememberDeviceId(id, source: "the robot's broadcast")
        case .deviceInfo(let info):
            deviceInfo = info
            rememberDeviceId(info.deviceId, source: "the robot")
            appendLog("Robot \(info.productKey) / fw \(info.firmware)")
        case .baseStatus(let status):
            applyStatus(status)
        case .progress(let progress):
            self.progress = progress
        case .history(let history):
            // Broadcasts can carry only the current task; keep a fuller list.
            if !history.events.isEmpty || self.history == nil { self.history = history }
        case .pose(let pose):
            self.pose = pose
            poseUpdatedAt = Date()
            if isCleaning, trail.last != pose.position {
                trail.append(pose.position)
                if trail.count > 5000 { trail.removeFirst(trail.count - 5000) }
            }
        case .broadcast:
            break
        case .log(let text):
            appendLog(text)
        }
    }

    private func applyStatus(_ new: BaseStatus) {
        let wasCleaning = isCleaning
        status = new
        statusUpdatedAt = Date()
        if new.workingStatus.isActiveCleaning, !wasCleaning {
            trail = []
        }
        alerts.statusChanged(new, previousWasCleaning: wasCleaning, roomName: currentRoomName)
    }

    private static let systemLog = Logger(subsystem: "local.narwal", category: "connection")

    private func appendLog(_ line: String) {
        // Mirrored to the system log so Simulator smoke tests (and Console)
        // can follow the connection.
        Self.systemLog.log("\(line, privacy: .public)")
        let stamp = Date().formatted(date: .omitted, time: .standard)
        log.append("\(stamp)  \(line)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    // MARK: Actions

    /// Runs a command with a busy indicator; failures land in `lastError`.
    func run(_ label: String, _ action: @escaping (NarwalConnection) async throws -> Void) async {
        guard let connection else {
            lastError = NarwalError.notConnected.localizedDescription
            return
        }
        busyAction = label
        defer { busyAction = nil }
        do {
            try await action(connection)
            appendLog("\(label): ok")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError = message
            appendLog("\(label): \(message)")
        }
    }

    func cleanRooms(_ rooms: [Int], settings: CleanSettings, perRoom: [Int: CleanSettings] = [:]) async {
        await run("Starting clean") { connection in
            let used = try await connection.cleanRooms(rooms, settings: settings, perRoom: perRoom)
            await MainActor.run { self.map = used }
        }
    }

    func cleanZones(_ zones: [Payloads.Zone], settings: CleanSettings) async {
        await run("Starting zone clean") { connection in
            let used = try await connection.cleanZones(zones, settings: settings)
            await MainActor.run { self.map = used }
        }
    }

    // MARK: Feature lab

    struct ProbeResult: Codable, Identifiable, Equatable {
        var id: String { topic }
        let topic: String
        let outcome: String
        let leaves: [Research.Leaf]
    }

    /// Sends one read-only query and decodes whatever comes back.
    func probe(_ topic: String) async -> ProbeResult {
        guard Research.isSafeQuery(topic) else {
            return ProbeResult(topic: topic, outcome: "Not sent: only read-only queries are allowed", leaves: [])
        }
        guard let connection else {
            return ProbeResult(topic: topic, outcome: "Not connected", leaves: [])
        }
        do {
            let response = try await connection.send(topic, timeout: 15)
            let outcome = response.raw.isEmpty ? "Answered (empty)" : "Answered, \(response.raw.count) bytes"
            appendLog("Probe \(topic): \(outcome)")
            return ProbeResult(topic: topic, outcome: outcome, leaves: Research.flatten(response.message))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return ProbeResult(topic: topic, outcome: message, leaves: [])
        }
    }

    func cleanAll(settings: CleanSettings) async {
        await run("Starting whole-house clean") { connection in
            let used = try await connection.cleanAll(settings: settings)
            await MainActor.run { self.map = used }
        }
    }
}
