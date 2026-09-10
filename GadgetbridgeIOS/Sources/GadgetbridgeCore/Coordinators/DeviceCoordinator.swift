import Foundation

/// Mirrors the role of Gadgetbridge's `DeviceCoordinator` on Android: one
/// implementation per device family, responsible for (a) recognizing a
/// scanned peripheral as belonging to that family, and (b) creating the
/// `DeviceSession` that speaks its protocol once connected.
public protocol DeviceCoordinator: AnyObject {
    var family: DeviceFamily { get }
    var displayName: String { get }

    /// Whether pairing this device family requires a user-supplied secret
    /// (e.g. a per-device key extracted from the vendor's own app/account,
    /// as with `AmazfitHelioCoordinator`) before a connection can be
    /// authenticated. Defaults to `false`.
    var requiresPairingSecret: Bool { get }

    func canSupport(_ peripheral: DiscoveredPeripheral) -> Bool

    func makeSession(for device: Device) -> DeviceSession
}

public extension DeviceCoordinator {
    var requiresPairingSecret: Bool { false }
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
