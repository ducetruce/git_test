import SwiftUI
import GadgetbridgeCore

struct ContentView: View {
    @ObservedObject var deviceListViewModel: DeviceListViewModel
    let repository: ActivityRepository

    var body: some View {
        NavigationStack {
            DeviceListView(viewModel: deviceListViewModel, repository: repository)
        }
    }
}
