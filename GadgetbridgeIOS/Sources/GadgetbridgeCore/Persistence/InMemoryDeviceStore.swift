import Foundation

/// Non-persistent fallback `DeviceStore`, used if the on-disk store fails
/// to initialize (e.g. sandbox misconfiguration).
public final class InMemoryDeviceStore: DeviceStore {
    private var devices: [Device] = []

    public init() {}

    public func loadDevices() throws -> [Device] { devices }

    public func saveDevices(_ devices: [Device]) throws {
        self.devices = devices
    }
}
