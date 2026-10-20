import Foundation

/// Breaks crash loops: if the previous launch died within its first seconds,
/// the app starts without auto-connecting so it can still be opened.
enum LaunchGuard {
    private static let key = "launchInProgress"

    /// Call once at launch. Returns true if the previous launch crashed early.
    static func begin() -> Bool {
        let crashed = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { markStable() }
        return crashed
    }

    /// The launch survived (or the app was backgrounded on purpose).
    static func markStable() {
        UserDefaults.standard.set(false, forKey: key)
    }
}
