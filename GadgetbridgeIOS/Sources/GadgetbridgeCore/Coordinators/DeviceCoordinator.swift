import Foundation

/// Mirrors the role of Gadgetbridge's `DeviceCoordinator` on Android: one
/// implementation per device family, responsible for (a) recognizing a
/// scanned peripheral as belonging to that family, and (b) creating the
/// `DeviceSession` that speaks its protocol once connected.
public protocol DeviceCoordinator: AnyObject {
    var family: DeviceFamily { get }
    var displayName: String { get }

    func canSupport(_ peripheral: DiscoveredPeripheral) -> Bool

    func makeSession(for device: Device) -> DeviceSession
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
    func session(_ session: DeviceSession, didReceiveHeartRate sample: HeartRateSample)
    func session(_ session: DeviceSession, didUpdateDeviceInfo device: Device)
}
