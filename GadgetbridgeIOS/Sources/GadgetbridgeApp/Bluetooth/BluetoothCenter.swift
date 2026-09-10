#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation
import GadgetbridgeCore

/// The single `CBCentralManager` owner for the app. Implements both
/// `BLEScanning` and `PeripheralConnecting` from `GadgetbridgeCore`, so
/// `DeviceManager` never imports `CoreBluetooth` directly.
///
/// It also owns reconnection. A wearable goes out of range constantly —
/// another room, a shower, a phone left on a desk — and a tracker that
/// stops collecting until you notice and tap Connect isn't much of a
/// tracker. CoreBluetooth connect requests never time out, so re-issuing
/// one after an unexpected drop means iOS reconnects whenever the device
/// comes back, including from the background.
public final class BluetoothCenter: NSObject, BLEScanning, PeripheralConnecting {
    public private(set) var isScanning = false
    public weak var connectionObserver: PeripheralConnectionObserving?

    private var central: CBCentralManager!
    private var onDiscover: ((DiscoveredPeripheral) -> Void)?
    private var wantsScanningWhenPoweredOn = false

    private var knownPeripherals: [String: CBPeripheral] = [:]
    private var pendingConnections: [String: CheckedContinuation<DeviceTransport, Error>] = [:]
    private var activeTransports: [String: CBDeviceTransport] = [:]
    /// Links we want kept alive. A user-initiated disconnect removes the id;
    /// anything else dropping is treated as temporary.
    private var reconnectingIds: Set<String> = []

    private let logger: ProtocolLogging

    public init(logger: ProtocolLogging = ProtocolLogger.shared) {
        self.logger = logger
        super.init()
        // The restoration identifier is what lets iOS relaunch the app into
        // the background when a peripheral it was connected to reappears.
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.example.gadgetbridge.central"]
        )
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

        reconnectingIds.insert(peripheralId)
        return try await withCheckedThrowingContinuation { continuation in
            pendingConnections[peripheralId] = continuation
            central.connect(peripheral, options: nil)
        }
    }

    public func disconnect(peripheralId: String) {
        reconnectingIds.remove(peripheralId)
        activeTransports.removeValue(forKey: peripheralId)?.disconnect()
        // Without this the radio link stays up even though nothing is
        // listening, draining both batteries.
        if let peripheral = knownPeripherals[peripheralId] {
            central.cancelPeripheralConnection(peripheral)
        }
        logger.log("Disconnected \(peripheralId) — automatic reconnection off")
    }
}

extension BluetoothCenter: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn, wantsScanningWhenPoweredOn, let onDiscover else { return }
        wantsScanningWhenPoweredOn = false
        startScan(onDiscover: onDiscover)
    }

    /// iOS relaunched us and handed back the peripherals we were connected
    /// to. Adopt them so a reconnect doesn't require the app to have been
    /// running continuously.
    public func centralManager(_ central: CBCentralManager, willRestoreState state: [String: Any]) {
        guard let restored = state[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] else { return }
        for peripheral in restored {
            let id = peripheral.identifier.uuidString
            knownPeripherals[id] = peripheral
            reconnectingIds.insert(id)
            peripheral.delegate = activeTransports[id]
        }
        logger.log("Restored \(restored.count) peripheral(s) after relaunch")
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
            guard let self else { return }
            if let pending = self.pendingConnections.removeValue(forKey: id) {
                pending.resume(returning: transport)
            } else {
                // Nobody is awaiting this one, so it's a reconnection: the
                // session has to be restarted against the new transport.
                self.logger.log("Reconnected \(id)")
                self.connectionObserver?.peripheralDidReconnect(id: id, transport: transport)
            }
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

        // A connection still being awaited failed mid-handshake.
        if let pending = pendingConnections.removeValue(forKey: id) {
            pending.resume(throwing: error ?? DeviceTransportError.underlying("Disconnected during connect"))
            return
        }

        let willRetry = reconnectingIds.contains(id)
        logger.log("Link to \(id) dropped\(willRetry ? " — waiting for it to return" : "")")
        connectionObserver?.peripheralDidDisconnect(id: id, willRetry: willRetry)

        // A connect request with no timeout is exactly the primitive needed
        // here: iOS completes it whenever the device is in range again.
        if willRetry {
            central.connect(peripheral, options: nil)
        }
    }
}
#endif
