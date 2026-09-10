import Foundation

/// A GATT service or characteristic UUID, kept as a plain string wrapper so
/// `GadgetbridgeCore` has no dependency on `CoreBluetooth` (which only
/// exists on Apple platforms). The App target bridges this to `CBUUID`.
public struct ServiceUUID: Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let uuidString: String

    public init(_ uuidString: String) {
        self.uuidString = uuidString.uppercased()
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String { uuidString }
}

/// Standard Bluetooth SIG GATT services/characteristics. These are public,
/// documented profiles (unlike vendor-specific ones like Mi Band's), so any
/// device implementing them can be supported without reverse engineering.
public enum StandardBLEService {
    public static let deviceInformation: ServiceUUID = "180A"
    public static let battery: ServiceUUID = "180F"
    public static let heartRate: ServiceUUID = "180D"
    public static let currentTime: ServiceUUID = "1805"
    public static let alertNotification: ServiceUUID = "1811"

    public static let all: [ServiceUUID] = [deviceInformation, battery, heartRate, currentTime, alertNotification]
}

public enum StandardBLECharacteristic {
    // Device Information Service (180A)
    public static let manufacturerName: ServiceUUID = "2A29"
    public static let modelNumber: ServiceUUID = "2A24"
    public static let firmwareRevision: ServiceUUID = "2A26"

    // Battery Service (180F)
    public static let batteryLevel: ServiceUUID = "2A19"

    // Heart Rate Service (180D)
    public static let heartRateMeasurement: ServiceUUID = "2A37"

    // Current Time Service (1805)
    public static let currentTime: ServiceUUID = "2A2B"

    // Alert Notification Service (1811) - phone-to-accessory alerts
    public static let newAlert: ServiceUUID = "2A46"
    public static let supportedNewAlertCategory: ServiceUUID = "2A47"
}
