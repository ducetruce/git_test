import SwiftUI
import GadgetbridgeCore

struct RootView: View {
    @ObservedObject var deviceList: DeviceListViewModel
    let repository: ActivityRepository

    var body: some View {
        TabView {
            NavigationStack {
                HomeView(deviceList: deviceList, repository: repository)
                    .toolbar(.hidden, for: .navigationBar)
            }
            .tabItem { Label("Data", systemImage: "waveform.path.ecg") }

            NavigationStack {
                DevicesView(viewModel: deviceList, repository: repository)
            }
            .tabItem { Label("Devices", systemImage: "dot.radiowaves.left.and.right") }

            NavigationStack {
                ProtocolLogView()
            }
            .tabItem { Label("Log", systemImage: "terminal") }
        }
        .tint(Instrument.amber)
        .toolbarBackground(Instrument.ground, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .preferredColorScheme(.dark)
        .alert(
            "Connection error",
            isPresented: Binding(
                get: { deviceList.lastError != nil },
                set: { if !$0 { deviceList.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deviceList.lastError ?? "")
        }
    }
}
