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
        let shape: ResponseShape
    }
    private var expected: [Expected] = []
    private var waiting: [UInt64: CheckedContinuation<NarwalFrame, Error>] = [:]
    private var nextId: UInt64 = 0

    private var commandBusy = false
    private var commandQueue: [CheckedContinuation<Void, Never>] = []

    public init(host: String, port: Int = NarwalDefaults.port,
                productKey: String = NarwalDefaults.z10UltraProductKey, deviceId: String = "") {
        self.host = Self.normalizedHost(host)
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
            let attemptStarted = Date()
            var gotData = false
            guard let url = URL(string: "ws://\(hostForURL):\(port)") else {
                log("Invalid robot address \"\(host)\". Forget the robot and enter its IP address.")
                setState(.disconnected)
                return
            }
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
                    if !gotData {
                        gotData = true
                        log("First data from robot")
                    }
                    if state == .connecting { setState(.connected) }
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
            var wait = delay + Double.random(in: 0...1)
            if !gotData, Date().timeIntervalSince(attemptStarted) < 20 {
                // The robot refuses reconnection for ~10 s after dropping a
                // client, so retrying sooner only extends the outage.
                wait = max(wait, 12)
                log("Robot dropped the connection without answering. Usual causes: the Narwal app is open on this phone (the robot allows one connection per device), or the wrong model is selected in Settings. Retrying in \(Int(wait)) s.")
            }
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            delay = min(delay * 2, 60)
        }
    }

    private var hostForURL: String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    /// Trims whitespace and any interface scope ("192.168.1.5%en0"): Network
    /// framework addresses carry one, and a "%" makes the URL invalid.
    public static func normalizedHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
        return host
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

    /// Learns the device id the robot expects in topics. Only ever uses the
    /// configured product key: the Z10 Ultra hangs up on clients that send
    /// another model's key. A docked robot ignores everything while it wakes,
    /// so keep asking, and re-send the wake-up now and then.
    private func identify() async {
        for attempt in 1...15 {
            if Task.isCancelled || socket == nil { return }
            if await requestDeviceInfo() { return }
            if attempt % 3 == 0 { await sendWakeBurst() }
        }
        log("No answer to get_device_info after 45 s. Is the right model selected in Settings?")
    }

    private func requestDeviceInfo() async -> Bool {
        // Ignored while the robot wakes: no grace for late answers.
        guard let response = try? await send(Topic.getDeviceInfo, timeout: 3, lateGrace: 0),
              let info = DeviceInfo(response: response.message) else { return false }
        let resubscribe = !identityFromBroadcast
        if !info.productKey.isEmpty { productKey = info.productKey }
        deviceId = info.deviceId
        continuation.yield(.deviceInfo(info))
        log("Identified robot \(productKey) / \(deviceId), firmware \(info.firmware)")
        // The connect-time wake burst may have arrived while the robot was
        // still waking; subscribe again now that it answers.
        if resubscribe { await sendWakeBurst() }
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

    /// Hands a response to the oldest request it fits. Requests queued ahead
    /// of that one were evidently ignored by the robot (it does that while
    /// asleep, or for a wrong product key), so they're dropped instead of
    /// swallowing later answers.
    private func routeResponse(_ frame: NarwalFrame) {
        let message = (try? ProtoMessage(bytes: frame.payload)) ?? ProtoMessage(fields: [])
        let now = Date()
        expected.removeAll { $0.expires < now }
        guard let index = expected.firstIndex(where: { $0.shape.accepts(message) }) else {
            return  // a late answer to something already given up on
        }
        let match = expected[index]
        let ignored = expected[..<index]
        expected.removeFirst(index + 1)
        for request in ignored {
            waiting.removeValue(forKey: request.id)?.resume(throwing: NarwalError.timeout(request.topic))
        }
        waiting.removeValue(forKey: match.id)?.resume(returning: frame)
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
                                     expires: Date().addingTimeInterval(NarwalDefaults.unawaitedAckWindow),
                                     shape: ResponseShape(topic: short, fireAndForget: true)))
        }
        enqueue(short, payload) { _ in }
    }

    /// Sends a command and waits for its response.
    @discardableResult
    /// `lateGrace` is how long a timed-out request keeps its place so a late
    /// answer is dropped rather than misrouted; use 0 for probes the robot
    /// may ignore outright.
    public func send(_ short: String, _ payload: [UInt8] = [],
                     timeout: TimeInterval = NarwalDefaults.commandTimeout,
                     lateGrace: TimeInterval = NarwalDefaults.lateResponseGrace) async throws -> CommandResponse {
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
                                     expires: Date().addingTimeInterval(timeout + lateGrace),
                                     shape: ResponseShape(topic: short, fireAndForget: false)))
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

/// What a response to a given request must look like. Responses carry no
/// topic, so this is the only way to tell a skipped request from a slow one.
struct ResponseShape: Sendable {
    enum Kind: Sendable {
        case any
        /// Only varint fields, e.g. {1: 1}.
        case ack
        /// Require their payload in field 2, or an error status.
        case deviceInfo, map, baseStatus
    }

    let kind: Kind

    init(topic: String, fireAndForget: Bool) {
        switch topic {
        case Topic.getDeviceInfo: kind = .deviceInfo
        case Topic.getMap: kind = .map
        case Topic.getBaseStatus: kind = .baseStatus
        default: kind = fireAndForget ? .ack : .any
        }
    }

    /// {1: code} and nothing but varints.
    static func isStatusOnly(_ m: ProtoMessage) -> Bool {
        m.has(1) && m.fields.allSatisfy { if case .varint = $0.value { return true } else { return false } }
    }

    /// A status-only reply that reports failure is a valid answer to any query.
    static func isErrorStatus(_ m: ProtoMessage) -> Bool {
        isStatusOnly(m) && m.int(1) != CommandResult.success.rawValue
    }

    func accepts(_ m: ProtoMessage) -> Bool {
        switch kind {
        case .any:
            return true
        case .ack:
            return Self.isStatusOnly(m) || m.fields.isEmpty
        case .deviceInfo:
            return !(m.string(2)?.isEmpty ?? true) || Self.isErrorStatus(m)
        case .map:
            // Not a bare number in field 2: that's a status reply (#108).
            return m.message(2) != nil || Self.isErrorStatus(m)
        case .baseStatus:
            // Field 2 has been captured as both a message and a bare number.
            return m.has(2) || Self.isErrorStatus(m)
        }
    }
}
