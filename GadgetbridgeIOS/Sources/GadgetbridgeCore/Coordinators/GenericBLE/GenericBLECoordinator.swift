import Foundation

/// Supports any peripheral that advertises at least one standard,
/// documented Bluetooth SIG service (Heart Rate, Battery, Device
/// Information). This covers plain heart-rate straps and many entry-level
/// fitness bands, without needing a vendor-specific reverse-engineered
/// protocol the way Gadgetbridge's Mi Band/Amazfit/etc. coordinators do on
/// Android.
public final class GenericBLECoordinator: DeviceCoordinator {
    public let family: DeviceFamily = .genericBLEStandard
    public let displayName = "Generic BLE device"

    public init() {}

    public func canSupport(_ peripheral: DiscoveredPeripheral) -> Bool {
        let advertised = Set(peripheral.advertisedServiceUUIDs)
        return advertised.contains(StandardBLEService.heartRate)
            || advertised.contains(StandardBLEService.battery)
    }

    public func makeSession(for device: Device) -> DeviceSession {
        GenericBLESession(device: device)
    }
}
