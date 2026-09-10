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
///   are exposed via the standard GATT services post-auth. These are
///   reconstructed best-effort and need confirmation via a BLE HCI snoop
///   capture of the real Zepp app pairing with a real device — exactly how
///   Gadgetbridge's own contributors originally reverse-engineered this.
public final class AmazfitHelioSession: DeviceSession {
    public private(set) var device: Device
    private let authKey: HuamiAuthKey?

    private weak var transport: DeviceTransport?
    private weak var delegate: DeviceSessionDelegate?

    private var pendingEcho: UInt8?
    private var continuation: CheckedContinuation<[UInt8], Error>?

    /// Reconstructed from a summarized read of Gadgetbridge's
    /// `InitOperation2021` — see the confidence breakdown above.
    private static let initiateCommandPrefix: [UInt8] = [0x04, 0x02, 0x00, 0x02]
    private static let challengeCommandPrefix: [UInt8] = [0x05]
    private static let authFailureStatusByte: UInt8 = 0x25

    public init(device: Device, authKey: HuamiAuthKey?) {
        self.device = device
        self.authKey = authKey
    }

    public func start(transport: DeviceTransport, delegate: DeviceSessionDelegate) async throws {
        guard let authKey else {
            throw DeviceTransportError.underlying(
                "Amazfit Helio requires a 16-byte pairing key extracted from your Zepp app account; none was provided or it wasn't valid 32-character hex"
            )
        }

        self.transport = transport
        self.delegate = delegate

        try transport.subscribe(service: HuamiGATT.service, characteristic: HuamiGATT.authCharacteristic) { [weak self] data in
            self?.handleAuthNotification(data)
        }

        let keyPair = ECDHB163.generateKeyPair()

        let peerKeyResponse = try await sendAndAwait(expectedEcho: 0x04) {
            var command = Self.initiateCommandPrefix
            command.append(contentsOf: keyPair.publicKey)
            try await transport.writeValue(
                Data(command), service: HuamiGATT.service, characteristic: HuamiGATT.authCharacteristic, withResponse: true
            )
        }

        let (remoteRandom, remotePublicKey) = try Self.parsePeerKeyResponse(peerKeyResponse)
        let sharedSecret = try ECDHB163.sharedSecret(privateKey: keyPair.privateKey, peerPublicKey: remotePublicKey)
        let sessionKey = Self.deriveSessionKey(sharedSecret: sharedSecret, authKey: authKey.bytes)

        let encryptedWithAuthKey = AES128.ecbEncrypt(remoteRandom, key: authKey.bytes)
        let encryptedWithSessionKey = AES128.ecbEncrypt(remoteRandom, key: sessionKey)

        _ = try await sendAndAwait(expectedEcho: 0x05) {
            var command = Self.challengeCommandPrefix
            command.append(contentsOf: encryptedWithAuthKey)
            command.append(contentsOf: encryptedWithSessionKey)
            try await transport.writeValue(
                Data(command), service: HuamiGATT.service, characteristic: HuamiGATT.authCharacteristic, withResponse: true
            )
        }

        // Authenticated. The proprietary activity/sleep/workout sync
        // protocol (Huami2021's "chunked" data transfer) isn't implemented
        // here — see the type-level doc comment. Battery and heart rate
        // are attempted via the same standard GATT services `GenericBLE`
        // uses, on the (unverified) assumption this device keeps exposing
        // them for compatibility; failures here are non-fatal.
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

    /// No timeout: if the device never notifies back (wrong key format
    /// aside from the explicit failure code, firmware quirk, etc.) this
    /// hangs indefinitely rather than failing cleanly. A production version
    /// should wrap this in a `Task`-based timeout.
    private func sendAndAwait(expectedEcho: UInt8, send: @escaping () async throws -> Void) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            self.pendingEcho = expectedEcho
            self.continuation = continuation
            Task {
                do {
                    try await send()
                } catch {
                    if self.continuation != nil {
                        self.continuation = nil
                        self.pendingEcho = nil
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func handleAuthNotification(_ data: Data) {
        guard let continuation, let expectedEcho else { return }
        let bytes = [UInt8](data)
        // Too short to inspect, or not the phase we're waiting on: keep
        // waiting rather than resolving with garbage.
        guard bytes.count >= 3, bytes[1] == expectedEcho else { return }

        self.continuation = nil
        self.pendingEcho = nil

        if bytes[2] == Self.authFailureStatusByte {
            continuation.resume(throwing: DeviceTransportError.underlying(
                "Amazfit rejected the pairing key (device reported an authentication failure)"
            ))
        } else {
            continuation.resume(returning: bytes)
        }
    }

    private static func parsePeerKeyResponse(_ bytes: [UInt8]) throws -> (random: [UInt8], publicKey: [UInt8]) {
        guard bytes.count >= 67 else {
            throw DeviceTransportError.underlying("Auth key-exchange response too short (\(bytes.count) bytes, expected at least 67)")
        }
        let random = Array(bytes[3..<19])
        let publicKey = Array(bytes[19..<67])
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
        ), let level = data.first else { return }

        let battery = BatteryInfo(level: Int(level))
        device.battery = battery
        delegate?.session(self, didUpdateBattery: battery)
    }

    private func subscribeToHeartRateIfAvailable() throws {
        guard let transport else { return }
        try transport.subscribe(
            service: StandardBLEService.heartRate,
            characteristic: StandardBLECharacteristic.heartRateMeasurement
        ) { [weak self] data in
            guard let self, let bpm = HeartRateMeasurementParser.parseBPM(from: data) else { return }
            let sample = HeartRateSample(deviceId: self.device.id, timestamp: Date(), beatsPerMinute: bpm)
            self.delegate?.session(self, didReceiveHeartRate: sample)
        }
    }
}
