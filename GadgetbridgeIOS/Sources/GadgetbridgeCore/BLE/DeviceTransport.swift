import Foundation

/// Errors surfaced by a `DeviceTransport` implementation.
public enum DeviceTransportError: Error, Sendable {
    case notConnected
    case serviceNotFound(ServiceUUID)
    case characteristicNotFound(ServiceUUID)
    case timedOut
    case underlying(String)
}

extension DeviceTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the device."
        case .serviceNotFound(let uuid): return "The device doesn't expose the expected service (\(uuid))."
        case .characteristicNotFound(let uuid): return "The device doesn't expose the expected characteristic (\(uuid))."
        case .timedOut: return "Timed out waiting for the device to respond."
        case .underlying(let message): return message
        }
    }
}

/// Abstraction over a single connected GATT link, so `DeviceCoordinator`
/// implementations in `GadgetbridgeCore` never touch `CoreBluetooth`
/// directly. This is what makes coordinators unit-testable with a mock
/// transport, and keeps the door open for a non-Apple transport later.
public protocol DeviceTransport: AnyObject {
    func readValue(service: ServiceUUID, characteristic: ServiceUUID) async throws -> Data

    func writeValue(
        _ data: Data,
        service: ServiceUUID,
        characteristic: ServiceUUID,
        withResponse: Bool
    ) async throws

    /// Registers for value-change notifications. `onUpdate` fires on every
    /// GATT notify/indicate until `unsubscribe` is called or the transport
    /// disconnects.
    func subscribe(
        service: ServiceUUID,
        characteristic: ServiceUUID,
        onUpdate: @escaping (Data) -> Void
    ) throws

    func unsubscribe(service: ServiceUUID, characteristic: ServiceUUID) throws

    func disconnect()
}
