import Foundation

/// Establishes the GATT connection for a peripheral discovered or
/// previously paired, and hands back a `DeviceTransport` once ready.
/// Implemented by `CoreBluetoothConnector` in the app target.
public protocol PeripheralConnecting: AnyObject {
    func connect(peripheralId: String) async throws -> DeviceTransport
}
