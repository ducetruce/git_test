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

/// Furniture the robot recognised: StaticMapPayload 32 VisionData {1 furnitures}.
///
///     Furniture {1 id, 2 furnitureType, 3 box BoundingBox {1 center Point,
///                2 width, 3 height}, 4 angle (degrees), ...}
///
/// Centre in map coordinates; width and height in grid units (as parsed by
/// the reference integration from real robots).
public struct Furniture: Equatable, Sendable, Identifiable {
    public var id: Int
    public var type: Int
    public var center: MapPoint
    public var width: Double
    public var height: Double
    /// Degrees, counter-clockwise in map coordinates.
    public var angle: Double
    /// Field 5: drawn mirrored (e.g. which end an L-shaped sofa's chaise is).
    public var isMirrored = false

    public var name: String { Self.names[type] ?? "Object" }

    /// Tables and similar that the Narwal app draws as circles.
    public var isRound: Bool { [5, 7, 25, 26].contains(type) }

    /// Furniture types from the app's map_furniture.json.
    public static let names: [Int: String] = [
        1: "Single bed", 2: "Double bed", 3: "Baby bed", 4: "Dining table", 5: "Round table",
        6: "Coffee table", 7: "Round coffee table", 8: "TV stand", 9: "Bedside table",
        10: "Cabinet", 11: "Wardrobe", 12: "Shoe cabinet", 13: "Armchair", 14: "Sofa",
        15: "L-shaped sofa", 16: "Lounge chair", 17: "Chair", 18: "Bar stool", 19: "Litter box",
        20: "Pet feeder", 21: "Pet house", 22: "Washing machine", 23: "Refrigerator",
        24: "Air conditioner", 25: "Fan", 26: "Plant", 27: "Floor mirror", 28: "Toilet",
        29: "Piano", 30: "U-shaped sofa", 31: "Desk", 32: "Grand piano", 33: "Washbasin",
        34: "Stove", 75: "Cat house", 76: "Dog house", 78: "Scale",
    ]
}

extension Furniture {
    init(_ m: ProtoMessage) {
        id = m.int(1) ?? 0
        type = m.int(2) ?? 0
        let box = m.message(3)
        center = box?.message(1).map(MapCoordinates.point) ?? MapPoint(x: 0, y: 0)
        width = Double(box?.float(2) ?? 0)
        height = Double(box?.float(3) ?? 0)
        angle = Double(m.float(4) ?? 0)
        isMirrored = m.int(5) == 1
    }
}

/// A carpet: StaticMapPayload 26 Carpet {1 id, 2 polygon (Grid), ..., 12 roomId}.
public struct CarpetArea: Equatable, Sendable, Identifiable {
    public var id: Int
    public var polygon: [MapPoint]
    public var roomId: Int?
}

extension CarpetArea {
    init(_ m: ProtoMessage) {
        id = m.int(1) ?? 0
        polygon = m.messages(2).map(MapCoordinates.point)
        // User-edited carpets may only carry carpetModifyPolygon (6).
        if polygon.count < 3 { polygon = m.messages(6).map(MapCoordinates.point) }
        roomId = m.int(12).flatMap { $0 > 0 ? $0 : nil }
    }
}

/// A doorway: StaticMapPayload 11 Door {1 roomIds, 2 doorPts (Grid), 3 hasDoorSill, ...}.
public struct Doorway: Equatable, Sendable {
    public var points: [MapPoint]
    public var roomIds: [Int]
    public var hasSill: Bool
}

extension Doorway {
    init(_ m: ProtoMessage) {
        points = m.messages(2).map(MapCoordinates.point)
        roomIds = m.varints(1)
        hasSill = m.int(3) == 1
    }
}
