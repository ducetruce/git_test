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
                    TodayView().tabItem { Label("Today", systemImage: "circle.circle") }
                    MapScreen().tabItem { Label("Clean", systemImage: "map") }
                    StationView().tabItem { Label("Station", systemImage: "drop") }
                    SettingsView().tabItem { Label("More", systemImage: "line.3.horizontal") }
                }
            } else {
                SetupView()
            }
        }
        // One look everywhere: dark, with the calm teal accent.
        .preferredColorScheme(.dark)
        .tint(Theme.teal)
        .alert(store.lastErrorTitle ?? "The robot didn't do that", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil; store.lastErrorTitle = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }
}
