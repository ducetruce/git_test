import Foundation

/// A wearable device known to the app, independent of whether it is
/// currently connected. Persisted so the user's paired devices survive
/// app relaunches.
public struct Device: Identifiable, Codable, Hashable, Sendable {
    /// Stable local identifier. Distinct from `peripheralIdentifier` because
    /// CoreBluetooth peripheral identifiers can change across a device
    /// unpairing/re-pairing on iOS.
    public let id: UUID

    public var name: String

    /// `CBPeripheral.identifier.uuidString`. iOS does not expose a device's
    /// Bluetooth MAC address to apps, unlike Android.
    public var peripheralIdentifier: String

    public var family: DeviceFamily

    public var firmwareVersion: String?
    public var manufacturer: String?
    public var modelNumber: String?
    public var battery: BatteryInfo?
    public var connectionState: ConnectionState
    public var lastSyncDate: Date?

    /// Opaque, family-specific pairing secret, hex-encoded. Some vendor
    /// protocols (e.g. `AmazfitHelioCoordinator`'s Zepp OS auth) can't
    /// authenticate without a per-device key the user extracts from the
    /// vendor's own app/account;
    /// `DeviceCoordinator.requiresPairingSecret(for:)` signals when a given
    /// peripheral needs one. Unused otherwise — including by an Amazfit
    /// strap in heart-rate broadcast mode, which needs no key at all.
    public var pairingSecretHex: String?

    public init(
        id: UUID = UUID(),
        name: String,
        peripheralIdentifier: String,
        family: DeviceFamily,
        firmwareVersion: String? = nil,
        manufacturer: String? = nil,
        modelNumber: String? = nil,
        battery: BatteryInfo? = nil,
        connectionState: ConnectionState = .disconnected,
        lastSyncDate: Date? = nil,
        pairingSecretHex: String? = nil
    ) {
        self.id = id
        self.name = name
        self.peripheralIdentifier = peripheralIdentifier
        self.family = family
        self.firmwareVersion = firmwareVersion
        self.manufacturer = manufacturer
        self.modelNumber = modelNumber
        self.battery = battery
        self.connectionState = connectionState
        self.lastSyncDate = lastSyncDate
        self.pairingSecretHex = pairingSecretHex
    }
}
