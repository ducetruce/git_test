import XCTest
@testable import GadgetbridgeCore

private final class CapturingLogger: ProtocolLogging {
    private(set) var lines: [String] = []
    func log(_ message: String) { lines.append(message) }
    var transcript: String { lines.joined(separator: "\n") }
}

/// A strap in heart-rate broadcast mode: it exposes the standard Heart Rate
/// service and nothing vendor-specific, and replays a canned notification
/// once subscribed.
private final class BroadcastTransport: DeviceTransport {
    private let notification: [UInt8]
    private var heartRateCallback: ((Data) -> Void)?
    private(set) var subscribedCharacteristics: [ServiceUUID] = []
    private(set) var writes = 0

    init(notification: [UInt8]) { self.notification = notification }

    /// Deliver the same notification again, as a 1 Hz sensor would.
    func replay() { heartRateCallback?(Data(notification)) }

    func hasCharacteristic(service: ServiceUUID, characteristic: ServiceUUID) -> Bool {
        characteristic == StandardBLECharacteristic.heartRateMeasurement
    }

    func readValue(service: ServiceUUID, characteristic: ServiceUUID) async throws -> Data {
        throw DeviceTransportError.characteristicNotFound(characteristic)
    }

    func writeValue(_ data: Data, service: ServiceUUID, characteristic: ServiceUUID, withResponse: Bool) async throws {
        writes += 1
    }

    func subscribe(service: ServiceUUID, characteristic: ServiceUUID, onUpdate: @escaping (Data) -> Void) throws {
        subscribedCharacteristics.append(characteristic)
        if characteristic == StandardBLECharacteristic.heartRateMeasurement {
            heartRateCallback = onUpdate
            onUpdate(Data(notification))
        }
    }

    func unsubscribe(service: ServiceUUID, characteristic: ServiceUUID) throws {}
    func disconnect() {}
}

private final class RecordingDelegate: DeviceSessionDelegate {
    private(set) var measurements: [HeartRateMeasurement] = []
    func session(_ session: DeviceSession, didUpdateBattery battery: BatteryInfo) {}
    func session(_ session: DeviceSession, didReceive measurement: HeartRateMeasurement) {
        measurements.append(measurement)
    }
    func session(_ session: DeviceSession, didUpdateDeviceInfo device: Device) {}
}

final class BroadcastModeTests: XCTestCase {
    private func device() -> Device {
        Device(name: "Helio Strap", peripheralIdentifier: "id", family: .amazfit)
    }

    /// The point of broadcast mode: it works with no pairing key at all,
    /// which is the one path here that doesn't depend on reconstructed
    /// protocol constants.
    func testBroadcastModeConnectsWithoutAPairingKey() async throws {
        let logger = CapturingLogger()
        let transport = BroadcastTransport(notification: [0x00, 72])
        let delegate = RecordingDelegate()
        let session = AmazfitHelioSession(device: device(), authKey: nil, logger: logger)

        try await session.start(transport: transport, delegate: delegate)

        XCTAssertEqual(delegate.measurements.first?.beatsPerMinute, 72)
        XCTAssertEqual(transport.writes, 0, "Broadcast mode must not attempt the vendor handshake")
        XCTAssertTrue(logger.transcript.contains("broadcast mode"))
    }

    func testBroadcastModeReportsWhenRRIntervalsAreAbsent() async throws {
        let logger = CapturingLogger()
        // flags 0x00: no RR intervals in the payload.
        let transport = BroadcastTransport(notification: [0x00, 64])
        let session = AmazfitHelioSession(device: device(), authKey: nil, logger: logger)

        try await session.start(transport: transport, delegate: RecordingDelegate())

        XCTAssertTrue(
            logger.transcript.contains("no RR intervals"),
            "The log has to say plainly when HRV isn't available from this sensor"
        )
    }

    func testBroadcastModeReportsWhenRRIntervalsArePresent() async throws {
        let logger = CapturingLogger()
        // flags 0x10: RR intervals present. 0x0400 = 1024/1024 = 1.0s.
        let transport = BroadcastTransport(notification: [0x10, 64, 0x00, 0x04])
        let delegate = RecordingDelegate()
        let session = AmazfitHelioSession(device: device(), authKey: nil, logger: logger)

        try await session.start(transport: transport, delegate: delegate)

        XCTAssertEqual(delegate.measurements.first?.rrIntervals.count, 1)
        XCTAssertTrue(logger.transcript.contains("HRV available"))
    }

    /// A 1 Hz sensor would flood the 1000-line transcript in about a
    /// quarter of an hour, so the payload shape is reported once per
    /// connection while readings keep flowing.
    func testMeasurementShapeIsLoggedOnlyOnce() async throws {
        let logger = CapturingLogger()
        let transport = BroadcastTransport(notification: [0x00, 70])
        let delegate = RecordingDelegate()
        let session = AmazfitHelioSession(device: device(), authKey: nil, logger: logger)

        try await session.start(transport: transport, delegate: delegate)
        transport.replay()
        transport.replay()

        XCTAssertEqual(delegate.measurements.count, 3, "All three readings should reach the delegate")
        XCTAssertEqual(
            logger.lines.filter { $0.contains("First heart rate notification") }.count,
            1,
            "…but the payload shape should only be logged once"
        )
    }

    func testMissingHeartRateServiceStillRequiresAKey() async {
        let logger = CapturingLogger()
        // Nothing exposed at all: not broadcasting, so the vendor path applies.
        final class BareTransport: DeviceTransport {
            func hasCharacteristic(service: ServiceUUID, characteristic: ServiceUUID) -> Bool { false }
            func readValue(service: ServiceUUID, characteristic: ServiceUUID) async throws -> Data { Data() }
            func writeValue(_ data: Data, service: ServiceUUID, characteristic: ServiceUUID, withResponse: Bool) async throws {}
            func subscribe(service: ServiceUUID, characteristic: ServiceUUID, onUpdate: @escaping (Data) -> Void) throws {}
            func unsubscribe(service: ServiceUUID, characteristic: ServiceUUID) throws {}
            func disconnect() {}
        }

        let session = AmazfitHelioSession(device: device(), authKey: nil, logger: logger)
        do {
            try await session.start(transport: BareTransport(), delegate: RecordingDelegate())
            XCTFail("Expected the vendor path to demand a pairing key")
        } catch {
            XCTAssertTrue("\(error)".contains("pairing key"))
        }
    }
}
