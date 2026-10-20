import Foundation
import NarwalKit
import Observation

/// A saved one-tap clean: rooms in order plus settings. Stored on the phone,
/// so it can't be silently overwritten by the robot's own plan.
struct CleanPreset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    /// Empty means the whole house.
    var rooms: [Int]
    var settings: CleanSettings
    var perRoom: [Int: CleanSettings] = [:]
    /// Set for zone routines. Optional so older saved routines still decode.
    var zones: [Payloads.Zone]?
}

@MainActor
@Observable
final class PresetStore {
    private(set) var presets: [CleanPreset] = []

    private static let key = "cleanPresets"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([CleanPreset].self, from: data) {
            presets = saved
        }
    }

    func save(_ preset: CleanPreset) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        persist()
    }

    func delete(at offsets: IndexSet) {
        presets.remove(atOffsets: offsets)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
