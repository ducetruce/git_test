import SwiftUI

/// One pass over everything that hasn't been tried on the real robot, with
/// a shareable report. Results stay on the phone between visits.
struct ChecklistView: View {
    @Environment(RobotStore.self) private var store
    @State private var results: [String: String] = ChecklistView.load()

    struct Item: Identifiable {
        let id: String
        let title: String
        let how: String
    }

    static let sections: [(String, [Item])] = [
        ("Status", [
            Item(id: "status", title: "Home shows the right state",
                 how: "Docked, charging, cleaning, returning: compare with the Narwal app."),
            Item(id: "relocalize", title: "\"Finding its position\"",
                 how: "Shown while the robot relocates itself, not \"Charging\"."),
            Item(id: "activity", title: "Station activities",
                 how: "Washing mops, drying, emptying the dustbin show by name."),
        ]),
        ("Settings", [
            Item(id: "settings", title: "Three different settings",
                 how: "Change one switch, one choice and quiet hours. Check each in the Narwal app."),
        ]),
        ("Carpets (Map)", [
            Item(id: "carpet-option", title: "One carpet's handling",
                 how: "Layers > Carpets…: set one carpet to Avoid. Check the same carpet in the Narwal app."),
            Item(id: "carpet-add", title: "Add a carpet",
                 how: "Edit > Add carpet: drag over a rug the robot missed."),
            Item(id: "carpet-not", title: "Not a carpet",
                 how: "Edit > Not a carpet: drag over a spot wrongly marked as carpet."),
            Item(id: "carpet-room", title: "Whole room is carpet",
                 how: "Edit > Select: tap a carpet > Whole room is carpet."),
            Item(id: "carpet-delete", title: "Delete a carpet",
                 how: "Edit > Select: tap a carpet > Delete. (Add it back afterwards if you need it.)"),
        ]),
        ("Map", [
            Item(id: "nogo-add", title: "Add a no-go zone", how: "Edit > No-go zone: drag a rectangle."),
            Item(id: "nogo-delete", title: "Delete it", how: "Edit > Select: tap the zone > Delete."),
            Item(id: "wall-add", title: "Add a virtual wall", how: "Edit > Virtual wall: drag a line."),
            Item(id: "wall-delete", title: "Delete it", how: "Edit > Select: tap the wall > Delete."),
            Item(id: "room-rename", title: "Rename a room", how: "Edit > Select: tap a room > Rename."),
            Item(id: "room-split", title: "Split a room",
                 how: "Edit > Split room: drag a line across a room. Then merge it back (next item)."),
            Item(id: "room-merge", title: "Merge two rooms", how: "Edit > Select: tap a room > Merge with…"),
            Item(id: "furniture", title: "Change a furniture type",
                 how: "Edit > Select: tap furniture > Change type. Check the Narwal app's 3D map."),
        ]),
        ("Schedules (Home)", [
            Item(id: "schedule-list", title: "Schedules load",
                 how: "Any schedules made in the Narwal app appear, with the right time and days."),
            Item(id: "schedule-add", title: "Add a schedule",
                 how: "Add one for a few minutes from now. Check it in the Narwal app, and that it runs."),
            Item(id: "schedule-toggle", title: "Turn it off and on", how: "Use its switch; check the Narwal app."),
            Item(id: "schedule-delete", title: "Delete it", how: "Swipe left on it."),
        ]),
        ("Everyday use", [
            Item(id: "resolved", title: "Mark resolved",
                 how: "Next \"can't find the base station\" alert: tap Mark resolved. Does the robot find it?"),
            Item(id: "connect", title: "Connects without the Narwal app",
                 how: "Close both apps, wait an hour, open only this one."),
            Item(id: "crash", title: "No crashes", how: "Settings > Diagnostics > Crash reports stays empty."),
        ]),
    ]

    var body: some View {
        List {
            Section {
                Text("Turn on Settings > Change robot settings first. Every change can be undone in the Narwal app. Mark each item, then share the report.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Self.sections.indices, id: \.self) { index in
                Section(Self.sections[index].0) {
                    ForEach(Self.sections[index].1) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title).font(.body.weight(.semibold))
                            Text(item.how).font(.footnote).foregroundStyle(.secondary)
                            Picker("Result", selection: binding(item.id)) {
                                Text("Not tried").tag("")
                                Text("Works").tag("pass")
                                Text("Doesn't").tag("fail")
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Section {
                Button("Clear all results", role: .destructive) {
                    results = [:]
                    Self.save(results)
                }
            }
        }
        .navigationTitle("Test checklist")
        .toolbar {
            ShareLink(item: report()) { Image(systemName: "square.and.arrow.up") }
        }
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { results[id] ?? "" }, set: { results[id] = $0; Self.save(results) })
    }

    private func report() -> String {
        var lines = ["Narwal Local test report"]
        for (title, items) in Self.sections {
            lines.append("")
            lines.append("## \(title)")
            for item in items {
                let result = ["pass": "WORKS", "fail": "DOESN'T"][results[item.id] ?? ""] ?? "not tried"
                lines.append("- \(item.title): \(result)")
            }
        }
        lines.append("")
        lines.append("## Last log lines")
        lines += store.log.suffix(60)
        return lines.joined(separator: "\n")
    }

    private static let key = "checklistResults"

    static func load() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func save(_ results: [String: String]) {
        UserDefaults.standard.set(results, forKey: key)
    }
}
