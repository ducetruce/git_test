import Foundation

/// Authenticates with a Zepp OS device (written against the Amazfit Helio
/// Strap) using the ECDH-over-NIST-B163 handshake Huami's newer firmware
/// uses, then falls back to standard BLE profiles for basic telemetry.
///
/// ## Confidence breakdown
///
/// This was built without access to a real Helio Strap or to Gadgetbridge's
/// exact source (this sandbox's network egress blocked Codeberg/GitHub raw
/// source access; what was available came through a summarizing fetch
/// tool, which paraphrases rather than guaranteeing verbatim extraction).
/// Treat confidence as follows:
///
/// - **High**: the elliptic-curve math (`GF2m163`, `ECPointB163`,
///   `ECDHB163`) and AES-128 (`AES128`) are from-scratch implementations
///   verified by self-consistency tests (both sides of a simulated ECDH
///   exchange agree; AES matches the canonical FIPS-197 test vector). Bugs
///   are possible but these are the most trustworthy pieces here.
/// - **Medium**: the curve choice (NIST B-163) and the general handshake
///   shape (send an ephemeral EC public key, receive the peer's key plus a
///   random nonce, derive a session key, echo an encrypted nonce back) are
///   corroborated by multiple independent sources.
/// - **Low / unverified**: the exact command opcode bytes
///   (`initiateCommandPrefix`, the `0x05` challenge command, the response
///   echo-byte convention, the `0x25` failure code), the exact byte ranges
///   used to derive the session key, and whether battery/heart-rate really
///   are exposed via the standard GATT services post-auth.
///
/// ## Capturing what really happens
///
/// Every byte written and every notification received is logged through
/// `ProtocolLogging`, **including notifications this code decides to
/// ignore** — because the most likely failure mode is that the low-confidence
/// assumptions above are wrong, in which case the device's real response is
/// sitting right there in the log being discarded. If the handshake times
/// out, the transcript is the raw material needed to correct the constants.
/// The log deliberately never contains the pairing key or the derived
/// session key; public keys, nonces and ciphertexts are logged, since those
/// cross the air in the clear anyway.
public final class AmazfitHelioSession: DeviceSession {
    public private(set) var device: Device
    private let authKey: HuamiAuthKey?
    private let logger: ProtocolLogging
    private let responseTimeout: TimeInterval

    private weak var transport: DeviceTransport?
    private weak var delegate: DeviceSessionDelegate?

    /// Guards `continuation`/`pendingEcho` so a notification, a failed
    /// write, and the timeout can't resume the same continuation twice.
    private let pendingLock = NSLock()
    private var pendingEcho: UInt8?
    private var continuation: CheckedContinuation<[UInt8], Error>?
    /// Readings arrive about once a second; the interesting part is the
    /// shape of the payload, which doesn't change within a connection. Log
    /// it once rather than flooding the transcript.
    private var hasLoggedMeasurementShape = false

    /// Reconstructed from a summarized read of Gadgetbridge's
    /// `InitOperation2021` — see the confidence breakdown above.
    private static let initiateCommandPrefix: [UInt8] = [0x04, 0x02, 0x00, 0x02]
    private static let challengeCommandPrefix: [UInt8] = [0x05]
    private static let authFailureStatusByte: UInt8 = 0x25

    public init(
        device: Device,
        authKey: HuamiAuthKey?,
        logger: ProtocolLogging = ProtocolLogger.shared,
        responseTimeout: TimeInterval = 15
    ) {
        self.device = device
        self.authKey = authKey
        self.logger = logger
        self.responseTimeout = responseTimeout
    }

    public func start(transport: DeviceTransport, delegate: DeviceSessionDelegate) async throws {
        self.transport = transport
        self.delegate = delegate

        // Heart-rate broadcast mode: the strap presents itself as an
        // ordinary standard-profile sensor, so there's no vendor handshake
        // to do and no pairing key involved. Prefer it whenever it's on —
        // it's the one path here that doesn't depend on reconstructed
        // protocol constants.
        if transport.hasCharacteristic(
            service: StandardBLEService.heartRate,
            characteristic: StandardBLECharacteristic.heartRateMeasurement
        ) {
            logger.log("=== \(device.name): standard Heart Rate service present ===")
            logger.log("Using broadcast mode — no vendor authentication needed, no pairing key used")
            await readBatteryIfAvailable()
            try subscribeToHeartRateIfAvailable()
            return
        }

        guard let authKey else {
            throw DeviceTransportError.underlying(
                "This device isn't broadcasting heart rate, so it needs the vendor handshake — which requires the 16-byte pairing key from your Zepp account. Either enable heart-rate broadcast on the strap, or supply the key."
            )
        }

        logger.log("=== Amazfit Helio handshake starting (device: \(device.name)) ===")
        logger.log("Auth characteristic: \(HuamiGATT.authCharacteristic) under service \(HuamiGATT.service)")

        try transport.subscribe(service: HuamiGATT.service, characteristic: HuamiGATT.authCharacteristic) { [weak self] data in
            self?.handleAuthNotification(data)
        }
        logger.log("Subscribed to auth characteristic notifications")

        let keyPair = ECDHB163.generateKeyPair()
        logger.log("Generated ephemeral B-163 key pair; public key (48 bytes): \(keyPair.publicKey.hexDump)")

        var initiateCommand = Self.initiateCommandPrefix
        initiateCommand.append(contentsOf: keyPair.publicKey)

        let peerKeyResponse = try await sendAndAwait(
            phase: "1/2 key exchange",
            expectedEcho: 0x04,
            command: initiateCommand
        ) {
            try await transport.writeValue(
                Data(initiateCommand), service: HuamiGATT.service, characteristic: HuamiGATT.authCharacteristic, withResponse: true
            )
        }

        let (remoteRandom, remotePublicKey) = try Self.parsePeerKeyResponse(peerKeyResponse, logger: logger)
        let sharedSecret = try ECDHB163.sharedSecret(privateKey: keyPair.privateKey, peerPublicKey: remotePublicKey)
        logger.log("Computed ECDH shared secret (24 bytes, redacted); deriving session key from bytes 8..<24 XOR pairing key")

        let sessionKey = Self.deriveSessionKey(sharedSecret: sharedSecret, authKey: authKey.bytes)
        let encryptedWithAuthKey = AES128.ecbEncrypt(remoteRandom, key: authKey.bytes)
        let encryptedWithSessionKey = AES128.ecbEncrypt(remoteRandom, key: sessionKey)

        var challengeCommand = Self.challengeCommandPrefix
        challengeCommand.append(contentsOf: encryptedWithAuthKey)
        challengeCommand.append(contentsOf: encryptedWithSessionKey)

        _ = try await sendAndAwait(
            phase: "2/2 encrypted challenge",
            expectedEcho: 0x05,
            command: challengeCommand
        ) {
            try await transport.writeValue(
                Data(challengeCommand), service: HuamiGATT.service, characteristic: HuamiGATT.authCharacteristic, withResponse: true
            )
        }

        logger.log("=== Handshake reported success ===")

        // The proprietary activity/sleep/workout sync protocol (Huami's
        // "chunked" data transfer) isn't implemented here. Battery and heart
        // rate are attempted via the same standard GATT services
        // `GenericBLE` uses, on the (unverified) assumption this device
        // keeps exposing them; failures here are non-fatal.
        await readBatteryIfAvailable()
        try? subscribeToHeartRateIfAvailable()
    }

    public func stop() {
        try? transport?.unsubscribe(service: HuamiGATT.service, characteristic: HuamiGATT.authCharacteristic)
        try? transport?.unsubscribe(service: StandardBLEService.heartRate, characteristic: StandardBLECharacteristic.heartRateMeasurement)
        transport = nil
        delegate = nil
    }

    public func sendAlert(_ alert: NotificationAlert) async throws {
        throw DeviceTransportError.underlying(
            "Sending alerts to Amazfit Helio isn't implemented — the proprietary notification protocol hasn't been reverse-engineered here"
        )
    }

    public func setTime(_ date: Date) async throws {
        throw DeviceTransportError.underlying(
            "Setting time on Amazfit Helio isn't implemented — the proprietary time-sync command hasn't been reverse-engineered here"
        )
    }

    // MARK: - Auth handshake plumbing

    private func sendAndAwait(
        phase: String,
        expectedEcho: UInt8,
        command: [UInt8],
        send: @escaping () async throws -> Void
    ) async throws -> [UInt8] {
        logger.log("-> phase \(phase): writing \(command.count) bytes: \(command.hexDump)")
        logger.log("   waiting for a notification whose byte[1] == 0x\(String(format: "%02X", expectedEcho)) (assumption, unverified)")

        return try await withCheckedThrowingContinuation { continuation in
            pendingLock.lock()
            self.pendingEcho = expectedEcho
            self.continuation = continuation
            pendingLock.unlock()

            Task {
                do {
                    try await send()
                } catch {
                    self.logger.log("!! write failed during phase \(phase): \(error.localizedDescription)")
                    self.claimPending()?.resume(throwing: error)
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(self.responseTimeout * 1_000_000_000))
                guard let pending = self.claimPending() else { return }
                self.logger.log(
                    "!! phase \(phase) timed out after \(self.responseTimeout)s. If notifications appear above marked 'ignored', "
                    + "this code's byte[1] echo assumption is wrong — those bytes are the device's real answer."
                )
                pending.resume(throwing: DeviceTransportError.timedOut)
            }
        }
    }

    /// Atomically takes ownership of the pending continuation, so only one
    /// of {notification, write failure, timeout} can ever resume it.
    private func claimPending() -> CheckedContinuation<[UInt8], Error>? {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        guard let pending = continuation else { return nil }
        continuation = nil
        pendingEcho = nil
        return pending
    }

    private enum NotificationDisposition {
        case nothingWaiting
        case tooShort
        case echoMismatch(expected: UInt8, actual: UInt8)
        case matched(CheckedContinuation<[UInt8], Error>)
    }

    private func classify(_ bytes: [UInt8]) -> NotificationDisposition {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        guard let expected = pendingEcho, let pending = continuation else { return .nothingWaiting }
        guard bytes.count >= 3 else { return .tooShort }
        guard bytes[1] == expected else { return .echoMismatch(expected: expected, actual: bytes[1]) }
        continuation = nil
        pendingEcho = nil
        return .matched(pending)
    }

    private func handleAuthNotification(_ data: Data) {
        let bytes = [UInt8](data)
        logger.log("<- auth notify (\(bytes.count) bytes): \(bytes.hexDump)")

        switch classify(bytes) {
        case .nothingWaiting:
            logger.log("   ...ignored: no handshake phase is waiting for a response right now")

        case .tooShort:
            logger.log("   ...ignored: fewer than the 3 header bytes this code expects")

        case .echoMismatch(let expected, let actual):
            logger.log(
                "   ...IGNORED: byte[1] is 0x\(String(format: "%02X", actual)) but this code expected "
                + "0x\(String(format: "%02X", expected)). This is a prime suspect — the echo convention is a guess."
            )

        case .matched(let pending):
            if bytes[2] == Self.authFailureStatusByte {
                logger.log("   ...device reported status 0x\(String(format: "%02X", bytes[2])) = authentication failure (bad pairing key?)")
                pending.resume(throwing: DeviceTransportError.underlying(
                    "Amazfit rejected the pairing key (device reported an authentication failure)"
                ))
            } else {
                logger.log("   ...accepted (status byte 0x\(String(format: "%02X", bytes[2])))")
                pending.resume(returning: bytes)
            }
        }
    }

    private static func parsePeerKeyResponse(_ bytes: [UInt8], logger: ProtocolLogging) throws -> (random: [UInt8], publicKey: [UInt8]) {
        guard bytes.count >= 67 else {
            logger.log(
                "!! key-exchange response is \(bytes.count) bytes; this code expects at least 67 "
                + "(3 header + 16 nonce + 48 public key). The layout assumption may be wrong."
            )
            throw DeviceTransportError.underlying("Auth key-exchange response too short (\(bytes.count) bytes, expected at least 67)")
        }
        let random = Array(bytes[3..<19])
        let publicKey = Array(bytes[19..<67])
        logger.log("   parsed device nonce (16 bytes): \(random.hexDump)")
        logger.log("   parsed device public key (48 bytes): \(publicKey.hexDump)")
        return (random, publicKey)
    }

    private static func deriveSessionKey(sharedSecret: [UInt8], authKey: [UInt8]) -> [UInt8] {
        zip(sharedSecret[8..<24], authKey).map { $0 ^ $1 }
    }

    // MARK: - Best-effort standard-profile telemetry (see type doc comment)

    private func readBatteryIfAvailable() async {
        guard let transport else { return }
        guard let data = try? await transport.readValue(
            service: StandardBLEService.battery,
            characteristic: StandardBLECharacteristic.batteryLevel
        ), let level = data.first else {
            logger.log("Standard battery service not readable on this device")
            return
        }

        let battery = BatteryInfo(level: Int(level))
        logger.log("Battery via standard GATT: \(battery.level)%")
        device.battery = battery
        delegate?.session(self, didUpdateBattery: battery)
    }

    private func logMeasurementShapeOnce(_ measurement: HeartRateMeasurement, raw: Data) {
        guard !hasLoggedMeasurementShape else { return }
        hasLoggedMeasurementShape = true
        logger.log("First heart rate notification (\(raw.count) bytes): \([UInt8](raw).hexDump)")
        logger.log("  \(measurement.diagnosticSummary)")
    }

    private func subscribeToHeartRateIfAvailable() throws {
        guard let transport else { return }
        try transport.subscribe(
            service: StandardBLEService.heartRate,
            characteristic: StandardBLECharacteristic.heartRateMeasurement
        ) { [weak self] data in
            guard let self, let measurement = HeartRateMeasurementParser.parse(data) else { return }
            self.logMeasurementShapeOnce(measurement, raw: data)
            self.delegate?.session(self, didReceive: measurement)
        }
    }
}
