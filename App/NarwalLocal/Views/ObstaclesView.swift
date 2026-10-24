import NarwalKit
import SwiftUI

/// Obstacles the robot's camera recognised on its last runs, with the photo
/// it took when it sends one locally.
struct ObstaclesView: View {
    @Environment(RobotStore.self) private var store

    var body: some View {
        List {
            if let obstacles = store.map?.obstacles, !obstacles.isEmpty {
                ForEach(obstacles) { obstacle in
                    NavigationLink {
                        ObstaclePhotoView(obstacle: obstacle)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(obstacle.name)
                            if let room = roomName(obstacle) {
                                Text(room).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Text("The robot's map has no recognised obstacles right now. They appear after a clean in which its camera spots something.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Obstacle photos")
        .themedList()
        .refreshable { await store.reloadMap() }
    }

    private func roomName(_ obstacle: VisionObstacle) -> String? {
        guard let map = store.map else { return nil }
        let g = map.gridPoint(for: obstacle.center)
        guard let id = map.roomId(atGridX: Int(g.x), y: Int(g.y)) else { return nil }
        return map.rooms.first { $0.id == id }?.displayName
    }
}

private struct ObstaclePhotoView: View {
    @Environment(RobotStore.self) private var store
    let obstacle: VisionObstacle
    @State private var image: UIImage?
    @State private var failed: String?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 16) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityLabel("Photo of the \(obstacle.name.lowercased())")
            } else if loading {
                ProgressView("Asking the robot for its photo…")
            } else {
                Text(failed ?? "The robot didn't send a photo of this one. It may keep photos only in Narwal's cloud.")
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(obstacle.name)
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        do {
            if let data = try await store.obstaclePhoto(obstacle.id) { image = UIImage(data: data) }
        } catch {
            failed = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
