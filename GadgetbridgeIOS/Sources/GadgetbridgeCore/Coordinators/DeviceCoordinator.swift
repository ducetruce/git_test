import Foundation

/// Mirrors the role of Gadgetbridge's `DeviceCoordinator` on Android: one
/// implementation per device family, responsible for (a) recognizing a
/// scanned peripheral as belonging to that family, and (b) creating the
/// `DeviceSession` that speaks its protocol once connected.
public protocol DeviceCoordinator: AnyObject {
    var family: DeviceFamily { get }
    var displayName: String { get }

    /// Whether pairing *this particular peripheral* requires a user-supplied
    /// secret (e.g. a per-device key from the vendor's own account) before a
    /// connection can be authenticated.
    ///
    /// It takes the peripheral rather than being a fixed property of the
    /// family because the same hardware can need a key or not depending on
    /// how it's presenting itself: an Amazfit strap in heart-rate broadcast
    /// mode is a plain standard-profile sensor with no handshake at all.
    /// Defaults to `false`.
    func requiresPairingSecret(for peripheral: DiscoveredPeripheral) -> Bool

    func canSupport(_ peripheral: DiscoveredPeripheral) -> Bool

    func makeSession(for device: Device) -> DeviceSession
}

public extension DeviceCoordinator {
    func requiresPairingSecret(for peripheral: DiscoveredPeripheral) -> Bool { false }
}

/// An active protocol session for one connected device. `start` is called
/// once a `DeviceTransport` is available (i.e. the GATT connection is up);
/// implementations subscribe to characteristics and translate incoming
/// bytes into `GadgetbridgeCore` model types via the delegate.
public protocol DeviceSession: AnyObject {
    var device: Device { get }

    func start(transport: DeviceTransport, delegate: DeviceSessionDelegate) async throws
    func stop()

    func sendAlert(_ alert: NotificationAlert) async throws
    func setTime(_ date: Date) async throws
}

public protocol DeviceSessionDelegate: AnyObject {
    func session(_ session: DeviceSession, didUpdateBattery battery: BatteryInfo)
    /// The full heart rate measurement, not just the pulse rate: sessions
    /// pass everything `0x2A37` carried so beat-to-beat intervals reach the
    /// HRV pipeline rather than being discarded at the edge.
    func session(_ session: DeviceSession, didReceive measurement: HeartRateMeasurement)
    func session(_ session: DeviceSession, didUpdateDeviceInfo device: Device)
}
