import NarwalKit
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
        ("Look", [
            Item(id: "model", title: "3D robot and station",
                 how: "Today and Station: does the model look like your robot? Drag to turn it."),
            Item(id: "screens", title: "New screens",
                 how: "Today, Clean, Station and More: anything cramped, cut off or hard to read?"),
            Item(id: "area", title: "Cleaned this week",
                 how: "Today's middle ring: after a clean, does the area roughly match the Narwal app's report?"),
            Item(id: "map3d", title: "3D map",
                 how: "Clean tab in 3D: walls, furniture and the robot in the right places?"),
            Item(id: "obstacles", title: "Obstacle photos", how: "More > Obstacle photos: tap one."),
        ]),
        ("Status", [
            Item(id: "status", title: "Today shows the right state",
                 how: "Docked, charging, cleaning, returning, \"Finding its position\": compare with the Narwal app."),
            Item(id: "activity", title: "Dock activities",
                 how: "Washing mops, drying, emptying, drying the dust bag show by name."),
            Item(id: "cartridges", title: "Cartridges",
                 how: "Station > Cartridges: Detergent and the Wood Floor Maintenance Solution show, and the stain remover isn't listed as missing."),
            Item(id: "drying", title: "Drying time left",
                 how: "While the mops dry, the Station screen shows minutes left."),
        ]),
        ("Freo Mind and cleaning", [
            Item(id: "freo-clean", title: "Clean with Freo Mind",
                 how: "Clean tab: pick a room > Freo Mind on > Start. Does the Narwal app show it as a Freo Mind clean?"),
            Item(id: "freo-settings", title: "Freo Mind Mode settings",
                 how: "More > Freo Mind Mode: change Re-mopping Cycle Limit and Coverage Precision. Check the Narwal app."),
            Item(id: "order", title: "House Cleaning Order",
                 how: "More > Map management > Cleaning order: move a room, Save. Check the Narwal app's order."),
            Item(id: "resume", title: "Resume an interrupted clean",
                 how: "If a clean stops early, Today offers Continue."),
        ]),
        ("Wood floor care", [
            Item(id: "floor-material", title: "Floor material",
                 how: "Clean > Edit > Select: tap a room > Floor material > Wood Floor. Check the Narwal app's Floor material."),
            Item(id: "maintain", title: "Floor maintenance",
                 how: "Clean tab > ✨ button: pick wood rooms, Start. Try once with \"Cleaning before maintenance\" off."),
            Item(id: "maintain-after", title: "Maintain after a clean",
                 how: "Start a clean with \"Maintain wood floors afterwards\" on."),
        ]),
        ("Settings", [
            Item(id: "floor-cleaning", title: "Floor Cleaning",
                 how: "Rewash Strategy, Intensive Corner Cleaning, granular debris: each matches the Narwal app before and after changing it."),
            Item(id: "dock", title: "Dock",
                 how: "Auto-empty Frequency and Level, Default Cleaning Mode, hot water, detergent: compare with the Narwal app."),
            Item(id: "general", title: "General",
                 how: "Do Not Disturb, Plateau Mode, Child Lock, Auto Power-Off."),
            Item(id: "carpet", title: "Newly detected carpets", how: "Clean / Avoid / Cross / Vacuum & Mop matches the Narwal app."),
            Item(id: "voice", title: "Navo Voice Assistant", how: "Assistant switch, language shown correctly, volume."),
            Item(id: "ai", title: "Obstacle Avoidance Strategy", how: "Smart / Safety matches."),
            Item(id: "drain", title: "Dock Base Drainage", how: "Station > Dock Base Drainage: does the dock drain?"),
        ]),
        ("Map", [
            Item(id: "carpet-option", title: "One carpet's handling",
                 how: "Clean tab, 2D, Layers > Carpets…: set one carpet to Avoid. Check the Narwal app."),
            Item(id: "carpet-edit", title: "Add / not a carpet / delete",
                 how: "Edit tools Add carpet and Not a carpet, then delete what you added."),
            Item(id: "nogo", title: "No-go zone and virtual wall", how: "Add each, then delete them."),
            Item(id: "rooms", title: "Rename, split, merge", how: "Rename a room; split one, then merge it back."),
            Item(id: "character", title: "Room character and type",
                 how: "Tap a room > Room character, and Room type. Check the Narwal app."),
            Item(id: "furniture", title: "Change a furniture type", how: "Edit > Select: tap furniture > Change type."),
            Item(id: "maps", title: "Map management",
                 how: "More > Map management: the Main Map is listed, No stairs matches the Narwal app. (Don't remap unless you want to.)"),
            Item(id: "rotate", title: "Rotate map", how: "Map management > Rotate map 90°. Rotate back the same way."),
        ]),
        ("Schedules", [
            Item(id: "schedule-list", title: "Schedules load", how: "Your 07:00 schedule appears on the right days."),
            Item(id: "schedule-add", title: "Add one", how: "Add one for a few minutes from now, with Freo Mind. Does it run?"),
            Item(id: "schedule-toggle", title: "Turn it off and on, then delete it", how: "Switch, then swipe left."),
        ]),
        ("Device and parts", [
            Item(id: "device", title: "Device", how: "More > Device: firmware matches v01.07.01.02, battery shows."),
            Item(id: "parts", title: "Parts hours",
                 how: "More > Parts and Consumables: enter the hours the Narwal app shows for each part. Check again after a few cleans."),
            Item(id: "restart", title: "Restart Robot", how: "More > Device > Restart Robot. It comes back within a few minutes."),
        ]),
        ("Everyday use", [
            Item(id: "resolved", title: "Mark resolved",
                 how: "Next \"can't find the base station\" alert: tap Mark resolved. Does the robot find it?"),
            Item(id: "connect", title: "Connects without the Narwal app",
                 how: "Close both apps, wait an hour, open only this one."),
            Item(id: "crash", title: "No crashes", how: "More > Diagnostics > Crash reports stays empty."),
        ]),
    ]

    var body: some View {
        List {
            Section {
                Text("Turn on More > Change robot settings first. Every change can be undone in the Narwal app. Mark each item, then share the report.")
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
        lines.append("## Robot values")
        // The raw values behind each setting, to check the mappings that
        // couldn't be confirmed without the robot.
        if let settings = store.robotSettings {
            for setting in RobotSetting.all {
                let paths = Set(setting.choices.flatMap { $0.writes.map(\.path) }).sorted { $0.lexicographicallyPrecedes($1) }
                let raw = paths.map { "\($0.map(String.init).joined(separator: "."))=\(settings.int(path: $0))" }
                lines.append("- \(setting.id): \(setting.label(in: settings)) [\(raw.joined(separator: " "))]")
            }
            if let mapId = store.map?.mapId {
                lines.append("- noStairs(map \(mapId)): \(settings.noStairs(mapId: mapId))")
                lines.append("- cleaningOrder: \(settings.cleaningOrder(mapId: mapId) ?? [])")
            }
        } else {
            lines.append("- settings not loaded")
        }
        if let station = store.status?.station {
            lines.append("- detergent=\(station.detergent ?? -1) stain=\(station.stainRemover ?? -1)/\(station.stainRemoverPercent ?? -1)% wood=\(station.woodFloorSolution ?? -1)/used \(station.woodFloorSolutionUsedPercent ?? -1)%")
        }
        for room in store.map?.rooms ?? [] {
            lines.append("- room \(room.id) \(room.displayName): floor=\(room.floor.label) angle=\(room.floorAngle) soiled=\(room.isHeavilySoiled) type=\(room.roomType)")
        }
        lines.append("- cleans recorded on the phone: \(store.ledger.entries.count)")

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
