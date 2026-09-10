import Foundation

public struct BatteryInfo: Codable, Hashable, Sendable {
    /// 0...100
    public var level: Int
    public var isCharging: Bool
    public var updatedAt: Date

    public init(level: Int, isCharging: Bool = false, updatedAt: Date = Date()) {
        self.level = max(0, min(100, level))
        self.isCharging = isCharging
        self.updatedAt = updatedAt
    }
}
