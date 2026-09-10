import Foundation
import GadgetbridgeCore

/// User-supplied values the app can't measure for itself.
///
/// Heart rate zones are the reason this exists: they're fractions of a
/// maximum heart rate, and nothing on a wrist strap can tell you what yours
/// is. Without a value here the zone model in `GadgetbridgeCore` is
/// unreachable code.
///
/// Lives in the app target rather than Core so Core stays free of Combine
/// and `UserDefaults`.
@MainActor
final class UserSettings: ObservableObject {
    private enum Key {
        static let maximumHeartRate = "gadgetbridge.maximumHeartRate"
        static let retentionDays = "gadgetbridge.retentionDays"
    }

    private let defaults: UserDefaults

    /// Nil means "not set" — zones stay hidden rather than being derived
    /// from a guess the user never made.
    @Published var maximumHeartRate: Int? {
        didSet { defaults.set(maximumHeartRate ?? 0, forKey: Key.maximumHeartRate) }
    }

    @Published var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Key.retentionDays) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedMaximum = defaults.integer(forKey: Key.maximumHeartRate)
        maximumHeartRate = storedMaximum > 0 ? storedMaximum : nil
        let storedRetention = defaults.integer(forKey: Key.retentionDays)
        retentionDays = storedRetention > 0 ? storedRetention : 30
    }

    var retention: TimeInterval { TimeInterval(retentionDays) * 24 * 3600 }

    /// The usual population estimate, offered as a starting point the user
    /// can overwrite — not presented as a measurement.
    func applyAgeBasedEstimate(age: Int) {
        maximumHeartRate = HeartRateZone.estimatedMaximum(forAge: age)
    }
}
