import Foundation

public protocol DeviceManagerDelegate: AnyObject {
    func deviceManager(_ manager: DeviceManager, didDiscover peripheral: DiscoveredPeripheral, supportedBy coordinator: DeviceCoordinator?)
    func deviceManager(_ manager: DeviceManager, didUpdate device: Device)
    func deviceManager(_ manager: DeviceManager, didFailToConnect device: Device, error: Error)
    func deviceManager(_ manager: DeviceManager, didReceiveHeartRate sample: HeartRateSample)
    func deviceManager(_ manager: DeviceManager, didComputeHRV sample: HRVSample)
    /// Whether the sensor reports being in contact with skin. Worth
    /// surfacing: a strap that has slipped reports plausible-looking but
    /// meaningless numbers.
    func deviceManager(_ manager: DeviceManager, didUpdateSensorContact contact: HeartRateMeasurement.SensorContact, for device: Device)
}

public extension DeviceManagerDelegate {
    func deviceManager(_ manager: DeviceManager, didComputeHRV sample: HRVSample) {}
    func deviceManager(_ manager: DeviceManager, didUpdateSensorContact contact: HeartRateMeasurement.SensorContact, for device: Device) {}
}
