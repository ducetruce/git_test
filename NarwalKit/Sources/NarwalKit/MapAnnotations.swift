import Foundation

/// A no-go zone from StaticMapPayload field 9 (`forbiddens`):
///
///     ForbiddenArea {1: polygon (repeated), 2: type, 3: id, 4: roomId, 5: mode}
///
/// Field numbers from docs/schema (MapBaseType.pb.dart). Polygon points are
/// in map coordinates, the same units as the dock and the live position.
public struct NoGoZone: Equatable, Sendable, Identifiable {
    /// ForbiddenArea_ForbiddenType: what the robot must not do there.
    public enum Kind: Int, Sendable {
        case unspecified = 0
        case noVacuum = 1
        case noMop = 2
        case noVacuumOrMop = 3

        public var label: String {
            switch self {
            case .unspecified, .noVacuumOrMop: return "No-go"
            case .noVacuum: return "No vacuum"
            case .noMop: return "No mop"
            }
        }
    }

    public var id: Int
    public var kind: Kind
    /// Set when the zone belongs to a room.
    public var roomId: Int?
    /// ForbiddenArea_ForbiddenMode 1: the whole room rather than a drawn region.
    public var coversWholeRoom: Bool
    public var polygon: [MapPoint]
}

extension NoGoZone {
    init(_ m: ProtoMessage) {
        id = m.int(3) ?? 0
        kind = m.int(2).flatMap(Kind.init(rawValue:)) ?? .unspecified
        roomId = m.int(4).flatMap { $0 > 0 ? $0 : nil }
        coversWholeRoom = m.int(5) == 1
        polygon = m.messages(1).map(MapCoordinates.point)
    }
}

/// A virtual wall from StaticMapPayload field 50:
/// `VirtualWallData {1: id, 2: startPoint, 3: endPoint}`.
public struct VirtualWall: Equatable, Sendable, Identifiable {
    public var id: Int
    public var start: MapPoint
    public var end: MapPoint
}

extension VirtualWall {
    init(_ m: ProtoMessage) {
        id = m.int(1) ?? 0
        start = m.message(2).map(MapCoordinates.point) ?? MapPoint(x: 0, y: 0)
        end = m.message(3).map(MapCoordinates.point) ?? MapPoint(x: 0, y: 0)
    }
}

enum MapCoordinates {
    /// A point message whose x/y are either float (`Point`, fixed32) or int32
    /// (`Grid`, varint). The schema leaves ForbiddenArea's polygon element
    /// type unnamed, so both are accepted. Proto3 omits zeros: absent is 0.
    static func point(_ m: ProtoMessage) -> MapPoint {
        MapPoint(x: coordinate(m, 1), y: coordinate(m, 2))
    }

    static func coordinate(_ m: ProtoMessage, _ field: Int) -> Double {
        switch m.first(field) {
        case .fixed32(let bits): return Double(Float(bitPattern: bits))
        case .varint(let v): return Double(Int32(truncatingIfNeeded: v))
        default: return 0
        }
    }
}
