import Foundation

/// Top-level orchestrator: owns scanning, pairing, connect/disconnect
/// lifecycle, and dispatches incoming device data to the `ActivityRepository`.
/// This is the `GadgetbridgeCore` equivalent of Gadgetbridge's
/// `DeviceCommunicationService` + `DeviceManager` combination on Android,
/// minus anything that relies on Android-only OS hooks.
@MainActor
public final class DeviceManager {
    public weak var delegate: DeviceManagerDelegate?
    public private(set) var pairedDevices: [Device]

    private let scanner: BLEScanning
    private let connector: PeripheralConnecting
    private let registry: DeviceCoordinatorRegistry
    private let repository: ActivityRepository
    private let deviceStore: DeviceStore
    private var activeSessions: [UUID: DeviceSession] = [:]

    public init(
        scanner: BLEScanning,
        connector: PeripheralConnecting,
        registry: DeviceCoordinatorRegistry = .shared,
        repository: ActivityRepository,
        deviceStore: DeviceStore
    ) {
        self.scanner = scanner
        self.connector = connector
        self.registry = registry
        self.repository = repository
        self.deviceStore = deviceStore
        self.pairedDevices = (try? deviceStore.loadDevices()) ?? []
    }

    // MARK: - Scanning & pairing

    public func startScanning() {
        scanner.startScan { [weak self] peripheral in
            guard let self else { return }
            let coordinator = self.registry.coordinator(for: peripheral)
            self.delegate?.deviceManager(self, didDiscover: peripheral, supportedBy: coordinator)
        }
    }

    public func stopScanning() {
        scanner.stopScan()
    }

    @discardableResult
    public func pair(_ peripheral: DiscoveredPeripheral, as coordinator: DeviceCoordinator, pairingSecretHex: String? = nil) -> Device {
        let device = Device(
            name: peripheral.name ?? coordinator.displayName,
            peripheralIdentifier: peripheral.id,
            family: coordinator.family,
            pairingSecretHex: pairingSecretHex
        )
        pairedDevices.append(device)
        persistDevices()
        return device
    }

    public func unpair(_ device: Device) {
        disconnect(device)
        pairedDevices.removeAll { $0.id == device.id }
        persistDevices()
    }

    // MARK: - Connection lifecycle

    public func connect(_ device: Device) async {
        guard let coordinator = registry.coordinator(for: device.family) else { return }
        updateDevice(device.id) { $0.connectionState = .connecting }

        do {
            let transport = try await connector.connect(peripheralId: device.peripheralIdentifier)
            let session = coordinator.makeSession(for: device)
            try await session.start(transport: transport, delegate: self)
            activeSessions[device.id] = session
            updateDevice(device.id) {
                $0.connectionState = .connected
                $0.lastSyncDate = Date()
            }
        } catch {
            updateDevice(device.id) { $0.connectionState = .disconnected }
            delegate?.deviceManager(self, didFailToConnect: device, error: error)
        }
    }

    public func disconnect(_ device: Device) {
        activeSessions[device.id]?.stop()
        activeSessions.removeValue(forKey: device.id)
        updateDevice(device.id) { $0.connectionState = .disconnected }
    }

    public func sendAlert(_ alert: NotificationAlert, to device: Device) async throws {
        guard let session = activeSessions[device.id] else { throw DeviceTransportError.notConnected }
        try await session.sendAlert(alert)
    }

    public func syncTime(to device: Device) async throws {
        guard let session = activeSessions[device.id] else { throw DeviceTransportError.notConnected }
        try await session.setTime(Date())
    }

    // MARK: - Private

    private func updateDevice(_ id: UUID, _ mutate: (inout Device) -> Void) {
        guard let index = pairedDevices.firstIndex(where: { $0.id == id }) else { return }
        mutate(&pairedDevices[index])
        persistDevices()
        delegate?.deviceManager(self, didUpdate: pairedDevices[index])
    }

    private func persistDevices() {
        try? deviceStore.saveDevices(pairedDevices)
    }
}

extension DeviceManager: DeviceSessionDelegate {
    public func session(_ session: DeviceSession, didUpdateBattery battery: BatteryInfo) {
        updateDevice(session.device.id) { $0.battery = battery }
    }

    public func session(_ session: DeviceSession, didReceiveHeartRate sample: HeartRateSample) {
        try? repository.save(sample)
        delegate?.deviceManager(self, didReceiveHeartRate: sample)
    }

    public func session(_ session: DeviceSession, didUpdateDeviceInfo device: Device) {
        updateDevice(device.id) {
            $0.manufacturer = device.manufacturer
            $0.modelNumber = device.modelNumber
            $0.firmwareVersion = device.firmwareVersion
        }
    }
}
