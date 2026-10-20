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

    // UI
    private(set) var busyAction: String?
    var lastError: String?
    private(set) var log: [String] = []

    let alerts = AlertMonitor()

    private var connection: NarwalConnection?
    private var eventTask: Task<Void, Never>?

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
        if !status.errors.isEmpty { return "Needs attention" }
        if status.isReturning { return "Returning to dock" }
        if status.isPaused { return "Paused" }
        switch status.workingStatus {
        case .cleaning, .cleaningV2, .cleaningAlt, .customCleaning: return "Cleaning"
        case .remapping: return "Mapping"
        case .taskCompleted: return "Finished, heading home"
        case .charged: return "Docked"
        case .docked, .dockedV2: return status.battery == 100 ? "Docked" : "Charging"
        case .standby: return status.isDocked == true ? "Docked" : "Idle"
        case .unknown: return "Unknown state (\(status.rawWorkingStatus.map(String.init) ?? "-"))"
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
        let connection = NarwalConnection(host: host)
        self.connection = connection
        eventTask = Task { [weak self] in
            for await event in connection.events {
                self?.apply(event)
            }
        }
        Task { await connection.start() }
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
        if let fetched = try? await connection.consumableAlerts() {
            consumables = fetched
            alerts.consumablesChanged(fetched)
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
            appendLog("Connection: \(state)")
            if state == .awake || state == .connected {
                Task { await refreshAll() }
            }
        case .deviceInfo(let info):
            deviceInfo = info
            appendLog("Robot \(info.productKey) / fw \(info.firmware)")
        case .baseStatus(let status):
            applyStatus(status)
        case .progress(let progress):
            self.progress = progress
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
