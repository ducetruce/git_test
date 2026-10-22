import NarwalKit
import SwiftUI

/// Schedules stored on the robot, so they run without the phone.
struct SchedulesView: View {
    @Environment(RobotStore.self) private var store
    @State private var adding = false

    var body: some View {
        List {
            if let schedules = store.schedules {
                if schedules.isEmpty {
                    Text("No schedules yet.").foregroundStyle(.secondary)
                }
                ForEach(schedules) { schedule in
                    row(schedule)
                }
                .onDelete { offsets in
                    guard store.allowsWrites else { return }
                    for index in offsets {
                        let schedule = schedules[index]
                        Task { await store.deleteSchedule(schedule) }
                    }
                }
            } else if let error = store.schedulesError {
                Section {
                    Text("The robot didn't send its schedules: \(error)")
                    Button("Try again") { Task { await store.reloadSchedules() } }
                }
            } else {
                HStack {
                    ProgressView()
                    Text("Loading schedules…").foregroundStyle(.secondary)
                }
            }

            if !store.allowsWrites {
                Text("Turn on Settings > Change robot settings to add or change schedules.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Schedules")
        .toolbar {
            Button { adding = true } label: { Image(systemName: "plus") }
                .disabled(!store.allowsWrites || store.map == nil || store.busyAction != nil)
                .accessibilityLabel("Add schedule")
        }
        .sheet(isPresented: $adding) { AddScheduleSheet() }
        .refreshable { await store.reloadSchedules() }
        .task { await store.reloadSchedules() }
    }

    private func row(_ schedule: CleanSchedule) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(schedule.name.isEmpty ? "Schedule" : schedule.name)
                Text(schedule.summary ?? schedule.cron).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("On", isOn: Binding(
                get: { schedule.enabled },
                set: { on in Task { await store.setSchedule(schedule, enabled: on) } }
            ))
            .labelsHidden()
            .disabled(!store.allowsWrites || store.busyAction != nil)
        }
    }
}

private struct AddScheduleSheet: View {
    @Environment(RobotStore.self) private var store
    @Environment(PresetStore.self) private var presets
    @Environment(\.dismiss) private var dismiss

    /// nil = whole house with default settings.
    @State private var routineId: UUID?
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var weekdays: Set<Int> = Set(1...5)

    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        // Zone routines can't be stored as robot plans.
        let routines = presets.presets.filter { ($0.zones ?? []).isEmpty }
        NavigationStack {
            Form {
                Section {
                    Picker("Clean", selection: $routineId) {
                        Text("Whole house").tag(UUID?.none)
                        ForEach(routines) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                } footer: {
                    Text("Routines are saved from the Map tab. Zone routines can't be scheduled on the robot.")
                }
                Section("When") {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    HStack {
                        ForEach(0..<7) { day in
                            Button(Self.dayNames[day]) {
                                if weekdays.contains(day) { weekdays.remove(day) } else { weekdays.insert(day) }
                            }
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(weekdays.contains(day) ? Color.accentColor.opacity(0.2) : Color.clear,
                                        in: Capsule())
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("New schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(routines) }.disabled(weekdays.isEmpty)
                }
            }
        }
    }

    private func save(_ routines: [CleanPreset]) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let routine = routines.first { $0.id == routineId }
        Task {
            await store.addSchedule(
                name: routine?.name ?? "Whole house",
                rooms: routine?.rooms ?? [],
                settings: routine?.settings ?? CleanSettings(),
                perRoom: routine?.perRoom ?? [:],
                hour: parts.hour ?? 9, minute: parts.minute ?? 0, weekdays: weekdays)
        }
        dismiss()
    }
}
