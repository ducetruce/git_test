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
                    NavigationLink("Connection") { connection }
                    NavigationLink("Feature lab") { LabView() }
                    NavigationLink("Connection log") { LogView() }
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
/// for them. Read-only until changing settings has been tried safely.
private struct RobotSettingsSections: View {
    @Environment(RobotStore.self) private var store

    var body: some View {
        let settings = store.robotSettings
        Section {
            LabeledContent("Voice volume", value: settings.map { "\($0.voiceVolume)%" } ?? "–")
        } header: {
            Text("Sound")
        }

        Section {
            if let dnd = settings?.doNotDisturb {
                LabeledContent("Quiet hours", value: dnd.enabled ? "\(clock(dnd.begin)) – \(clock(dnd.end))" : "Off")
            } else {
                LabeledContent("Quiet hours", value: settings == nil ? "–" : "Off")
            }
            if let zone = settings?.timeZone {
                LabeledContent("Time zone", value: zone)
            }
        } header: {
            Text("Schedule & quiet hours")
        } footer: {
            Text(settings == nil
                 ? "Pull down to load the robot's settings."
                 : "Shown read-only for now. Switches arrive once changing a setting has been tested safely on your robot.")
        }
    }

    /// Seconds after midnight -> "22:00".
    private func clock(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 3600 % 24, seconds / 60 % 60)
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
