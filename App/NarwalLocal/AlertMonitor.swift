import Foundation
import NarwalKit
import Observation
import UserNotifications

/// Turns status updates into alerts.
///
/// Fixes the Narwal app's phantom and repeated alerts:
/// - a condition must appear in two consecutive status reports (~3 s) before
///   it alerts, so one-frame glitches never notify;
/// - each condition notifies once, and again only after it has cleared;
/// - missing fields are "unknown", never "fine" or "problem".
@MainActor
@Observable
final class AlertMonitor {
    struct Alert: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
    }

    private(set) var active: [Alert] = []

    @ObservationIgnored private var pending: Set<String> = []
    /// Conditions already notified; persisted so relaunching doesn't re-alert.
    @ObservationIgnored private var notified = Set(UserDefaults.standard.stringArray(forKey: "notifiedAlerts") ?? [])
    @ObservationIgnored private var cleanStartedAt: Date?

    private func saveNotified() {
        UserDefaults.standard.set(Array(notified), forKey: "notifiedAlerts")
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func statusChanged(_ status: BaseStatus, previousWasCleaning: Bool, roomName: String?) {
        var current: [Alert] = status.errors.map {
            Alert(id: "error-\($0.code)", title: RobotErrorText.message(for: $0.code),
                  detail: $0.detail.isEmpty ? "Code \($0.code)" : "Code \($0.code): \($0.detail)")
        }
        current += status.station.problems.map { Alert(id: "station-\($0)", title: $0, detail: "") }

        let ids = Set(current.map(\.id))
        let confirmed = ids.intersection(pending)
        pending = ids
        active = current.filter { confirmed.contains($0.id) }

        for alert in active where !notified.contains(alert.id) {
            notify(alert.title, alert.detail)
            notified.insert(alert.id)
        }
        // Forget cleared conditions so they can alert again next time.
        notified = notified.filter { !$0.hasPrefix("error-") && !$0.hasPrefix("station-") || ids.contains($0) }
        saveNotified()

        let cleaning = status.workingStatus.isActiveCleaning
        if cleaning, !previousWasCleaning {
            cleanStartedAt = Date()
        }
        if previousWasCleaning, !cleaning, !status.isPaused {
            let finished = status.workingStatus == .taskCompleted || status.isReturning
                || status.workingStatus.isOnDock
            if finished, cleanStartedAt != nil {
                notify("Cleaning finished", status.errors.isEmpty ? "Heading back to the dock." : "Ended with an error.")
            }
            cleanStartedAt = nil
        }
    }

    func consumablesChanged(_ alerts: ConsumableAlerts) {
        let current = Set(alerts.maintain.map { "maintain-\($0)" } + alerts.replace.map { "replace-\($0)" })
        let fresh = current.subtracting(notified)
        if !fresh.isEmpty {
            let names = alerts.maintain.filter { fresh.contains("maintain-\($0)") }
                .map { ConsumableAlerts.maintainNames[$0] ?? "Part \($0)" }
                + alerts.replace.filter { fresh.contains("replace-\($0)") }
                .map { ConsumableAlerts.replaceNames[$0] ?? "Part \($0)" }
            notify("Maintenance due", names.joined(separator: ", "))
        }
        notified = notified.filter { !($0.hasPrefix("maintain-") || $0.hasPrefix("replace-")) || current.contains($0) }
            .union(current)
        saveNotified()
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
