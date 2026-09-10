import SwiftUI
import GadgetbridgeCore

@main
struct GadgetbridgeApp: App {
    @StateObject private var deviceListViewModel: DeviceListViewModel
    private let repository: ActivityRepository

    init() {
        DeviceCoordinatorRegistry.shared.register(GenericBLECoordinator())

        let supportDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gadgetbridge", isDirectory: true)

        let repository: ActivityRepository
        if let jsonRepository = try? JSONFileActivityRepository(directory: supportDirectory) {
            repository = jsonRepository
        } else {
            repository = InMemoryActivityRepository()
        }
        self.repository = repository

        let deviceStore: DeviceStore
        if let jsonStore = try? JSONFileDeviceStore(directory: supportDirectory) {
            deviceStore = jsonStore
        } else {
            deviceStore = InMemoryDeviceStore()
        }

        let bluetoothCenter = BluetoothCenter()
        let manager = DeviceManager(
            scanner: bluetoothCenter,
            connector: bluetoothCenter,
            repository: repository,
            deviceStore: deviceStore
        )
        _deviceListViewModel = StateObject(wrappedValue: DeviceListViewModel(manager: manager))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(deviceListViewModel: deviceListViewModel, repository: repository)
        }
    }
}
