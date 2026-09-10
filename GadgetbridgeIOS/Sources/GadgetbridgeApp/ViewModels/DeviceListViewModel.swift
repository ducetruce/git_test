import Foundation
import GadgetbridgeCore

@MainActor
final class DeviceListViewModel: ObservableObject {
    @Published private(set) var pairedDevices: [Device] = []
    @Published private(set) var discovered: [DiscoveredPeripheral] = []
    @Published private(set) var isScanning = false
    @Published var lastError: String?

    /// Bumped whenever a new reading lands, so screens showing stored
    /// samples know to re-query without polling.
    @Published private(set) var latestSampleAt: Date?

    /// Skin-contact state from the last measurement, when the sensor
    /// reports it. A slipped strap emits plausible-looking nonsense, so
    /// this is worth showing rather than silently charting.
    @Published private(set) var sensorContact: HeartRateMeasurement.SensorContact = .notSupported

    let manager: DeviceManager
    private var discoverySupport: [String: DeviceCoordinator] = [:]

    init(manager: DeviceManager) {
        self.manager = manager
        self.pairedDevices = manager.pairedDevices
        manager.delegate = self
    }

    func startScanning() {
        discovered = []
        discoverySupport = [:]
        isScanning = true
        manager.startScanning()
    }

    func stopScanning() {
        isScanning = false
        manager.stopScanning()
    }

    func pair(_ peripheral: DiscoveredPeripheral, pairingSecretHex: String? = nil) {
        guard let coordinator = discoverySupport[peripheral.id] else { return }
        let device = manager.pair(peripheral, as: coordinator, pairingSecretHex: pairingSecretHex)
        pairedDevices = manager.pairedDevices
        Task { await manager.connect(device) }
    }

    func requiresPairingSecret(_ peripheral: DiscoveredPeripheral) -> Bool {
        discoverySupport[peripheral.id]?.requiresPairingSecret ?? false
    }

    func connect(_ device: Device) {
        Task { await manager.connect(device) }
    }

    func disconnect(_ device: Device) {
        manager.disconnect(device)
        pairedDevices = manager.pairedDevices
    }

    func unpair(_ device: Device) {
        manager.unpair(device)
        pairedDevices = manager.pairedDevices
    }
}

extension DeviceListViewModel: DeviceManagerDelegate {
    func deviceManager(
        _ manager: DeviceManager,
        didDiscover peripheral: DiscoveredPeripheral,
        supportedBy coordinator: DeviceCoordinator?
    ) {
        // Peripherals whose family has no registered coordinator can't be
        // paired yet (e.g. proprietary Mi Band/Amazfit protocols) — surface
        // them as unsupported in the UI rather than silently dropping them.
        if let coordinator {
            discoverySupport[peripheral.id] = coordinator
        }
        if let idx = discovered.firstIndex(where: { $0.id == peripheral.id }) {
            discovered[idx] = peripheral
        } else {
            discovered.append(peripheral)
        }
    }

    func deviceManager(_ manager: DeviceManager, didUpdate device: Device) {
        pairedDevices = manager.pairedDevices
    }

    func deviceManager(_ manager: DeviceManager, didFailToConnect device: Device, error: Error) {
        lastError = "Couldn't connect to \(device.name): \(error.localizedDescription)"
    }

    func deviceManager(_ manager: DeviceManager, didReceiveHeartRate sample: HeartRateSample) {
        // HomeViewModel reads the stored samples; this just tells it when.
        latestSampleAt = sample.timestamp
    }

    func deviceManager(_ manager: DeviceManager, didComputeHRV sample: HRVSample) {
        latestSampleAt = sample.timestamp
    }

    func deviceManager(
        _ manager: DeviceManager,
        didUpdateSensorContact contact: HeartRateMeasurement.SensorContact,
        for device: Device
    ) {
        sensorContact = contact
    }

    func isSupported(_ peripheral: DiscoveredPeripheral) -> Bool {
        discoverySupport[peripheral.id] != nil
    }
}
