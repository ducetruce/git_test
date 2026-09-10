#if canImport(HealthKit)
import Foundation
import HealthKit
import GadgetbridgeCore

/// Writes readings collected from a device into Apple Health.
///
/// This is the one place the app's local-only stance is deliberately
/// relaxed, and only on the user's explicit authorization: data goes into
/// *their* health record on *their* device, not to a vendor cloud. Export is
/// one-directional — this never reads from HealthKit.
@MainActor
final class HealthKitExporter: ObservableObject {
    @Published private(set) var isAuthorized = false
    @Published private(set) var lastError: String?

    private let store = HKHealthStore()

    private var writableTypes: Set<HKSampleType> {
        var types = Set<HKSampleType>()
        if let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            types.insert(heartRate)
        }
        if let hrv = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) {
            types.insert(hrv)
        }
        return types
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async {
        guard isAvailable else {
            lastError = "Health data isn't available on this device."
            return
        }
        do {
            try await store.requestAuthorization(toShare: writableTypes, read: [])
            isAuthorized = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func export(heartRate samples: [HeartRateSample], deviceName: String) async {
        guard isAvailable, let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())

        let hkSamples = samples.map { sample in
            HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: unit, doubleValue: Double(sample.beatsPerMinute)),
                start: sample.timestamp,
                end: sample.timestamp,
                metadata: [HKMetadataKeyExternalUUID: sample.deviceId.uuidString]
            )
        }
        await save(hkSamples)
    }

    /// HealthKit's HRV type is specifically SDNN, so that's the figure
    /// exported — RMSSD stays local rather than being filed under a label
    /// that would misrepresent it.
    func export(hrv samples: [HRVSample]) async {
        guard isAvailable,
              let type = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return }

        let hkSamples = samples.map { sample in
            HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: sample.sdnnMilliseconds),
                start: sample.timestamp,
                end: sample.timestamp,
                metadata: [HKMetadataKeyExternalUUID: sample.deviceId.uuidString]
            )
        }
        await save(hkSamples)
    }

    private func save(_ samples: [HKSample]) async {
        guard !samples.isEmpty else { return }
        do {
            try await store.save(samples)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
#endif
