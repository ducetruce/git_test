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
                RobotSettingsSections()

                Section("This app") {
                    Picker("Area units", selection: $areaUnit) {
                        ForEach(AreaFormat.Unit.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section {
                    NavigationLink("Test checklist") { ChecklistView() }
                    NavigationLink("Connection") { connection }
                    NavigationLink("Feature lab") { LabView() }
                    NavigationLink("Connection log") { LogView() }
                    NavigationLink("Crash reports") { CrashReportsView() }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("The feature lab helps decode settings this app doesn't support yet.")
                }

                Section {
                    Button("Forget this robot", role: .destructive) { confirmForget = true }
                } footer: {
                    Text("This app talks only to your robot on your Wi-Fi. Nothing is sent to Narwal or anywhere else.")
                }
            }
            .navigationTitle("Settings")
            .refreshable { await store.reloadSettings() }
            .task { if store.robotSettings == nil { await store.reloadSettings() } }
            .confirmationDialog("Forget this robot?", isPresented: $confirmForget) {
                Button("Forget", role: .destructive) { store.forgetRobot() }
            }
        }
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
                    Button("Reconnect") { store.connect() }
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

/// The robot's own settings on one flat screen, grouped the way people look
/// for them. Read-only until the owner turns on "Change robot settings".
private struct RobotSettingsSections: View {
    @Environment(RobotStore.self) private var store
    @AppStorage("allowRobotWrites") private var allowWrites = false
    @State private var volume: Double?
    @State private var confirmWrites = false

    var body: some View {
        let settings = store.robotSettings
        // Controls stay in place while a write runs (only disabled): swapping
        // a slider out mid-drag lost the next change.
        let editable = allowWrites && settings != nil
        let busy = store.busyAction != nil

        Section {
            if editable, let settings {
                VStack(alignment: .leading) {
                    LabeledContent("Voice volume", value: "\(Int(volume ?? Double(settings.voiceVolume)))%")
                    Slider(value: Binding(get: { volume ?? Double(settings.voiceVolume) }, set: { volume = $0 }),
                           in: 0...100, step: 1, onEditingChanged: { editing in
                        guard !editing, let volume else { return }
                        Task {
                            await store.changeVolume(to: Int(volume))
                            self.volume = nil
                        }
                    })
                    .disabled(busy)
                }
            } else {
                LabeledContent("Voice volume", value: settings.map { "\($0.voiceVolume)%" } ?? "–")
            }
            ForEach(RobotSettingKey.all.filter { $0.group == .sound }) { row($0, settings, editable).disabled(busy) }
        } header: {
            Text(RobotSettingKey.Group.sound.rawValue)
        }

        QuietHoursSection(settings: settings, editable: editable)
            .disabled(busy)

        ForEach(RobotSettingKey.Group.allCases.filter { $0 != .sound }, id: \.self) { group in
            Section {
                ForEach(RobotSettingKey.all.filter { $0.group == group }) { row($0, settings, editable).disabled(busy) }
            } header: {
                Text(group.rawValue)
            } footer: {
                let notes = RobotSettingKey.all.filter { $0.group == group }.compactMap(\.footnote)
                if !notes.isEmpty { Text(notes.joined(separator: " ")) }
            }
        }

        Section {
            Toggle("Change robot settings", isOn: Binding(
                get: { allowWrites },
                set: { on in if on { confirmWrites = true } else { allowWrites = false } }
            ))
        } footer: {
            Text(settings == nil
                 ? "Pull down to load the robot's settings."
                 : "Beta. After each change the app reads the setting back and tells you if the robot didn't apply it.")
        }
        .alert("Change robot settings?", isPresented: $confirmWrites) {
            Button("Turn on") { allowWrites = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This app hasn't changed settings on a real robot before. Start with voice volume and check the Narwal app shows the same value. Any setting can be changed back in the Narwal app.")
        }
    }

    @ViewBuilder
    private func row(_ key: RobotSettingKey, _ settings: RobotSettings?, _ editable: Bool) -> some View {
        let value = settings?.value(key)
        if editable, let value {
            if key.isToggle {
                Toggle(key.title, isOn: Binding(
                    get: { value != 0 },
                    set: { on in Task { await store.changeSetting(key, to: on ? 1 : 0) } }
                ))
            } else {
                Picker(key.title, selection: Binding(
                    get: { value },
                    set: { new in Task { await store.changeSetting(key, to: new) } }
                )) {
                    if !key.options.contains(where: { $0.value == value }) {
                        Text("Not set").tag(value)
                    }
                    ForEach(key.options, id: \.value) { Text($0.label).tag($0.value) }
                }
            }
        } else {
            LabeledContent(key.title, value: value.map { key.label(for: $0) } ?? "–")
        }
    }
}

private struct QuietHoursSection: View {
    @Environment(RobotStore.self) private var store
    let settings: RobotSettings?
    let editable: Bool

    var body: some View {
        let dnd = settings?.doNotDisturb ?? .init(enabled: false, begin: 22 * 3600, end: 8 * 3600)
        Section {
            if editable {
                Toggle("Quiet hours", isOn: Binding(
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
                LabeledContent("Quiet hours", value: settings == nil ? "–"
                               : dnd.enabled ? "\(clock(dnd.begin)) – \(clock(dnd.end))" : "Off")
            }
            if let zone = settings?.timeZone {
                LabeledContent("Time zone", value: zone)
            }
        } header: {
            Text("Quiet hours")
        } footer: {
            Text("No cleaning, emptying or voice prompts during quiet hours.")
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
        store.connect()
    }
}
