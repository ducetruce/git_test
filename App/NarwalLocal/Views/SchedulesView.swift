import SwiftUI

/// The Z10 Ultra doesn't answer schedule/clean_schedule/get on the local
/// connection, and no other local reply carries the schedules, so they're
/// managed in the Narwal app (they run on the robot without the phone).
struct SchedulesView: View {
    var body: some View {
        List {
            Section {
                Label("Schedules are managed in the Narwal app", systemImage: "calendar")
                    .font(.headline)
                Text("The robot doesn't share its schedules over the local connection, so Narwal Local can't show, add or change them. Schedules you set in the Narwal app still run on the robot without either app.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Schedules")
        .themedList()
    }
}
