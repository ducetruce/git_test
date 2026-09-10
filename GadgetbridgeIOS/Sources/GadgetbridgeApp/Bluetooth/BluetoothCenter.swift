#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation
import GadgetbridgeCore

/// The single `CBCentralManager` owner for the app. Implements both
/// `BLEScanning` and `PeripheralConnecting` from `GadgetbridgeCore`, so
/// `DeviceManager` never imports `CoreBluetooth` directly.
public final class BluetoothCenter: NSObject, BLEScanning, PeripheralConnecting {
    public private(set) var isScanning = false

    private var central: CBCentralManager!
    private var onDiscover: ((DiscoveredPeripheral) -> Void)?
    private var wantsScanningWhenPoweredOn = false

    private var knownPeripherals: [String: CBPeripheral] = [:]
    private var pendingConnections: [String: CheckedContinuation<DeviceTransport, Error>] = [:]
    private var activeTransports: [String: CBDeviceTransport] = [:]

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - BLEScanning

    public func startScan(onDiscover: @escaping (DiscoveredPeripheral) -> Void) {
        self.onDiscover = onDiscover
        guard central.state == .poweredOn else {
            wantsScanningWhenPoweredOn = true
            return
        }
        isScanning = true
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        wantsScanningWhenPoweredOn = false
        isScanning = false
        central.stopScan()
    }

    // MARK: - PeripheralConnecting

    public func connect(peripheralId: String) async throws -> DeviceTransport {
        guard let uuid = UUID(uuidString: peripheralId) else {
            throw DeviceTransportError.underlying("Invalid peripheral identifier: \(peripheralId)")
        }

        let peripheral: CBPeripheral
        if let known = knownPeripherals[peripheralId] {
            peripheral = known
        } else if let retrieved = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            peripheral = retrieved
            knownPeripherals[peripheralId] = retrieved
        } else {
            throw DeviceTransportError.underlying("iOS no longer remembers this peripheral; re-pair it")
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingConnections[peripheralId] = continuation
            central.connect(peripheral, options: nil)
        }
    }
}

extension BluetoothCenter: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn, wantsScanningWhenPoweredOn, let onDiscover else { return }
        wantsScanningWhenPoweredOn = false
        startScan(onDiscover: onDiscover)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier.uuidString
        knownPeripherals[id] = peripheral
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])
            .map { $0.map { ServiceUUID($0.uuidString) } } ?? []
        onDiscover?(DiscoveredPeripheral(
            id: id,
            name: peripheral.name,
            rssi: RSSI.intValue,
            advertisedServiceUUIDs: serviceUUIDs
        ))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier.uuidString
        let transport = CBDeviceTransport(peripheral: peripheral)
        activeTransports[id] = transport
        peripheral.delegate = transport

        transport.onReady = { [weak self] in
            self?.pendingConnections.removeValue(forKey: id)?.resume(returning: transport)
        }
        transport.onFailure = { [weak self] error in
            self?.pendingConnections.removeValue(forKey: id)?.resume(throwing: error)
        }
        transport.beginDiscovery()
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier.uuidString
        pendingConnections.removeValue(forKey: id)?.resume(
            throwing: error ?? DeviceTransportError.underlying("Connection failed")
        )
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier.uuidString
        activeTransports.removeValue(forKey: id)?.disconnect()
    }
}
#endif
