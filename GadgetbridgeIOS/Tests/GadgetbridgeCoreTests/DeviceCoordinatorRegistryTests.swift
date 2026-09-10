import XCTest
@testable import GadgetbridgeCore

final class DeviceCoordinatorRegistryTests: XCTestCase {
    func testGenericBLECoordinatorMatchesHeartRatePeripheral() {
        let registry = DeviceCoordinatorRegistry()
        registry.register(GenericBLECoordinator())

        let peripheral = DiscoveredPeripheral(
            id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            name: "HRM-Dual",
            rssi: -50,
            advertisedServiceUUIDs: [StandardBLEService.heartRate]
        )

        XCTAssertNotNil(registry.coordinator(for: peripheral))
        XCTAssertEqual(registry.coordinator(for: peripheral)?.family, .genericBLEStandard)
    }

    func testUnknownPeripheralHasNoCoordinator() {
        let registry = DeviceCoordinatorRegistry()
        registry.register(GenericBLECoordinator())

        let peripheral = DiscoveredPeripheral(
            id: "11111111-2222-3333-4444-555555555555",
            name: "Mystery Band",
            rssi: -70,
            advertisedServiceUUIDs: [ServiceUUID("FEE0")] // some vendor-specific service
        )

        XCTAssertNil(registry.coordinator(for: peripheral))
    }

    func testRegisteringSameFamilyTwiceReplacesTheCoordinator() {
        let registry = DeviceCoordinatorRegistry()
        registry.register(GenericBLECoordinator())
        registry.register(GenericBLECoordinator())

        XCTAssertEqual(registry.registeredFamilies, [.genericBLEStandard])
    }
}
