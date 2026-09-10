import Foundation

/// A family of wearable devices sharing a communication protocol.
///
/// Gadgetbridge (Android) supports each family through vendor-specific,
/// often reverse-engineered protocols. `genericBLEStandard` and `amazfit`
/// have working `DeviceCoordinator`s today (see
/// `Coordinators/GenericBLE` and `Coordinators/AmazfitHelio`); the rest are
/// placeholders for future vendor-specific work. `amazfit`'s coordinator
/// targets the Zepp OS / Huami protocol family, written for the Amazfit
/// Helio Strap specifically — it has *not* been tested against real
/// hardware (see `AmazfitHelioSession`'s documentation), and other
/// Amazfit/Mi Band generations using older Huami protocol versions are not
/// expected to match.
public enum DeviceFamily: String, CaseIterable, Codable, Sendable {
    case genericBLEStandard
    case miBand
    case amazfit
    case pebble
    case fitPro

    public var isImplemented: Bool {
        switch self {
        case .genericBLEStandard, .amazfit: return true
        case .miBand, .pebble, .fitPro: return false
        }
    }
}
