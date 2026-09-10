import Foundation

/// Recognizes and pairs with Zepp OS / Huami-protocol devices, written
/// against the Amazfit Helio Strap. See `AmazfitHelioSession` for the
/// authentication handshake and a detailed confidence breakdown of what's
/// implemented here versus best-effort/unverified.
public final class AmazfitHelioCoordinator: DeviceCoordinator {
    public let family: DeviceFamily = .amazfit
    public let displayName = "Amazfit Helio Strap"

    /// Zepp OS devices normally authenticate with a per-device secret
    /// provisioned by Huami's servers during first pairing through the
    /// official Zepp app, which can't be derived locally (see `HuamiAuthKey`).
    ///
    /// The exception is heart-rate broadcast mode: the strap then advertises
    /// the standard Heart Rate service and behaves like any other
    /// standard-profile sensor, with no handshake and no key. Demanding a key
    /// in that case would block pairing for no reason.
    public func requiresPairingSecret(for peripheral: DiscoveredPeripheral) -> Bool {
        !peripheral.advertisedServiceUUIDs.contains(StandardBLEService.heartRate)
    }

    private let logger: ProtocolLogging

    public init(logger: ProtocolLogging = ProtocolLogger.shared) {
        self.logger = logger
    }

    public func canSupport(_ peripheral: DiscoveredPeripheral) -> Bool {
        if peripheral.advertisedServiceUUIDs.contains(HuamiGATT.service) {
            return true
        }
        if let name = peripheral.name?.lowercased(), name.contains("helio") {
            return true
        }
        return false
    }

    public func makeSession(for device: Device) -> DeviceSession {
        let authKey = device.pairingSecretHex.flatMap { HuamiAuthKey(hexString: $0) }
        return AmazfitHelioSession(device: device, authKey: authKey, logger: logger)
    }
}
