import Foundation

/// A platform-agnostic view of a Bluetooth LE scan result.
public struct DiscoveredPeripheral: Identifiable, Hashable, Sendable {
    /// `CBPeripheral.identifier.uuidString` on Apple platforms.
    public let id: String
    public let name: String?
    public let rssi: Int
    public let advertisedServiceUUIDs: [ServiceUUID]

    public init(id: String, name: String?, rssi: Int, advertisedServiceUUIDs: [ServiceUUID]) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.advertisedServiceUUIDs = advertisedServiceUUIDs
    }
}
