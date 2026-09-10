import Foundation

/// An outgoing alert the app pushes to a paired device, e.g. via the
/// Bluetooth SIG Alert Notification Profile (service `0x1811`).
///
/// This is intentionally one-directional (phone -> device). Unlike Android,
/// iOS apps cannot read other apps' notifications (there is no
/// `NotificationListenerService` equivalent). Real notification mirroring on
/// iOS is handled by the accessory itself via Apple's ANCS, which the
/// device's firmware speaks directly to iOS — the companion app is not in
/// that path at all. See `README.md` for details.
public struct NotificationAlert: Codable, Hashable, Sendable {
    public enum Category: String, Codable, Sendable {
        case call, message, custom
    }

    public var category: Category
    public var title: String
    public var body: String
    public var timestamp: Date

    public init(category: Category, title: String, body: String, timestamp: Date = Date()) {
        self.category = category
        self.title = title
        self.body = body
        self.timestamp = timestamp
    }
}
