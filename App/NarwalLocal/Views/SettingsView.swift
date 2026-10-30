import NarwalKit
import SwiftUI

struct SettingsView: View {
    @Environment(RobotStore.self) private var store
    @State private var confirmForget = false
    @State private var testResult: String?
    @State private var testing = false
    @State private var deviceIdText = ""
    @AppStorage(AreaFormat.unitKey) private var areaUnit = AreaFormat.Unit.automatic

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { SchedulesView() } label: { Label("Schedules", systemImage: "calendar") }
                    NavigationLink { HistoryView() } label: { Label("Cleaning history", systemImage: "clock.arrow.circlepath") }
                    NavigationLink { ObstaclesView() } label: { Label("Obstacle photos", systemImage: "camera.viewfinder") }
                }

                RobotSettingsSections()

                Section("This app") {
                    Picker("Area units", selection: $areaUnit) {
                        ForEach(AreaFormat.Unit.allCases) { Text($0.label).tag($0) }
                    }
                    NavigationLink { diagnostics } label: { Label("Diagnostics", systemImage: "stethoscope") }
                }

                Section {
                    Button("Forget this robot", role: .destructive) { confirmForget = true }
                } footer: {
                    Text("This app talks only to your robot on your Wi-Fi. Nothing is sent to Narwal or anywhere else.")
                }
            }
            .navigationTitle("More")
            .themedList()
            .refreshable { await store.reloadSettings() }
            .task { if store.robotSettings == nil { await store.reloadSettings() } }
            .confirmationDialog("Forget this robot?", isPresented: $confirmForget) {
                Button("Forget", role: .destructive) { store.forgetRobot() }
            }
        }
    }

    /// Troubleshooting tools, kept off the main list.
    private var diagnostics: some View {
        List {
            Section {
                NavigationLink("Connection") { connection }
                NavigationLink("Connection log") { LogView() }
                NavigationLink("Crash reports") { CrashReportsView() }
            }
            Section {
                NavigationLink("Test checklist") { ChecklistView() }
                NavigationLink("Feature lab") { LabView() }
                NavigationLink("Hidden settings") { HiddenSettingsView() }
            } footer: {
                Text("The feature lab and hidden settings help decode what the robot stores. They aren't needed day to day.")
            }
        }
        .navigationTitle("Diagnostics")
        .themedList()
    }

    private var connection: some View {
            List {
                Section {
                    LabeledContent("Address", value: store.host)
                    Picker("Model", selection: Binding(get: { store.model }, set: { store.setModel($0) })) {
                        ForEach(NarwalModel.allCases) { Text($0.name).tag($0) }
                    }
                    TextField("Device ID (optional)", text: $deviceIdText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { store.setDeviceIdOverride(deviceIdText) }
                        .onAppear { deviceIdText = store.deviceIdOverride }
                    if let info = store.deviceInfo {
                        LabeledContent("Model key", value: info.productKey)
                        LabeledContent("Firmware", value: info.firmware)
                        LabeledContent("Device ID", value: info.deviceId)
                    }
                    if let map = store.map {
                        LabeledContent("Map", value: "#\(map.mapId), \(map.rooms.count) rooms")
                    }
                    Button("Reconnect") { store.connect(force: true) }
                    Button(testing ? "Testing…" : "Test connection") {
                        testing = true
                        Task {
                            testResult = await ConnectionTest.tcp(host: store.host)
                            testing = false
                        }
                    }
                    .disabled(testing)
                    if let testResult {
                        Text(testResult).font(.footnote).foregroundStyle(.secondary)
                    }
                    if store.host.contains(":") {
                        Text("This is an IPv6 address, which often fails. Tap Forget this robot and pick it again to get its IPv4 address.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Robot")
                } footer: {
                    Text("The model must match your robot: a Z10 Ultra disconnects apps that address it as another model. Leave Device ID empty unless asked; it's learned from the robot.")
                }
            }
            .navigationTitle("Connection")
    }
}

/// The robot's settings, in the Narwal app's menus and order.
private struct RobotSettingsSections: View {
    @Environment(RobotStore.self) private var store

    var body: some View {
        Section {
            NavigationLink { RobotMenuView(menu: .freoMind) } label: { Label("Freo Mind Mode", systemImage: "drop.circle") }
            NavigationLink { RobotMenuView(menu: .floorCleaning) } label: { Label("Floor Cleaning", systemImage: "bubbles.and.sparkles") }
            NavigationLink { RobotMenuView(menu: .carpet) } label: { Label("Carpet Detection and Cleaning", systemImage: "square.grid.3x3") }
            NavigationLink { GeneralMenuView() } label: { Label("General", systemImage: "gearshape") }
            NavigationLink { RobotMenuView(menu: .dock) } label: { Label("Dock", systemImage: "square.bottomhalf.filled") }
            NavigationLink { RobotMenuView(menu: .pet) } label: { Label("Pet-friendly Mode", systemImage: "pawprint") }
            NavigationLink { MapManagementView() } label: { Label("Map management", systemImage: "map") }
            NavigationLink { PartsView() } label: { Label("Parts and Consumables", systemImage: "wrench.and.screwdriver") }
        } header: {
            Text("Robot")
        }

        Section {
            NavigationLink { VoiceMenuView() } label: { Label("Navo Voice Assistant", systemImage: "waveform") }
            NavigationLink { RobotMenuView(menu: .ai) } label: { Label("AI Recognition", systemImage: "eye") }
            NavigationLink { DeviceView() } label: { Label("Device", systemImage: "info.circle") }
        }

    }
}

/// Every stored setting the Narwal app doesn't show for this robot, for
/// diagnostics.
struct HiddenSettingsView: View {
    @Environment(RobotStore.self) private var store

    var body: some View {
        List {
            Section {
                ForEach(RobotSetting.menu(.hidden)) { SettingRow(setting: $0) }
            } footer: {
                Text("The robot stores these, but the Narwal app doesn't show them for the Freo Z10 Ultra, so they may do nothing.")
            }
        }
        .navigationTitle("Hidden settings")
        .themedList()
        .task { if store.robotSettings == nil { await store.reloadSettings() } }
    }
}

struct QuietHoursSection: View {
    @Environment(RobotStore.self) private var store
    let settings: RobotSettings?
    let editable: Bool

    var body: some View {
        let dnd = settings?.doNotDisturb ?? .init(enabled: false, begin: 22 * 3600, end: 8 * 3600)
        Section {
            if editable {
                Toggle("Do Not Disturb Mode", isOn: Binding(
                    get: { dnd.enabled },
                    set: { on in change(dnd, enabled: on) }
                ))
                if dnd.enabled {
                    DatePicker("From", selection: time(dnd.begin) { change(dnd, begin: $0) },
                               displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: time(dnd.end) { change(dnd, end: $0) },
                               displayedComponents: .hourAndMinute)
                }
            } else {
                LabeledContent("Do Not Disturb Mode", value: settings == nil ? "–"
                               : dnd.enabled ? "\(clock(dnd.begin)) – \(clock(dnd.end))" : "Off")
            }
            if let zone = settings?.timeZone {
                LabeledContent("Time zone", value: zone)
            }
        } footer: {
            Text("Some robot voices and dock lights are turned off during these hours.")
        }
    }

    private func change(_ dnd: RobotSettings.DoNotDisturb, enabled: Bool? = nil, begin: Int? = nil, end: Int? = nil) {
        var new = dnd
        new.enabled = enabled ?? dnd.enabled
        new.begin = begin ?? dnd.begin
        new.end = end ?? dnd.end
        Task { await store.changeDoNotDisturb(to: new) }
    }

    /// Seconds after midnight <-> a Date today; committed on each change.
    private func time(_ seconds: Int, _ commit: @escaping (Int) -> Void) -> Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(seconds)) },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                commit((parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60)
            }
        )
    }

    /// Seconds after midnight -> "22:00".
    private func clock(_ seconds: Int) -> String {
        String(format: "%02ld:%02ld", seconds / 3600 % 24, seconds / 60 % 60)
    }
}

private struct CrashReportsView: View {
    @State private var files = CrashReports.all()

    var body: some View {
        List {
            if files.isEmpty {
                Text("No crashes recorded. iOS hands a crash over the next time the app opens, so open it once after a crash.")
                    .foregroundStyle(.secondary)
            }
            ForEach(files, id: \.self) { file in
                ShareLink(item: file) {
                    Label(file.deletingPathExtension().lastPathComponent, systemImage: "doc.text")
                }
            }
        }
        .navigationTitle("Crash reports")
        .onAppear { files = CrashReports.all() }
    }
}

private struct LogView: View {
    @Environment(RobotStore.self) private var store

    var body: some View {
        List(Array(store.log.enumerated().reversed()), id: \.offset) { entry in
            Text(entry.element).font(.caption.monospaced())
        }
        .navigationTitle("Log")
        .toolbar {
            ShareLink(item: store.log.joined(separator: "\n"))
        }
    }
}

struct SetupView: View {
    @Environment(RobotStore.self) private var store
    @State private var discovery = RobotDiscovery()
    @State private var manualHost = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if discovery.found.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Looking for robots on this Wi-Fi…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(discovery.found) { robot in
                        Button {
                            choose(robot.host)
                        } label: {
                            LabeledContent(robot.name, value: robot.host)
                        }
                    }
                } header: {
                    Text("Found nearby")
                } footer: {
                    Text("Your phone must be on the same network as the robot. If nothing shows up, enter the robot's IP address from your router.")
                }

                Section("Enter address") {
                    TextField("192.168.1.50", text: $manualHost)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Connect") { choose(manualHost) }
                        .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Find your robot")
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop() }
        }
    }

    private func choose(_ host: String) {
        store.setHost(host)
        store.connect(force: true)
    }
}
