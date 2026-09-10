import SwiftUI
import GadgetbridgeCore

@main
struct GadgetbridgeApp: App {
    @StateObject private var deviceListViewModel: DeviceListViewModel
    @StateObject private var settings = UserSettings()
    private let repository: ActivityRepository

    init() {
        DeviceCoordinatorRegistry.shared.register(GenericBLECoordinator())
        DeviceCoordinatorRegistry.shared.register(AmazfitHelioCoordinator())

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
            RootView(
                deviceList: deviceListViewModel,
                settings: settings,
                repository: repository
            )
            // Re-link devices that were connected when the app last stopped,
            // so collection resumes without the user opening the app and
            // tapping anything.
            .task { await deviceListViewModel.reconnectKnownDevices() }
        }
    }
}
