import NarwalKit
import SwiftUI

/// Decodes unmapped features from the phone alone: snapshot what the robot
/// reports, change ONE setting in the Narwal app, snapshot again, compare.
struct LabView: View {
    @Environment(RobotStore.self) private var store
    @State private var snapshots: [LabSnapshot] = LabSnapshot.loadAll()
    @State private var running = false
    @State private var customTopic = ""
    @State private var label = ""
    @State private var compareFrom: LabSnapshot.ID?
    @State private var compareTo: LabSnapshot.ID?

    var body: some View {
        List {
            Section {
                Text("""
                1. Tap Take snapshot.
                2. Open the Narwal app and change ONE setting (for example volume 5 → 6). \
                Note what you changed.
                3. Swipe the Narwal app away so it lets go of the robot.
                4. Come back, take another snapshot, and compare the two.
                """)
                .font(.callout)
            } header: {
                Text("How it works")
            } footer: {
                Text("The lab only sends read-only queries; it can't change anything on the robot. Shared snapshots contain your robot's settings but no passwords.")
            }

            Section("Snapshot") {
                TextField("Label, e.g. \"volume 6\"", text: $label)
                Button {
                    Task { await snapshot() }
                } label: {
                    HStack {
                        Text(running ? "Reading…" : "Take snapshot")
                        if running { Spacer(); ProgressView() }
                    }
                }
                .disabled(running || store.connectionState == .disconnected)
                HStack {
                    TextField("Extra topic, e.g. config/get", text: $customTopic)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text(Research.isSafeQuery(customTopic) || customTopic.isEmpty ? "" : "not a query")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            if snapshots.count >= 2 {
                Section("Compare") {
                    Picker("Before", selection: $compareFrom) {
                        Text("–").tag(LabSnapshot.ID?.none)
                        ForEach(snapshots) { Text($0.title).tag(Optional($0.id)) }
                    }
                    Picker("After", selection: $compareTo) {
                        Text("–").tag(LabSnapshot.ID?.none)
                        ForEach(snapshots) { Text($0.title).tag(Optional($0.id)) }
                    }
                    if let before = snapshots.first(where: { $0.id == compareFrom }),
                       let after = snapshots.first(where: { $0.id == compareTo }) {
                        NavigationLink("Show differences") { LabDiffView(before: before, after: after) }
                    }
                }
            }

            Section("Snapshots") {
                if snapshots.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                ForEach(snapshots) { snap in
                    NavigationLink {
                        LabSnapshotView(snapshot: snap)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(snap.title)
                            Text("\(snap.results.filter { !$0.leaves.isEmpty }.count) of \(snap.results.count) topics answered")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    snapshots.remove(atOffsets: offsets)
                    LabSnapshot.saveAll(snapshots)
                }
            }
        }
        .navigationTitle("Feature lab")
    }

    private func snapshot() async {
        running = true
        defer { running = false }
        var topics = Research.probeTopics
        let extra = customTopic.trimmingCharacters(in: .whitespaces)
        if !extra.isEmpty, !topics.contains(extra) { topics.append(extra) }
        var results: [RobotStore.ProbeResult] = []
        for topic in topics {
            results.append(await store.probe(topic))
        }
        let snap = LabSnapshot(label: label, firmware: store.deviceInfo?.firmware ?? "", results: results)
        snapshots.insert(snap, at: 0)
        LabSnapshot.saveAll(snapshots)
        // Default to comparing the two newest.
        compareTo = snap.id
        compareFrom = snapshots.count > 1 ? snapshots[1].id : nil
        label = ""
    }
}

struct LabSnapshot: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var label: String
    var firmware: String
    var results: [RobotStore.ProbeResult]

    var title: String {
        let time = date.formatted(date: .abbreviated, time: .shortened)
        return label.isEmpty ? time : "\(label) · \(time)"
    }

    /// Plain text for sharing, raw paths and values only.
    var exportText: String {
        var lines = ["Narwal lab snapshot: \(title)", "Firmware: \(firmware)", ""]
        for result in results {
            lines.append("## \(result.topic): \(result.outcome)")
            lines += result.leaves.map { "\($0.path) = \($0.value)" }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static var fileURL: URL {
        URL.documentsDirectory.appending(path: "lab-snapshots.json")
    }

    static func loadAll() -> [LabSnapshot] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([LabSnapshot].self, from: data)) ?? []
    }

    static func saveAll(_ snapshots: [LabSnapshot]) {
        if let data = try? JSONEncoder().encode(snapshots) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

private struct LabSnapshotView: View {
    let snapshot: LabSnapshot

    var body: some View {
        List {
            ForEach(snapshot.results) { result in
                Section {
                    ForEach(result.leaves, id: \.path) { leaf in
                        LabeledContent(leaf.path, value: leaf.value)
                            .font(.caption.monospaced())
                    }
                } header: {
                    Text(result.topic)
                } footer: {
                    Text(result.outcome)
                }
            }
        }
        .navigationTitle(snapshot.title)
        .toolbar { ShareLink(item: snapshot.exportText) }
    }
}

private struct LabDiffView: View {
    let before: LabSnapshot
    let after: LabSnapshot

    private struct TopicChanges: Identifiable {
        let topic: String
        let changes: [Research.Change]
        var id: String { topic }
    }

    private var changes: [TopicChanges] {
        after.results.compactMap { result in
            let old = before.results.first { $0.topic == result.topic }?.leaves ?? []
            let diff = Research.diff(old, result.leaves)
            return diff.isEmpty ? nil : TopicChanges(topic: result.topic, changes: diff)
        }
    }

    private var exportText: String {
        var lines = ["Narwal lab diff", "Before: \(before.title)", "After: \(after.title)", ""]
        for group in changes {
            lines.append("## \(group.topic)")
            lines += group.changes.map { "\($0.path): \($0.before ?? "∅") → \($0.after ?? "∅")" }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        List {
            if changes.isEmpty {
                Text("No differences. The setting may live on Narwal's cloud, or under a topic the lab doesn't query yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(changes) { group in
                Section(group.topic) {
                    ForEach(group.changes, id: \.path) { change in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.path).font(.caption.monospaced().weight(.semibold))
                            Text("\(change.before ?? "∅")  →  \(change.after ?? "∅")")
                                .font(.caption.monospaced())
                        }
                    }
                }
            }
        }
        .navigationTitle("Differences")
        .toolbar { ShareLink(item: exportText) }
    }
}
