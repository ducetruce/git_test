import XCTest
@testable import GadgetbridgeCore

private final class CountingRepository: ActivityRepository {
    private(set) var savedHeartRates: [HeartRateSample] = []
    private(set) var pruneCalls: [Date] = []

    func save(_ sample: ActivitySample) throws {}
    func save(_ sample: HeartRateSample) throws { savedHeartRates.append(sample) }
    func save(_ sample: HRVSample) throws {}
    func save(_ session: SleepSession) throws {}
    func activitySamples(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [ActivitySample] { [] }
    func heartRateSamples(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [HeartRateSample] { savedHeartRates }
    func hrvSamples(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [HRVSample] { [] }
    func sleepSessions(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [SleepSession] { [] }
    func prune(before date: Date) throws { pruneCalls.append(date) }
}

private final class StubScanner: BLEScanning {
    var isScanning = false
    func startScan(onDiscover: @escaping (DiscoveredPeripheral) -> Void) {}
    func stopScan() {}
}

private final class StubConnector: PeripheralConnecting {
    weak var connectionObserver: PeripheralConnectionObserving?
    private(set) var disconnectedIds: [String] = []

    func connect(peripheralId: String) async throws -> DeviceTransport {
        throw DeviceTransportError.notConnected
    }

    func disconnect(peripheralId: String) {
        disconnectedIds.append(peripheralId)
    }
}

private final class StubSession: DeviceSession {
    var device: Device
    init(device: Device) { self.device = device }
    func start(transport: DeviceTransport, delegate: DeviceSessionDelegate) async throws {}
    func stop() {}
    func sendAlert(_ alert: NotificationAlert) async throws {}
    func setTime(_ date: Date) async throws {}
}

private final class CountingDelegate: DeviceManagerDelegate {
    private(set) var publishedHeartRates = 0
    func deviceManager(_ manager: DeviceManager, didDiscover peripheral: DiscoveredPeripheral, supportedBy coordinator: DeviceCoordinator?) {}
    func deviceManager(_ manager: DeviceManager, didUpdate device: Device) {}
    func deviceManager(_ manager: DeviceManager, didFailToConnect device: Device, error: Error) {}
    func deviceManager(_ manager: DeviceManager, didReceiveHeartRate sample: HeartRateSample) { publishedHeartRates += 1 }
}

@MainActor
final class DeviceManagerStorageTests: XCTestCase {
    private func makeManager(
        repository: CountingRepository,
        connector: StubConnector = StubConnector(),
        storageInterval: TimeInterval = 15
    ) -> DeviceManager {
        DeviceManager(
            scanner: StubScanner(),
            connector: connector,
            registry: DeviceCoordinatorRegistry(),
            repository: repository,
            deviceStore: InMemoryDeviceStore(),
            storageInterval: storageInterval
        )
    }

    /// A 1 Hz sensor would write ~86k rows per device per day. Every reading
    /// still reaches the UI; only the writes are downsampled.
    func testRapidReadingsArePublishedLiveButStoredOnce() {
        let repository = CountingRepository()
        let delegate = CountingDelegate()
        let manager = makeManager(repository: repository)
        manager.delegate = delegate

        let device = Device(name: "Strap", peripheralIdentifier: "p1", family: .genericBLEStandard)
        let session = StubSession(device: device)

        for bpm in 60...69 {
            manager.session(session, didReceive: HeartRateMeasurement(beatsPerMinute: bpm))
        }

        XCTAssertEqual(delegate.publishedHeartRates, 10, "Every reading should reach the UI")
        XCTAssertEqual(repository.savedHeartRates.count, 1, "…but only one should be written within the interval")
    }

    func testAnIntervalOfZeroStoresEveryReading() {
        let repository = CountingRepository()
        let manager = makeManager(repository: repository, storageInterval: 0)

        let device = Device(name: "Strap", peripheralIdentifier: "p1", family: .genericBLEStandard)
        let session = StubSession(device: device)

        for bpm in 60...64 {
            manager.session(session, didReceive: HeartRateMeasurement(beatsPerMinute: bpm))
        }

        XCTAssertEqual(repository.savedHeartRates.count, 5)
    }

    func testThrottleIsPerDeviceNotGlobal() {
        let repository = CountingRepository()
        let manager = makeManager(repository: repository)

        let first = StubSession(device: Device(name: "A", peripheralIdentifier: "p1", family: .genericBLEStandard))
        let second = StubSession(device: Device(name: "B", peripheralIdentifier: "p2", family: .genericBLEStandard))

        manager.session(first, didReceive: HeartRateMeasurement(beatsPerMinute: 60))
        manager.session(second, didReceive: HeartRateMeasurement(beatsPerMinute: 70))

        XCTAssertEqual(repository.savedHeartRates.count, 2, "One device's reading must not suppress another's")
    }

    /// Tapping Disconnect has to stop the automatic reconnection too, or the
    /// link comes straight back.
    func testDisconnectingTellsTheConnectorToStopRetrying() {
        let repository = CountingRepository()
        let connector = StubConnector()
        let manager = makeManager(repository: repository, connector: connector)

        let peripheral = DiscoveredPeripheral(id: "p1", name: "Strap", rssi: -50, advertisedServiceUUIDs: [])
        let coordinator = GenericBLECoordinator()
        let device = manager.pair(peripheral, as: coordinator)

        manager.disconnect(device)

        XCTAssertEqual(connector.disconnectedIds, ["p1"])
    }

    func testManagerRegistersItselfForConnectionEvents() {
        let connector = StubConnector()
        let manager = makeManager(repository: CountingRepository(), connector: connector)
        XCTAssertTrue(connector.connectionObserver === manager)
    }
}
