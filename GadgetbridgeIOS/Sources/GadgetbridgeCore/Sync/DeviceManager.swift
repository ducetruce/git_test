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
    /// One HRV window per device: beat-to-beat intervals arrive a couple at
    /// a time and only mean something in aggregate.
    private var hrvAccumulators: [UUID: HRVAccumulator] = [:]

    /// Sensors notify about once a second. Every reading is published live,
    /// but persisting all of them means ~86k rows per device per day, which
    /// the store and every query that touches it would carry forever — so
    /// what gets written is downsampled to this interval.
    private let storageInterval: TimeInterval
    private var lastStoredHeartRate: [UUID: Date] = [:]

    /// How much history to keep. Older buckets are discarded on connect.
    private let retention: TimeInterval

    public init(
        scanner: BLEScanning,
        connector: PeripheralConnecting,
        registry: DeviceCoordinatorRegistry = .shared,
        repository: ActivityRepository,
        deviceStore: DeviceStore,
        storageInterval: TimeInterval = 15,
        retention: TimeInterval = 30 * 24 * 3600
    ) {
        self.scanner = scanner
        self.connector = connector
        self.registry = registry
        self.repository = repository
        self.deviceStore = deviceStore
        self.storageInterval = storageInterval
        self.retention = retention
        self.pairedDevices = (try? deviceStore.loadDevices()) ?? []
        connector.connectionObserver = self
    }

    /// Reconnects every paired device that was linked when the app last
    /// stopped. Called at launch so collection resumes without the user
    /// having to open the app and tap anything.
    public func reconnectKnownDevices() async {
        for device in pairedDevices where device.lastSyncDate != nil {
            await connect(device)
        }
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
        try? repository.prune(before: Date().addingTimeInterval(-retention))
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
        // A partial HRV window spanning a disconnect would mix beats from
        // two sessions, so drop it.
        hrvAccumulators[device.id]?.reset()
        // Deliberate disconnect: also stop the automatic reconnection, or
        // the link would come straight back.
        connector.disconnect(peripheralId: device.peripheralIdentifier)
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

extension DeviceManager: PeripheralConnectionObserving {
    public nonisolated func peripheralDidDisconnect(id: String, willRetry: Bool) {
        Task { @MainActor in
            guard let device = pairedDevices.first(where: { $0.peripheralIdentifier == id }) else { return }
            activeSessions[device.id]?.stop()
            activeSessions.removeValue(forKey: device.id)
            hrvAccumulators[device.id]?.reset()
            // While a retry is pending the device is on its way back, which
            // is a different state from "you disconnected this".
            updateDevice(device.id) { $0.connectionState = willRetry ? .connecting : .disconnected }
        }
    }

    public nonisolated func peripheralDidReconnect(id: String, transport: DeviceTransport) {
        Task { @MainActor in
            guard let device = pairedDevices.first(where: { $0.peripheralIdentifier == id }),
                  let coordinator = registry.coordinator(for: device.family) else { return }
            do {
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
    }
}

extension DeviceManager: DeviceSessionDelegate {
    public func session(_ session: DeviceSession, didUpdateBattery battery: BatteryInfo) {
        updateDevice(session.device.id) { $0.battery = battery }
    }

    public func session(_ session: DeviceSession, didReceive measurement: HeartRateMeasurement) {
        let deviceId = session.device.id
        let now = Date()
        let sample = HeartRateSample(
            deviceId: deviceId,
            timestamp: now,
            beatsPerMinute: measurement.beatsPerMinute
        )

        // Publish every reading — the live display should be live — but
        // only write one per `storageInterval`.
        delegate?.deviceManager(self, didReceiveHeartRate: sample)

        let elapsed = lastStoredHeartRate[deviceId].map { now.timeIntervalSince($0) } ?? .infinity
        if elapsed >= storageInterval {
            lastStoredHeartRate[deviceId] = now
            try? repository.save(sample)
        }

        if measurement.sensorContact != .notSupported, let device = pairedDevices.first(where: { $0.id == deviceId }) {
            delegate?.deviceManager(self, didUpdateSensorContact: measurement.sensorContact, for: device)
        }

        guard !measurement.rrIntervals.isEmpty else { return }
        let accumulator = hrvAccumulators[deviceId] ?? {
            let new = HRVAccumulator()
            hrvAccumulators[deviceId] = new
            return new
        }()
        if let hrv = accumulator.add(measurement.rrIntervals, deviceId: deviceId) {
            try? repository.save(hrv)
            delegate?.deviceManager(self, didComputeHRV: hrv)
        }
    }

    public func session(_ session: DeviceSession, didUpdateDeviceInfo device: Device) {
        updateDevice(device.id) {
            $0.manufacturer = device.manufacturer
            $0.modelNumber = device.modelNumber
            $0.firmwareVersion = device.firmwareVersion
        }
    }
}
