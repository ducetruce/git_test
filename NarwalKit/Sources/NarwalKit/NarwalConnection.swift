import Foundation

public struct CommandResponse: Sendable {
    public let message: ProtoMessage
    public let raw: [UInt8]

    /// Field 1 is a result code for actions but data for queries; a
    /// non-integer field 1 means a data response, which counts as success.
    public var resultCode: Int {
        if case .varint(let v) = message.first(1) { return Int(truncatingIfNeeded: v) }
        return CommandResult.success.rawValue
    }

    public var result: CommandResult? { CommandResult(rawValue: resultCode) }
    public var accepted: Bool { resultCode == 1 || resultCode == 6 }
}

public enum NarwalError: Error, LocalizedError, Equatable {
    case notConnected
    case timeout(String)
    case rejected(String, Int)
    case noMap

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the robot."
        case .timeout(let t): return "The robot didn't answer \(t)."
        case .rejected(let t, let code):
            switch CommandResult(rawValue: code) {
            case .notApplicable: return "The robot can't do that right now (\(t))."
            case .conflict: return "That's already in progress (\(t))."
            case .notReady: return "The robot isn't ready (\(t)). Room cleans must start from the dock."
            default: return "The robot refused \(t) (code \(code))."
            }
        case .noMap: return "No saved map yet. Run a mapping clean in the Narwal app first."
        }
    }
}

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    /// Socket open but no broadcast or reply yet.
    case connected
    /// Broadcasting: live data is flowing.
    case awake
    case asleep
}

public enum NarwalEvent: Sendable {
    case connection(ConnectionState)
    case deviceInfo(DeviceInfo)
    case baseStatus(BaseStatus)
    case progress(WorkingProgress)
    case pose(LivePose)
    case broadcast(NarwalFrame)
    case log(String)
}

/// One local WebSocket session with a robot, kept alive across sleeps and
/// network blips.
public actor NarwalConnection {
    public nonisolated let events: AsyncStream<NarwalEvent>
    private let continuation: AsyncStream<NarwalEvent>.Continuation

    public let host: String
    public let port: Int
    public private(set) var productKey: String
    public private(set) var deviceId: String

    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var runTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var state: ConnectionState = .disconnected

    private var lastBroadcast: Date = .distantPast
    private var lastDisplayMap: Date = .distantPast
    private var lastSubscription: Date = .distantPast
    private var lastDropoutRecovery: Date = .distantPast
    private var lastWorkingStatus: WorkingStatus = .unknown
    /// Set while a WebSocket ping awaits its pong; detects dead sockets that
    /// would otherwise hang until a TCP timeout.
    private var pingSentAt: Date?
    /// Broadcast topics carry the robot's real product key and device id.
    private var identityFromBroadcast = false

    // Responses carry no topic, so each is matched to the oldest request
    // still owed one. Timed-out requests keep their place for a grace period
    // so their late answers are dropped rather than handed to the next caller.
    private struct Expected {
        let id: UInt64
        let topic: String
        let expires: Date
    }
    private var expected: [Expected] = []
    private var waiting: [UInt64: CheckedContinuation<NarwalFrame, Error>] = [:]
    private var nextId: UInt64 = 0

    private var commandBusy = false
    private var commandQueue: [CheckedContinuation<Void, Never>] = []

    public init(host: String, port: Int = NarwalDefaults.port,
                productKey: String = NarwalDefaults.z10UltraProductKey, deviceId: String = "") {
        self.host = host
        self.port = port
        self.productKey = productKey
        self.deviceId = deviceId
        let (stream, continuation) = AsyncStream<NarwalEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.events = stream
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        // For WebSocket tasks this is an idle timeout: with a short value the
        // socket drops whenever a sleeping robot stays quiet. Dead sockets are
        // detected by the ping/pong check in the keepalive loop instead.
        config.timeoutIntervalForRequest = 24 * 60 * 60
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        self.session = URLSession(configuration: config, delegate: SocketDelegate(continuation), delegateQueue: nil)
    }

    // MARK: Lifecycle

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { await self.runLoop() }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        failAllWaiting()
        setState(.disconnected)
        // A session holds its delegate until invalidated.
        session.invalidateAndCancel()
    }

    /// Call when the app returns to the foreground: re-wakes the robot and
    /// renews the broadcast subscription immediately.
    public func refresh() async {
        guard socket != nil else { return }
        await sendWakeBurst()
    }

    private func runLoop() async {
        var delay: TimeInterval = 1
        while !Task.isCancelled {
            setState(.connecting)
            let url = URL(string: "ws://\(hostForURL):\(port)")!
            log("Connecting to \(url.absoluteString) as /\(productKey)/\(deviceId.isEmpty ? "<no id yet>" : deviceId)")
            let ws = session.webSocketTask(with: url)
            ws.maximumMessageSize = 16 * 1024 * 1024
            socket = ws
            ws.resume()
            expected.removeAll()
            pingSentAt = nil

            // A fresh connection can trip the robot's deep-sleep wake handler,
            // but only if commands arrive promptly.
            await sendWakeBurst()
            keepaliveTask?.cancel()
            keepaliveTask = Task { await self.keepaliveLoop() }
            Task { await self.identify() }

            do {
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    if state == .connecting {
                        setState(.connected)
                        log("First data from robot")
                    }
                    delay = 1
                    if case .data(let data) = message {
                        handle([UInt8](data))
                    }
                }
            } catch {
                let ns = error as NSError
                var detail = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
                if ws.closeCode != .invalid {
                    let reason = ws.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    detail += "; robot closed with \(ws.closeCode.rawValue) \(reason)"
                }
                log("Connection lost after \(state == .connecting ? "no data" : "receiving data"): \(detail)")
            }

            keepaliveTask?.cancel()
            keepaliveTask = nil
            if socket === ws { socket = nil }
            ws.cancel(with: .goingAway, reason: nil)
            failAllWaiting()
            if Task.isCancelled { break }
            setState(.disconnected)
            let wait = delay + Double.random(in: 0...1)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            delay = min(delay * 2, 60)
        }
    }

    private var hostForURL: String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    private func setState(_ new: ConnectionState) {
        guard new != state else { return }
        state = new
        continuation.yield(.connection(new))
    }

    private func log(_ text: String) {
        continuation.yield(.log(text))
    }

    // MARK: Identity

    private static let fallbackProductKeys = [
        NarwalDefaults.z10UltraProductKey, "qV6BujoYLz", "QoEsI5qYXO", "QxMSPG6VSO",
        "iSuVlI1If2", "mkbqaprvrb", "hEA7OEshlx", "fjhpiem4ba", "ulonq49mm1", "CNbforyZWI",
    ]

    /// Learns the device id (and product key) the robot expects in topics.
    /// The robot answers only commands that carry its own product key.
    private func identify() async {
        let preferred = productKey
        let keys = [preferred] + Self.fallbackProductKeys.filter { $0 != preferred }
        // A robot that is still waking ignores commands, so make several passes.
        for _ in 0..<3 {
            for key in keys {
                // Broadcast topics are authoritative; stop guessing once one arrives.
                if !identityFromBroadcast { productKey = key }
                if await requestDeviceInfo() { return }
                if Task.isCancelled || socket == nil { return }
                if identityFromBroadcast { break }
            }
        }
        if !identityFromBroadcast { productKey = preferred }
        log("Robot did not answer get_device_info")
    }

    private func requestDeviceInfo() async -> Bool {
        guard let response = try? await send(Topic.getDeviceInfo, timeout: 3),
              let info = DeviceInfo(response: response.message) else { return false }
        let wakeWentToOtherKey = !identityFromBroadcast
        if !info.productKey.isEmpty { productKey = info.productKey }
        deviceId = info.deviceId
        continuation.yield(.deviceInfo(info))
        log("Identified robot \(productKey) / \(deviceId), firmware \(info.firmware)")
        // The connect-time wake burst may have carried a guessed product key,
        // which the robot ignores; subscribe again under the real identity.
        if wakeWentToOtherKey { await sendWakeBurst() }
        return true
    }

    // MARK: Incoming

    private func handle(_ bytes: [UInt8]) {
        guard let frame = try? NarwalFrame(bytes: bytes) else { return }
        if frame.kind == .response {
            if state != .awake { setState(.connected) }
            routeResponse(frame)
            return
        }

        lastBroadcast = Date()
        setState(.awake)
        if let id = frame.topicDeviceId, let key = frame.topicProductKey {
            deviceId = id
            productKey = key
            identityFromBroadcast = true
        }
        continuation.yield(.broadcast(frame))

        guard let message = try? ProtoMessage(bytes: frame.payload) else { return }
        switch frame.shortTopic {
        case Topic.robotBaseStatus:
            let status = BaseStatus(message)
            lastWorkingStatus = status.workingStatus
            continuation.yield(.baseStatus(status))
        case Topic.workingStatus:
            continuation.yield(.progress(WorkingProgress(message)))
        case Topic.displayMap:
            lastDisplayMap = Date()
            if let pose = LivePose(message) { continuation.yield(.pose(pose)) }
        default:
            break
        }
    }

    private func routeResponse(_ frame: NarwalFrame) {
        let now = Date()
        while !expected.isEmpty {
            let next = expected.removeFirst()
            if next.expires < now { continue }
            if let waiter = waiting.removeValue(forKey: next.id) {
                waiter.resume(returning: frame)
            }
            // Otherwise: a fire-and-forget ack or a late answer. Dropped.
            return
        }
    }

    private func failAllWaiting() {
        let pending = waiting
        waiting.removeAll()
        expected.removeAll()
        for (_, waiter) in pending { waiter.resume(throwing: NarwalError.notConnected) }
    }

    // MARK: Outgoing

    private func fullTopic(_ short: String) -> String {
        "/\(productKey)/\(deviceId)/\(short)"
    }

    /// Queues a frame on the socket synchronously, so frames reach the wire
    /// in exactly the order their expected responses were recorded.
    private func enqueue(_ short: String, _ payload: [UInt8], onError: @escaping @Sendable (Error) -> Void) {
        guard let ws = socket else {
            onError(NarwalError.notConnected)
            return
        }
        let frame = NarwalFrame(topic: fullTopic(short), payload: payload)
        ws.send(.data(Data(frame.encoded()))) { error in
            if let error { onError(error) }
        }
        if short == Topic.activeRobotPublish { lastSubscription = Date() }
    }

    /// Sends without waiting; its ack (if any) still takes a place in the
    /// response order so it can't be mistaken for a real command's answer.
    public func sendUnawaited(_ short: String, _ payload: [UInt8] = []) {
        guard socket != nil else { return }
        if !Topic.unacknowledged.contains(short) {
            nextId += 1
            expected.append(Expected(id: nextId, topic: short,
                                     expires: Date().addingTimeInterval(NarwalDefaults.unawaitedAckWindow)))
        }
        enqueue(short, payload) { _ in }
    }

    /// Sends a command and waits for its response.
    @discardableResult
    public func send(_ short: String, _ payload: [UInt8] = [],
                     timeout: TimeInterval = NarwalDefaults.commandTimeout) async throws -> CommandResponse {
        guard socket != nil else { throw NarwalError.notConnected }
        await acquireCommandSlot()
        defer { releaseCommandSlot() }

        nextId += 1
        let id = nextId
        let timer = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self.fail(id, NarwalError.timeout(short))
        }
        defer { timer.cancel() }

        let frame: NarwalFrame = try await withCheckedThrowingContinuation { cont in
            waiting[id] = cont
            expected.append(Expected(id: id, topic: short,
                                     expires: Date().addingTimeInterval(timeout + NarwalDefaults.lateResponseGrace)))
            enqueue(short, payload) { error in
                Task { await self.fail(id, error) }
            }
        }
        let message = (try? ProtoMessage(bytes: frame.payload)) ?? ProtoMessage(fields: [])
        return CommandResponse(message: message, raw: frame.payload)
    }

    /// Like `send`, but throws unless the robot accepted the command.
    @discardableResult
    public func perform(_ short: String, _ payload: [UInt8] = [],
                        timeout: TimeInterval = NarwalDefaults.commandTimeout) async throws -> CommandResponse {
        let response = try await send(short, payload, timeout: timeout)
        guard response.accepted else { throw NarwalError.rejected(short, response.resultCode) }
        return response
    }

    private func fail(_ id: UInt64, _ error: Error) {
        // The Expected entry stays queued until it expires, so a late answer
        // is discarded instead of misrouted.
        waiting.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func acquireCommandSlot() async {
        if !commandBusy {
            commandBusy = true
            return
        }
        await withCheckedContinuation { commandQueue.append($0) }
    }

    private func releaseCommandSlot() {
        if commandQueue.isEmpty {
            commandBusy = false
        } else {
            commandQueue.removeFirst().resume()
        }
    }

    // MARK: Wake & keepalive

    private func pongReceived(failed: Bool) {
        if !failed { pingSentAt = nil }
    }

    private func sendWakeBurst() async {
        sendUnawaited(Topic.notifyAppEvent, Payloads.singleVarint(1))
        try? await Task.sleep(nanoseconds: 200_000_000)
        sendUnawaited(Topic.activeRobotPublish, Payloads.topicSubscription())
        try? await Task.sleep(nanoseconds: 200_000_000)
        sendUnawaited(Topic.activeRobotPublish, Payloads.singleVarint(NarwalDefaults.subscriptionDuration))
        try? await Task.sleep(nanoseconds: 200_000_000)
        sendUnawaited(Topic.appHeartbeat, Payloads.singleVarint(1))
        try? await Task.sleep(nanoseconds: 200_000_000)
        // Passive commands wake only the socket server; a query wakes the
        // application processor. Its answer is discarded.
        sendUnawaited(Topic.getBaseStatus)
    }

    private func keepaliveLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(NarwalDefaults.keepaliveInterval * 1_000_000_000))
            if Task.isCancelled || socket == nil { return }
            let now = Date()

            // Resets the robot's 60 s idle-disconnect timer.
            sendUnawaited(Topic.appHeartbeat, Payloads.singleVarint(1))

            if let sent = pingSentAt, now.timeIntervalSince(sent) > 2 * NarwalDefaults.keepaliveInterval {
                log("No pong from robot; reconnecting")
                socket?.cancel(with: .abnormalClosure, reason: nil)
                return
            }
            if pingSentAt == nil, let ws = socket {
                pingSentAt = now
                ws.sendPing { error in
                    Task { await self.pongReceived(failed: error != nil) }
                }
            }

            let stale = now.timeIntervalSince(lastBroadcast) > NarwalDefaults.broadcastStaleAfter
            if stale {
                if state == .awake { setState(.asleep) }
                await sendWakeBurst()
                continue
            }
            if now.timeIntervalSince(lastSubscription) > NarwalDefaults.subscriptionRenewInterval {
                sendUnawaited(Topic.activeRobotPublish, Payloads.topicSubscription())
            }
            // The live map can stop mid-clean while status keeps flowing;
            // a wake burst restores the display_map subscription.
            if lastWorkingStatus.isActiveCleaning,
               now.timeIntervalSince(lastDisplayMap) > NarwalDefaults.displayMapDropoutAfter,
               now.timeIntervalSince(lastDropoutRecovery) > 45 {
                lastDropoutRecovery = now
                log("Live map stalled; re-subscribing")
                await sendWakeBurst()
            }
        }
    }
}

/// Reports WebSocket handshake and close details to the connection log; the
/// async receive() API alone only says that something failed.
final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<NarwalEvent>.Continuation

    init(_ continuation: AsyncStream<NarwalEvent>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        continuation.yield(.log("WebSocket handshake OK"))
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let text = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        continuation.yield(.log("Robot closed the socket: code \(closeCode.rawValue) \(text)"))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let ns = error as NSError
        var line = "Socket ended: \(ns.domain) \(ns.code) \(ns.localizedDescription)"
        if let http = task.response as? HTTPURLResponse {
            line += " (handshake HTTP \(http.statusCode))"
        }
        continuation.yield(.log(line))
    }
}
