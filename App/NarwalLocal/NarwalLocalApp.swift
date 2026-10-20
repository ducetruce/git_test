import SwiftUI

@main
struct NarwalLocalApp: App {
    @State private var store = RobotStore()
    @State private var presets = PresetStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        CrashReports.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(presets)
                .onAppear {
                    store.alerts.requestPermission()
                    if LaunchGuard.begin() {
                        store.pauseAutoConnect()
                    } else {
                        store.connect()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.appBecameActive() }
                    if phase == .background { LaunchGuard.markStable() }
                }
        }
    }
}

struct RootView: View {
    @Environment(RobotStore.self) private var store

    var body: some View {
        Group {
            if store.isConfigured {
                TabView {
                    HomeView().tabItem { Label("Home", systemImage: "house") }
                    MapScreen().tabItem { Label("Map", systemImage: "map") }
                    DockView().tabItem { Label("Station", systemImage: "drop") }
                    SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
                }
            } else {
                SetupView()
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }
}
