import Foundation

/// Establishes the GATT connection for a peripheral discovered or
/// previously paired, and hands back a `DeviceTransport` once ready.
/// Implemented by `BluetoothCenter` in the app target.
public protocol PeripheralConnecting: AnyObject {
    func connect(peripheralId: String) async throws -> DeviceTransport

    /// Tears the link down for good and stops any automatic reconnection.
    /// Distinct from a dropped link: walking out of range should reconnect
    /// on its own, but a user tapping Disconnect should not.
    func disconnect(peripheralId: String)

    /// Notified about links that drop and come back without anyone asking.
    var connectionObserver: PeripheralConnectionObserving? { get set }
}

public protocol PeripheralConnectionObserving: AnyObject {
    /// A link dropped. `willRetry` distinguishes "out of range, we're
    /// waiting for it" from "gone, and nothing further will happen".
    func peripheralDidDisconnect(id: String, willRetry: Bool)

    /// A dropped link came back on its own. The transport is new, so the
    /// session has to be restarted against it.
    func peripheralDidReconnect(id: String, transport: DeviceTransport)
}
