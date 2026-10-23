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
    /// Saved maps; nil until loaded.
    private(set) var maps: [MapSummary]?
    private(set) var firmware: FirmwareVersions?
    private(set) var battery: BatteryHealth?
    /// An interrupted clean the robot offers to pick up.
    private(set) var continuable: ContinuableTask?
    private(set) var dryingMinutesLeft: Int?
    /// Cleans this app watched finish (area and time), kept on the phone.
    private(set) var ledger = CleaningLedger.load()
    /// The clean in progress: when it started and the most area seen.
    private var watching: (start: Date, squareMeters: Double, seconds: Int)?

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
        connect(force: true)
    }

    /// Saves a device id learned from the robot without reconnecting.
    /// Returns whether it was new.
    @discardableResult
    private func rememberDeviceId(_ id: String, source: String) -> Bool {
        guard DeviceInfo.isPlausibleId(id), id != deviceIdOverride else { return false }
        deviceIdOverride = id
        UserDefaults.standard.set(id, forKey: "robotDeviceId")
        appendLog("Saved device ID from \(source)")
        // The running connection already uses it; don't restart for it.
        if connection != nil { connectedWith = "\(host)|\(model.productKey)|\(id)" }
        return true
    }

    func setDeviceIdOverride(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != deviceIdOverride else { return }
        deviceIdOverride = trimmed
        UserDefaults.standard.set(trimmed, forKey: "robotDeviceId")
        connect(force: true)
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
        connect(force: true)
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

    /// The host, model and id the current connection was made with.
    private var connectedWith: String?

    /// Connects, or keeps the connection already running for the same robot:
    /// restarting it cuts the robot off before it has identified itself, and
    /// views and Bonjour can ask more than once. `force` always restarts.
    func connect(force: Bool = false) {
        guard isConfigured else { return }
        let target = "\(host)|\(model.productKey)|\(deviceIdOverride)"
        if !force, connection != nil, connectedWith == target {
            appendLog("Already connecting to the robot; not restarting")
            return
        }
        autoConnectPaused = false
        disconnect()
        connectedWith = target
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
            if robot.host == self.host, self.deviceIdOverride.isEmpty, let id = robot.deviceIdCandidate,
               self.rememberDeviceId(id, source: "Bonjour") {
                self.connect(force: true)
            }
        }
        probe.start()
        bonjourProbe = probe
    }

    func disconnect() {
        connectedWith = nil
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

    /// Quiet: a background load, so a failure is logged, not shown as an
    /// error, and it waits for the robot to be connected.
    func reloadHistory() async {
        guard let connection, connectionState != .disconnected, connectionState != .connecting else { return }
        do {
            history = try await connection.cleaningHistory()
        } catch {
            appendLog("Loading history: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
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

    func changeSetting(_ setting: RobotSetting, to choice: RobotSetting.Choice) async {
        await write(setting.title, expecting: { setting.choice(in: $0) == choice }) { try await $0.setSetting(choice) }
    }

    func changeNoStairs(_ on: Bool, mapId: Int) async {
        await write("No stairs", expecting: { $0.noStairs(mapId: mapId) == on }) {
            try await $0.setNoStairs(on, mapId: mapId)
        }
    }

    func saveCleaningOrder(_ rooms: [Int]) async {
        guard let mapId = map?.mapId else { return }
        await write("Cleaning order", expecting: { $0.cleaningOrder(mapId: mapId) == rooms }) {
            try await $0.setCleaningOrder(rooms, mapId: mapId)
        }
    }

    /// The saved House Cleaning Order for the current map, else map order.
    var cleaningOrder: [Int] {
        let rooms = map?.rooms.map(\.id) ?? []
        guard let mapId = map?.mapId, let saved = robotSettings?.cleaningOrder(mapId: mapId), !saved.isEmpty else {
            return rooms
        }
        return saved.filter(rooms.contains) + rooms.filter { !saved.contains($0) }
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
                Task {
                    await refreshAll()
                    if history == nil { await reloadHistory() }
                }
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
            if isCleaning {
                let area = Double(progress.areaSquareMeters ?? 0)
                if watching == nil || watching?.squareMeters == 0,
                   let resumed = ledger.reopen(ifContinuedWith: area) {
                    // The same clean after a mop wash or recharge: the
                    // robot's area keeps counting, so don't count it twice.
                    watching = (start: resumed.start, squareMeters: resumed.squareMeters, seconds: resumed.seconds)
                }
                var current = watching ?? (start: Date(), squareMeters: 0, seconds: 0)
                current.squareMeters = max(current.squareMeters, Double(progress.areaSquareMeters ?? 0))
                current.seconds = max(current.seconds, progress.elapsedSeconds ?? Int(Date().timeIntervalSince(current.start)))
                watching = current
            }
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
            watching = (start: Date(), squareMeters: 0, seconds: 0)
        }
        // A clean ended: keep its area and time on the phone. A pause or a
        // trip to the dock mid-clean isn't an end.
        if !new.workingStatus.isActiveCleaning, !new.isPaused, !new.isReturning, let finished = watching {
            ledger.add(.init(start: finished.start, end: Date(), squareMeters: finished.squareMeters,
                             seconds: finished.seconds > 0 ? finished.seconds : Int(Date().timeIntervalSince(finished.start))))
            watching = nil
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

    func cleanRooms(_ rooms: [Int], settings: CleanSettings, perRoom: [Int: CleanSettings] = [:],
                    options: CleanOptions = CleanOptions()) async {
        await run("Starting clean") { connection in
            let used = try await connection.cleanRooms(rooms, settings: settings, perRoom: perRoom, options: options)
            await MainActor.run { self.map = used }
        }
    }

    // MARK: Wood floor care

    /// Rooms set to Wood Floor, the only ones the robot maintains.
    var woodRooms: [Room] { map?.rooms.filter { $0.floor == .wood } ?? [] }

    func startFloorMaintenance(rooms: [Int], cleanFirst: Bool) async {
        await run("Starting floor maintenance") { connection in
            if let used = try await connection.startFloorMaintenance(rooms: rooms, cleanFirst: cleanFirst) {
                await MainActor.run { self.map = used }
            }
        }
    }

    // MARK: Maps

    func reloadMaps() async {
        guard let connection else { return }
        do {
            maps = try await connection.allMaps()
        } catch {
            appendLog("Maps: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
    }

    func switchMap(to id: Int) async {
        guard allowsWrites else { return }
        await run("Switch map") { connection in
            try await connection.switchMap(to: id)
            let fetched = try await connection.fetchMap()
            await MainActor.run { self.map = fetched }
        }
        await reloadMaps()
    }

    func deleteMap(_ id: Int) async {
        guard allowsWrites else { return }
        await run("Delete map") { try await $0.deleteMap(id) }
        await reloadMaps()
    }

    func startMapping(rebuildCurrent: Bool) async {
        guard allowsWrites else { return }
        let stairs = !(robotSettings?.noStairs(mapId: map?.mapId ?? 0) ?? false)
        await run(rebuildCurrent ? "Remapping" : "New secondary map") {
            try await $0.startMapping(rebuildCurrent: rebuildCurrent, hasStairs: stairs)
        }
    }

    // MARK: Device and parts

    func reloadDeviceInfo() async {
        guard let connection else { return }
        if let fetched = try? await connection.firmwareVersions() { firmware = fetched }
        if let fetched = try? await connection.batteryHealth() { battery = fetched }
    }

    func reboot() async {
        guard allowsWrites else { return }
        await run("Restart robot") { try await $0.reboot() }
    }

    func replacedPart(_ part: PartLife) async {
        part.setStart(hoursLeft: part.ratedHours)
        guard allowsWrites else { return }
        await run("\(part.name) replaced") { try await $0.resetConsumable(part.item) }
        await refreshAll()
    }

    func drainDockBase() async {
        guard allowsWrites else { return }
        await run("Dock Base Drainage") { try await $0.drainDockBase() }
    }

    func checkForInterruptedClean() async {
        guard let connection, !isCleaning else { return }
        continuable = try? await connection.continuableTask()
    }

    func continueInterruptedClean(_ resume: Bool) async {
        await run(resume ? "Resuming clean" : "Discarding interrupted clean") { try await $0.continueTask(resume) }
        continuable = nil
    }

    func reloadDryingTime() async {
        guard let connection else { return }
        dryingMinutesLeft = try? await connection.dryingTimeLeft()
    }

    /// Area cleaned in the last 7 days, including the clean in progress.
    var squareMetersThisWeek: Double {
        ledger.squareMetersThisWeek() + (watching?.squareMeters ?? 0)
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

    /// Whole house, in the saved House Cleaning Order.
    func cleanAll(settings: CleanSettings, options: CleanOptions = CleanOptions()) async {
        let order = cleaningOrder
        await run("Starting whole-house clean") { connection in
            let used: RobotMap
            if order.isEmpty {
                used = try await connection.cleanAll(settings: settings, options: options)
            } else {
                used = try await connection.cleanRooms(order, settings: settings, options: options)
            }
            await MainActor.run { self.map = used }
        }
    }
}
