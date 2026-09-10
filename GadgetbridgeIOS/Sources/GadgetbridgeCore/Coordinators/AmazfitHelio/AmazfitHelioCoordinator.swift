import Foundation

/// Recognizes and pairs with Zepp OS / Huami-protocol devices, written
/// against the Amazfit Helio Strap. See `AmazfitHelioSession` for the
/// authentication handshake and a detailed confidence breakdown of what's
/// implemented here versus best-effort/unverified.
public final class AmazfitHelioCoordinator: DeviceCoordinator {
    public let family: DeviceFamily = .amazfit
    public let displayName = "Amazfit Helio Strap"

    /// Zepp OS devices authenticate with a per-device secret provisioned by
    /// Huami's servers during first pairing through the official Zepp app —
    /// there's no way to derive or generate this locally. See
    /// `HuamiAuthKey`.
    public let requiresPairingSecret = true

    public init() {}

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
        return AmazfitHelioSession(device: device, authKey: authKey)
    }
}
