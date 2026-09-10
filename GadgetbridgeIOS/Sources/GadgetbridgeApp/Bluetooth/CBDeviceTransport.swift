#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation
import GadgetbridgeCore

/// `DeviceTransport` backed by a connected `CBPeripheral`. Owned by
/// `BluetoothCenter`, which creates one per connection and wires it up as
/// the peripheral's delegate.
final class CBDeviceTransport: NSObject, DeviceTransport {
    private let peripheral: CBPeripheral
    private var subscriptions: [String: (Data) -> Void] = [:]
    private var readContinuations: [String: CheckedContinuation<Data, Error>] = [:]
    private var writeContinuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var discoveredCharacteristics: [String: CBCharacteristic] = [:]
    private var pendingServiceDiscoveryCount = 0
    private var didBecomeReady = false

    /// Fired once service + characteristic discovery has finished and the
    /// transport is safe to hand to a `DeviceSession`.
    var onReady: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
    }

    func beginDiscovery() {
        peripheral.discoverServices(nil)
    }

    // MARK: - DeviceTransport

    func readValue(service: ServiceUUID, characteristic: ServiceUUID) async throws -> Data {
        guard let ch = discoveredCharacteristics[key(service, characteristic)] else {
            throw DeviceTransportError.characteristicNotFound(characteristic)
        }
        return try await withCheckedThrowingContinuation { continuation in
            readContinuations[key(service, characteristic)] = continuation
            peripheral.readValue(for: ch)
        }
    }

    func writeValue(
        _ data: Data,
        service: ServiceUUID,
        characteristic: ServiceUUID,
        withResponse: Bool
    ) async throws {
        guard let ch = discoveredCharacteristics[key(service, characteristic)] else {
            throw DeviceTransportError.characteristicNotFound(characteristic)
        }
        guard withResponse else {
            peripheral.writeValue(data, for: ch, type: .withoutResponse)
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeContinuations[key(service, characteristic)] = continuation
            peripheral.writeValue(data, for: ch, type: .withResponse)
        }
    }

    func subscribe(
        service: ServiceUUID,
        characteristic: ServiceUUID,
        onUpdate: @escaping (Data) -> Void
    ) throws {
        guard let ch = discoveredCharacteristics[key(service, characteristic)] else {
            throw DeviceTransportError.characteristicNotFound(characteristic)
        }
        subscriptions[key(service, characteristic)] = onUpdate
        peripheral.setNotifyValue(true, for: ch)
    }

    func unsubscribe(service: ServiceUUID, characteristic: ServiceUUID) throws {
        guard let ch = discoveredCharacteristics[key(service, characteristic)] else { return }
        subscriptions.removeValue(forKey: key(service, characteristic))
        peripheral.setNotifyValue(false, for: ch)
    }

    func disconnect() {
        // BluetoothCenter owns the CBCentralManager and performs the actual
        // cancelPeripheralConnection call; this transport just stops caring
        // about further updates.
        subscriptions.removeAll()
    }

    // MARK: - Private

    private func key(_ service: ServiceUUID, _ characteristic: ServiceUUID) -> String {
        "\(service.uuidString)/\(characteristic.uuidString)"
    }
}

extension CBDeviceTransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            onFailure?(error)
            return
        }
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            markReadyIfNeeded()
            return
        }
        pendingServiceDiscoveryCount = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        defer {
            pendingServiceDiscoveryCount -= 1
            if pendingServiceDiscoveryCount <= 0 {
                markReadyIfNeeded()
            }
        }
        guard error == nil, let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            let k = "\(service.uuid.uuidString.uppercased())/\(characteristic.uuid.uuidString.uppercased())"
            discoveredCharacteristics[k] = characteristic
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let serviceUUID = characteristic.service?.uuid.uuidString.uppercased() else { return }
        let k = "\(serviceUUID)/\(characteristic.uuid.uuidString.uppercased())"

        if let continuation = readContinuations.removeValue(forKey: k) {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: characteristic.value ?? Data())
            }
            return
        }

        guard error == nil, let data = characteristic.value else { return }
        subscriptions[k]?(data)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let serviceUUID = characteristic.service?.uuid.uuidString.uppercased() else { return }
        let k = "\(serviceUUID)/\(characteristic.uuid.uuidString.uppercased())"
        guard let continuation = writeContinuations.removeValue(forKey: k) else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func markReadyIfNeeded() {
        guard !didBecomeReady else { return }
        didBecomeReady = true
        onReady?()
    }
}
#endif
