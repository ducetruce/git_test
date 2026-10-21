import CoreGraphics
import NarwalKit
import SwiftUI

enum MapPalette {
    static let rooms: [(UInt8, UInt8, UInt8)] = [
        (130, 177, 255), (255, 183, 130), (149, 214, 164), (240, 160, 200),
        (196, 170, 255), (255, 220, 120), (128, 214, 220), (230, 150, 140),
        (180, 200, 120), (170, 190, 230), (250, 200, 170), (160, 220, 200),
    ]
    static let unknown: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    static let floor: (UInt8, UInt8, UInt8) = (205, 210, 218)
    static let obstacle: (UInt8, UInt8, UInt8) = (90, 95, 105)
    static let carpet = Color(red: 0.45, green: 0.33, blue: 0.22)
    static let furnitureLine = Color(red: 0.28, green: 0.30, blue: 0.36)

    static func color(forRoom id: Int) -> Color {
        let c = rooms[(id - 1 + rooms.count) % rooms.count]
        return Color(red: Double(c.0) / 255, green: Double(c.1) / 255, blue: Double(c.2) / 255)
    }
}

extension Furniture {
    /// Robot floats can be NaN or absurd; such a piece is skipped, not drawn.
    var isDrawable: Bool {
        [center.x, center.y, width, height, angle].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
}

extension RobotMap {
    /// RGBA image, flipped so north is up (map rows grow upward).
    /// Unselected rooms are dimmed while a selection exists. Carpet cells
    /// get the Narwal app's fine checked texture; `highlight` paints one
    /// low-byte pixel type magenta (Map > Layers > Pixel types).
    func image(selected: Set<Int> = [], carpets: Bool = true, highlight: Int? = nil) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let outRow = height - 1 - y
            for x in 0..<width {
                let o = (outRow * width + x) * 4
                var c: (UInt8, UInt8, UInt8, UInt8)
                switch pixel(x: x, y: y) {
                case .unknown:
                    c = MapPalette.unknown
                case .unassignedFloor:
                    c = (MapPalette.floor.0, MapPalette.floor.1, MapPalette.floor.2, 255)
                case .unassignedObstacle:
                    c = (MapPalette.obstacle.0, MapPalette.obstacle.1, MapPalette.obstacle.2, 255)
                case .floor(let room), .wall(let room):
                    let base = MapPalette.rooms[(max(room, 1) - 1) % MapPalette.rooms.count]
                    let isWall: Bool
                    if case .wall = pixel(x: x, y: y) { isWall = true } else { isWall = false }
                    let dim = !selected.isEmpty && !selected.contains(room)
                    var r = base.0, g = base.1, b = base.2
                    // 0x10 cells are a lighter shade in the Narwal app.
                    if isWall {
                        r = UInt8((Int(r) * 3 + 255) / 4); g = UInt8((Int(g) * 3 + 255) / 4); b = UInt8((Int(b) * 3 + 255) / 4)
                    }
                    if carpets, isCarpet(x: x, y: y) {
                        // Carpet: darker overall with a fine checked weave.
                        let k = (x + y) % 2 == 0 ? 55 : 80
                        r = UInt8(Int(r) * k / 100); g = UInt8(Int(g) * k / 100); b = UInt8(Int(b) * k / 100)
                    }
                    c = (r, g, b, dim ? 90 : 255)
                }
                if let highlight, Int(pixels[y * width + x] & 0xFF) == highlight, c.3 > 0 {
                    c = (255, 0, 200, 255)
                }
                rgba[o] = c.0
                rgba[o + 1] = c.1
                rgba[o + 2] = c.2
                rgba[o + 3] = c.3
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// The house map with rooms, dock, live robot and trail. Tap a room to
/// toggle it when `onTapRoom` is set; drag to draw a zone when `onDrawZone`
/// is set.
struct MapCanvas: View {
    let map: RobotMap
    var selected: [Int] = []
    var pose: LivePose?
    var trail: [MapPoint] = []
    /// Zones in world coordinates.
    var zones: [Payloads.Zone] = []
    var onTapRoom: ((Int) -> Void)?
    var onDrawZone: ((Payloads.Zone) -> Void)?
    /// The surrounding zoom level: labels and icons are counter-scaled so
    /// they stay readable instead of growing with the map.
    var zoom: CGFloat = 1
    var showFurniture = true
    var showCarpets = true
    /// Low-byte pixel type to paint magenta, for diagnosis.
    var highlightPixelType: Int?
    /// Carpet to outline, e.g. while it's being edited.
    var highlightCarpet: Int?

    @State private var image: CGImage?
    @State private var centroids: [Int: MapPoint] = [:]
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / CGFloat(map.width), geo.size.height / CGFloat(map.height))
            let size = CGSize(width: CGFloat(map.width) * scale, height: CGFloat(map.height) * scale)
            let toScreen = { (p: MapPoint) -> CGPoint in
                CGPoint(x: CGFloat(p.x) * scale, y: (CGFloat(map.height) - CGFloat(p.y)) * scale)
            }

            ZStack(alignment: .topLeading) {
                if let image {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                }

                Path { path in
                    let points = trail.map { toScreen(map.gridPoint(for: $0)) }
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                // Carpets: diagonal hatching inside a solid outline.
                ForEach(Array((showCarpets ? map.carpets : []).enumerated()), id: \.offset) { _, carpet in
                    let points = carpet.polygon.map { toScreen(map.gridPoint(for: $0)) }
                    polygonPath(points).fill(MapPalette.carpet.opacity(0.25))
                    hatching(over: points, spacing: max(3, 4 / zoom))
                        .stroke(MapPalette.carpet.opacity(0.7), lineWidth: max(0.5, 1 / zoom))
                        .clipShape(polygonPath(points))
                    polygonPath(points).stroke(MapPalette.carpet, lineWidth: max(0.75, 1.5 / zoom))
                }

                if let id = highlightCarpet, let carpet = map.carpets.first(where: { $0.id == id }) {
                    let points = carpet.polygon.map { toScreen(map.gridPoint(for: $0)) }
                    polygonPath(points).fill(Color.yellow.opacity(0.3))
                    polygonPath(points).stroke(Color.yellow, lineWidth: max(1.5, 3 / zoom))
                }

                // Furniture: a floor-plan drawing of each piece, rotated into place.
                ForEach(Array((showFurniture ? map.furniture.filter(\.isDrawable) : []).enumerated()), id: \.offset) { _, item in
                    FurnitureView(item: item, lineWidth: max(0.5, 1 / zoom))
                        .frame(width: max(CGFloat(item.width) * scale, 4), height: max(CGFloat(item.height) * scale, 4))
                        // Map angles are counter-clockwise with y up; screen y is down.
                        .rotationEffect(.degrees(-item.angle))
                        .position(toScreen(map.gridPoint(for: item.center)))
                }

                // Doorways: a short dark bar across the opening.
                ForEach(Array(map.doorways.enumerated()), id: \.offset) { _, door in
                    if let first = door.points.first, let last = door.points.last, door.points.count > 1 {
                        Path { path in
                            path.move(to: toScreen(map.gridPoint(for: first)))
                            path.addLine(to: toScreen(map.gridPoint(for: last)))
                        }
                        .stroke(Color.black.opacity(0.55), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    }
                }

                // Robot-stored no-go zones and virtual walls (read-only).
                // Keyed by position: robots may repeat ids (e.g. 0).
                ForEach(Array(map.noGoZones.enumerated()), id: \.offset) { _, zone in
                    let points = zone.polygon.map { toScreen(map.gridPoint(for: $0)) }
                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: first)
                        points.dropFirst().forEach { path.addLine(to: $0) }
                        path.closeSubpath()
                    }
                    .fill(Color.red.opacity(0.18))
                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: first)
                        points.dropFirst().forEach { path.addLine(to: $0) }
                        path.closeSubpath()
                    }
                    .stroke(Color.red, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    if zone.kind != .unspecified, zone.kind != .noVacuumOrMop, !points.isEmpty {
                        Text(zone.kind.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                            .position(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                                      y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
                    }
                }
                ForEach(Array(map.virtualWalls.enumerated()), id: \.offset) { _, wall in
                    Path { path in
                        path.move(to: toScreen(map.gridPoint(for: wall.start)))
                        path.addLine(to: toScreen(map.gridPoint(for: wall.end)))
                    }
                    .stroke(Color.red, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }

                ForEach(Array(zones.enumerated()), id: \.offset) { index, zone in
                    let a = toScreen(MapPoint(x: Double(zone.x1 - map.originX), y: Double(zone.y1 - map.originY)))
                    let b = toScreen(MapPoint(x: Double(zone.x2 - map.originX), y: Double(zone.y2 - map.originY)))
                    let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                    Rectangle()
                        .fill(Color.orange.opacity(0.25))
                        .overlay(Rectangle().stroke(Color.orange, lineWidth: 2))
                        .overlay(Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.orange))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }

                if let start = dragStart, let end = dragEnd {
                    Rectangle()
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .frame(width: abs(end.x - start.x), height: abs(end.y - start.y))
                        .position(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                }

                ForEach(map.rooms) { room in
                    if let c = centroids[room.id] {
                        let order = selected.firstIndex(of: room.id).map { $0 + 1 }
                        Text(order.map { "\($0). \(room.displayName)" } ?? room.displayName)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .scaleEffect(1 / zoom)
                            .position(toScreen(c))
                    }
                }

                if let dock = map.dock {
                    Image(systemName: "bolt.circle.fill")
                        .foregroundStyle(.green, .white)
                        .font(.title3)
                        .scaleEffect(1 / zoom)
                        .position(toScreen(dock))
                }

                if let pose {
                    Image(systemName: "location.north.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white, .blue)
                        // Heading is counter-clockwise from +x with y up;
                        // the symbol points north, i.e. +90°.
                        .rotationEffect(.radians(.pi / 2 - pose.heading))
                        .scaleEffect(1 / zoom)
                        .position(toScreen(map.gridPoint(for: pose.position)))
                        .animation(.easeInOut(duration: 1.2), value: pose.position.x)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard let onTapRoom, onDrawZone == nil else { return }
                let gx = Int(location.x / scale)
                let gy = Int((size.height - location.y) / scale)
                if let room = map.roomId(atGridX: gx, y: gy) { onTapRoom(room) }
            }
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        dragStart = value.startLocation
                        dragEnd = value.location
                    }
                    .onEnded { value in
                        defer { dragStart = nil; dragEnd = nil }
                        // Screen -> grid (y up) -> world.
                        func world(_ p: CGPoint) -> (Int, Int) {
                            let x = min(max(p.x, 0), size.width) / scale
                            let y = (size.height - min(max(p.y, 0), size.height)) / scale
                            return (Int(x.rounded()) + map.originX, Int(y.rounded()) + map.originY)
                        }
                        let a = world(value.startLocation)
                        let b = world(value.location)
                        // Ignore slivers: at least ~3 cells each way.
                        guard abs(a.0 - b.0) >= 3, abs(a.1 - b.1) >= 3 else { return }
                        onDrawZone?(Payloads.Zone(x1: a.0, y1: a.1, x2: b.0, y2: b.1))
                    },
                including: onDrawZone == nil ? .subviews : .all
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: RenderKey(mapId: map.mapId, pixels: map.pixels.count, selected: selected,
                            carpets: showCarpets, highlight: highlightPixelType)) {
            image = map.image(selected: Set(selected), carpets: showCarpets, highlight: highlightPixelType)
            centroids = map.roomCentroids()
        }
    }

    private func polygonPath(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            points.dropFirst().forEach { path.addLine(to: $0) }
            path.closeSubpath()
        }
    }

    /// Diagonal lines covering a polygon's bounding box.
    private func hatching(over points: [CGPoint], spacing: CGFloat) -> Path {
        Path { path in
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return }
            let height = maxY - minY
            var x = minX - height
            while x <= maxX {
                path.move(to: CGPoint(x: x, y: maxY))
                path.addLine(to: CGPoint(x: x + height, y: minY))
                x += spacing
            }
        }
    }

    private struct RenderKey: Equatable {
        let mapId: Int
        let pixels: Int
        let selected: [Int]
        let carpets: Bool
        let highlight: Int?
    }
}
