import NarwalKit
import SwiftUI

struct SettingsView: View {
    @Environment(RobotStore.self) private var store
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            List {
                Section("Robot") {
                    LabeledContent("Address", value: store.host)
                    if let info = store.deviceInfo {
                        LabeledContent("Model key", value: info.productKey)
                        LabeledContent("Firmware", value: info.firmware)
                        LabeledContent("Device ID", value: info.deviceId)
                    }
                    if let map = store.map {
                        LabeledContent("Map", value: "#\(map.mapId), \(map.rooms.count) rooms")
                    }
                    Button("Reconnect") { store.connect() }
                }

                Section {
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
            .confirmationDialog("Forget this robot?", isPresented: $confirmForget) {
                Button("Forget", role: .destructive) { store.forgetRobot() }
            }
        }
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
