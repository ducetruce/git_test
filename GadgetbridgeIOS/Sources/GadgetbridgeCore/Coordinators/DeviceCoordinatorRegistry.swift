import Foundation

/// Central lookup from a scan result or a known family to the
/// `DeviceCoordinator` that handles it. New vendor protocols are added by
/// implementing `DeviceCoordinator` and registering an instance here —
/// nothing else in the app needs to change.
public final class DeviceCoordinatorRegistry {
    public static let shared = DeviceCoordinatorRegistry()

    private var coordinators: [DeviceCoordinator] = []

    public init() {}

    public func register(_ coordinator: DeviceCoordinator) {
        coordinators.removeAll { $0.family == coordinator.family }
        coordinators.append(coordinator)
    }

    public func coordinator(for peripheral: DiscoveredPeripheral) -> DeviceCoordinator? {
        coordinators.first { $0.canSupport(peripheral) }
    }

    public func coordinator(for family: DeviceFamily) -> DeviceCoordinator? {
        coordinators.first { $0.family == family }
    }

    public var registeredFamilies: [DeviceFamily] {
        coordinators.map(\.family)
    }
}
