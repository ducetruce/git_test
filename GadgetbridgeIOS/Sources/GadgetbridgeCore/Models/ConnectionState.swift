import Foundation

public enum ConnectionState: String, Codable, Sendable {
    case disconnected
    case connecting
    case connected
    case syncing
}
