import Foundation
import NarwalKit

/// Cleans this app has watched finish, kept on the phone: the robot's own
/// history has dates and rooms but no area or duration. Feeds "cleaned this
/// week" and the parts' hours.
struct CleaningLedger: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var start: Date
        var end: Date
        var squareMeters: Double
        var seconds: Int
    }

    private(set) var entries: [Entry] = []

    private static let key = "cleaningLedger"

    static func load() -> CleaningLedger {
        guard let data = UserDefaults.standard.data(forKey: key),
              let ledger = try? JSONDecoder().decode(CleaningLedger.self, from: data) else { return CleaningLedger() }
        return ledger
    }

    mutating func add(_ entry: Entry) {
        guard entry.squareMeters > 0 || entry.seconds > 60 else { return }
        entries.append(entry)
        // A year is plenty for parts and weekly totals.
        let cutoff = Date().addingTimeInterval(-366 * 86_400)
        entries.removeAll { $0.end < cutoff }
        save()
    }

    /// If a clean that just started reports at least as much area as the
    /// one that ended under two hours ago, it's that clean continuing (after
    /// a mop wash or a recharge): take it back out to keep counting.
    mutating func reopen(ifContinuedWith squareMeters: Double, now: Date = Date()) -> Entry? {
        guard let last = entries.last, squareMeters > 0, squareMeters >= last.squareMeters * 0.9,
              now.timeIntervalSince(last.end) < 2 * 3600 else { return nil }
        entries.removeLast()
        save()
        return last
    }

    private func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// Area cleaned in the last 7 days.
    func squareMetersThisWeek(now: Date = Date()) -> Double {
        let since = now.addingTimeInterval(-7 * 86_400)
        return entries.filter { $0.end >= since }.reduce(0) { $0 + $1.squareMeters }
    }

    /// Typical clean length from what the app has seen, for cleans it
    /// missed. 40 minutes until it has seen a few.
    var typicalSeconds: Int {
        let seen = entries.map(\.seconds).filter { $0 > 60 }.sorted()
        guard seen.count >= 3 else { return 40 * 60 }
        return seen[seen.count / 2]
    }

    /// Cleaning hours since `date`: cleans the app watched, plus cleans in
    /// the robot's history it didn't watch, at the typical length.
    func hours(since date: Date, history: CleaningHistory?) -> Double {
        let watched = entries.filter { $0.end > date }
        var seconds = watched.reduce(0) { $0 + $1.seconds }
        let missed = (history?.events ?? []).filter { event in
            guard event.isPrimary, event.task == 4, let start = event.date, start > date else { return false }
            return !watched.contains { abs($0.start.timeIntervalSince(start)) < 15 * 60 }
        }
        seconds += missed.count * typicalSeconds
        return Double(seconds) / 3600
    }
}

/// Hours left on wearing parts. The robot only says when a part needs
/// attention; the Narwal app's hour counts come from Narwal's servers. So
/// each part counts down from a starting point the owner gives: "Replaced"
/// (its full life), or the hours the Narwal app shows today.
struct PartLife: Identifiable, Equatable {
    let id: String
    let name: String
    /// ConsumableReplaceItem, for telling the robot it was replaced.
    let item: Int
    /// Narwal's rated life, estimated from its app's countdowns.
    let ratedHours: Double

    static let all: [PartLife] = [
        PartLife(id: "mop", name: "Silver Ion Mop", item: 2, ratedHours: 150),
        PartLife(id: "sideBrush", name: "Anti-tangle side brush", item: 3, ratedHours: 150),
        PartLife(id: "mainBrush", name: "Zero-tangling floating brush", item: 5, ratedHours: 300),
        PartLife(id: "filter", name: "Dust Bin Filter", item: 1, ratedHours: 150),
        PartLife(id: "insertBin", name: "Replaceable insert bin", item: 24, ratedHours: 2_150),
    ]

    struct Start: Codable, Equatable {
        var date: Date
        var hoursLeft: Double
    }

    private static func key(_ id: String) -> String { "partLife.\(id)" }

    var start: Start? {
        guard let data = UserDefaults.standard.data(forKey: Self.key(id)) else { return nil }
        return try? JSONDecoder().decode(Start.self, from: data)
    }

    func setStart(hoursLeft: Double, date: Date = Date()) {
        let start = Start(date: date, hoursLeft: max(0, hoursLeft))
        if let data = try? JSONEncoder().encode(start) { UserDefaults.standard.set(data, forKey: Self.key(id)) }
    }

    func hoursLeft(_ ledger: CleaningLedger, _ history: CleaningHistory?) -> Double? {
        guard let start else { return nil }
        return max(0, start.hoursLeft - ledger.hours(since: start.date, history: history))
    }
}
