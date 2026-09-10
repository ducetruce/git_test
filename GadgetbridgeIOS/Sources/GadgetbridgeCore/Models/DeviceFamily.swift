import Foundation

/// A family of wearable devices sharing a communication protocol.
///
/// Gadgetbridge (Android) supports each family through vendor-specific,
/// often reverse-engineered protocols. On iOS, `CoreBluetooth` cannot access
/// raw HCI/L2CAP data the way Android's Bluetooth stack can, so only
/// families that expose standard Bluetooth SIG GATT profiles (or that ship
/// public protocol documentation) can be supported without an accompanying
/// jailbreak or MFi program. `genericBLEStandard` is the only family with a
/// working `DeviceCoordinator` today; the rest are placeholders for future
/// vendor-specific work.
public enum DeviceFamily: String, CaseIterable, Codable, Sendable {
    case genericBLEStandard
    case miBand
    case amazfit
    case pebble
    case fitPro

    public var isImplemented: Bool {
        switch self {
        case .genericBLEStandard: return true
        case .miBand, .amazfit, .pebble, .fitPro: return false
        }
    }
}
