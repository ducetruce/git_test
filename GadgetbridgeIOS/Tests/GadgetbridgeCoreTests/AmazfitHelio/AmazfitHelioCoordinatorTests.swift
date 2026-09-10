import XCTest
@testable import GadgetbridgeCore

final class AmazfitHelioCoordinatorTests: XCTestCase {
    func testRecognizesDeviceByHuamiServiceUUID() {
        let coordinator = AmazfitHelioCoordinator()
        let peripheral = DiscoveredPeripheral(id: "1", name: "Amazfit Helio Strap", rssi: -40, advertisedServiceUUIDs: [HuamiGATT.service])
        XCTAssertTrue(coordinator.canSupport(peripheral))
    }

    func testRecognizesDeviceByNameFallback() {
        let coordinator = AmazfitHelioCoordinator()
        let peripheral = DiscoveredPeripheral(id: "2", name: "Helio Strap 1234", rssi: -40, advertisedServiceUUIDs: [])
        XCTAssertTrue(coordinator.canSupport(peripheral))
    }

    func testDoesNotRecognizeUnrelatedDevice() {
        let coordinator = AmazfitHelioCoordinator()
        let peripheral = DiscoveredPeripheral(id: "3", name: "Random Speaker", rssi: -40, advertisedServiceUUIDs: [StandardBLEService.heartRate])
        XCTAssertFalse(coordinator.canSupport(peripheral))
    }

    func testRequiresPairingSecret() {
        XCTAssertTrue(AmazfitHelioCoordinator().requiresPairingSecret)
    }

    func testSessionStartFailsWithoutAValidAuthKey() async {
        let device = Device(name: "Helio", peripheralIdentifier: "id", family: .amazfit, pairingSecretHex: nil)
        let session = AmazfitHelioSession(device: device, authKey: nil)

        final class NoopTransport: DeviceTransport {
            func readValue(service: ServiceUUID, characteristic: ServiceUUID) async throws -> Data { Data() }
            func writeValue(_ data: Data, service: ServiceUUID, characteristic: ServiceUUID, withResponse: Bool) async throws {}
            func subscribe(service: ServiceUUID, characteristic: ServiceUUID, onUpdate: @escaping (Data) -> Void) throws {}
            func unsubscribe(service: ServiceUUID, characteristic: ServiceUUID) throws {}
            func disconnect() {}
        }
        final class NoopDelegate: DeviceSessionDelegate {
            func session(_ session: DeviceSession, didUpdateBattery battery: BatteryInfo) {}
            func session(_ session: DeviceSession, didReceiveHeartRate sample: HeartRateSample) {}
            func session(_ session: DeviceSession, didUpdateDeviceInfo device: Device) {}
        }

        do {
            try await session.start(transport: NoopTransport(), delegate: NoopDelegate())
            XCTFail("Expected start() to throw without a pairing key")
        } catch {
            // Expected.
        }
    }

    func testHuamiAuthKeyParsesValidHex() {
        XCTAssertNotNil(HuamiAuthKey(hexString: "0123456789abcdef0123456789ABCDEF"))
        XCTAssertNil(HuamiAuthKey(hexString: "tooshort"))
        XCTAssertNil(HuamiAuthKey(hexString: String(repeating: "Z", count: 32))) // right length, not valid hex
    }
}
