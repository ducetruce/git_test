import NarwalKit
import SwiftUI

/// Recent cleaning events from info/get_clean_time_line (read-only).
struct HistoryView: View {
    @Environment(RobotStore.self) private var store

    var body: some View {
        List {
            if let history = store.history {
                if history.events.isEmpty {
                    Text("No recent cleaning events.").foregroundStyle(.secondary)
                }
                ForEach(Array(history.events.reversed().enumerated()), id: \.offset) { _, event in
                    EventRow(event: event, roomName: roomName(event.zoneId))
                }
            } else {
                Text("Not loaded yet.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Cleaning history")
        .refreshable { await store.reloadHistory() }
        .task { if store.history == nil { await store.reloadHistory() } }
    }

    private func roomName(_ id: Int?) -> String? {
        guard let id else { return nil }
        return store.map?.rooms.first { $0.id == id }?.displayName
    }
}

private struct EventRow: View {
    let event: CleaningEvent
    let roomName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.taskLabel).font(event.isPrimary ? .body.weight(.semibold) : .body)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                if let date = event.date {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                } else if event.rawTime != 0 {
                    // The robot's time unit isn't known yet; show what it sent.
                    Text("Time code \(event.rawTime)")
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if let roomName { parts.append(roomName) }
        if let result = event.resultLabel { parts.append(result) }
        if let code = event.errorCode { parts.append(RobotErrorText.message(for: code)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var icon: String {
        if event.errorCode != nil { return "exclamationmark.triangle.fill" }
        if event.succeeded { return "checkmark.circle.fill" }
        if event.result != nil && event.result != 0 { return "stop.circle" }
        return "circle.fill"
    }

    private var color: Color {
        if event.errorCode != nil { return .orange }
        if event.succeeded { return .green }
        return .secondary
    }
}
