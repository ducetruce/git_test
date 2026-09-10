import Foundation

public protocol DeviceManagerDelegate: AnyObject {
    func deviceManager(_ manager: DeviceManager, didDiscover peripheral: DiscoveredPeripheral, supportedBy coordinator: DeviceCoordinator?)
    func deviceManager(_ manager: DeviceManager, didUpdate device: Device)
    func deviceManager(_ manager: DeviceManager, didFailToConnect device: Device, error: Error)
    func deviceManager(_ manager: DeviceManager, didReceiveHeartRate sample: HeartRateSample)
}
