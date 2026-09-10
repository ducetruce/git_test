import Foundation

/// Abstraction over Bluetooth LE scanning so `GadgetbridgeCore` stays
/// portable and unit-testable without `CoreBluetooth`. The real
/// implementation (`CoreBluetoothScanner`) lives in the app target.
public protocol BLEScanning: AnyObject {
    var isScanning: Bool { get }
    func startScan(onDiscover: @escaping (DiscoveredPeripheral) -> Void)
    func stopScan()
}
