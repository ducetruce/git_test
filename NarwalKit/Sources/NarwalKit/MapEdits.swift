import Foundation

/// map/operation edits beyond carpet handling. Each is one
/// MapOperationPayload (docs/schema/messages.txt, MapOperation.Request);
/// field numbers and operation enums are from the app's schema. Points are
/// in map coordinates, the same frame the map decodes them in.
public enum MapEdit: Equatable, Sendable {
    /// ForbiddenAreaOperation (4): OPERATION_SET (1) a rectangle, or
    /// OPERATION_DELETE (2) by id.
    case addNoGoZone(id: Int, kind: NoGoZone.Kind, corners: [MapPoint])
    case deleteNoGoZone(NoGoZone)
    /// VirtualWallOperation (13): OPERATION_ADD (3) / OPERATION_DELETE (2).
    case addWall(id: Int, from: MapPoint, to: MapPoint)
    case deleteWall(VirtualWall)
    /// RoomInfoOperation (3): RoomInfo {1 roomId, 2 type, 3 customName}.
    case renameRoom(Room, to: String)
    /// RoomMergeOperation (2): {1 roomId1, 2 roomId2, 3 newRoomId}.
    case mergeRooms(Int, Int)
    /// RoomSegOperation (1): {1 startSegPoint, 2 endSegPoint, 3 leftRoomId,
    /// 4 rightRoomId}: a line across one room.
    case splitRoom(Int, from: MapPoint, to: MapPoint)
    /// CarpetOperation (6): ADD (1) with a polygon, DELETE (3) by id, SET (2)
    /// whole-room carpet.
    case addCarpet(id: Int, corners: [MapPoint], gridInPixels: Bool, origin: (x: Int, y: Int))
    case deleteCarpet(Int)
    case setWholeRoomCarpet(CarpetArea, Bool)
    /// NoCarpetAreaOperation (14): ADD_NO_CARPET_AREA (1), DELETE (3).
    case addNoCarpetArea(id: Int, corners: [MapPoint], gridInPixels: Bool, origin: (x: Int, y: Int))
    /// SetFurnitureOperation (8): SET (1) to retype, DELETE (2).
    case retypeFurniture(Furniture, to: Int)
    case deleteFurniture(Furniture)
    /// RoomInfoOperation (3) with the room's own RoomInfo, one value changed:
    /// floor material and grain angle (4, 5), Heavily Soiled Room (7), room
    /// type (2).
    case setFloor(Room, FloorMaterial, angle: Int?)
    case setHeavilySoiled(Room, Bool)
    case setRoomType(Room, Int)
    /// MapRotateOperation (5): {1 rotateAngle} in degrees.
    case rotateMap(degrees: Int)
    /// SetMapNameOperation (7): {1 customName}.
    case renameMap(String)

    public static func == (a: MapEdit, b: MapEdit) -> Bool { a.operation == b.operation }

    /// (MapOperationPayload field, operation message bytes).
    public var operation: (field: Int, body: [UInt8]) {
        var w = ProtoWriter()
        switch self {
        case let .addNoGoZone(id, kind, corners):
            w.varint(1, 1)
            w.message(2) { area in
                for p in corners { area.message(1) { Self.point(&$0, p) } }
                area.varint(2, kind.rawValue)
                area.varint(3, id)
                area.varint(5, 0)
            }
            return (4, w.bytes)
        case let .deleteNoGoZone(zone):
            w.varint(1, 2)
            w.message(2) { area in
                for p in zone.polygon { area.message(1) { Self.point(&$0, p) } }
                area.varint(2, zone.kind.rawValue)
                area.varint(3, zone.id)
            }
            return (4, w.bytes)
        case let .addWall(id, from, to):
            w.varint(1, 3)
            w.message(2) { wall in
                wall.varint(1, id)
                wall.message(2) { Self.point(&$0, from) }
                wall.message(3) { Self.point(&$0, to) }
            }
            return (13, w.bytes)
        case let .deleteWall(wall):
            w.varint(1, 2)
            w.message(2) { data in
                data.varint(1, wall.id)
                data.message(2) { Self.point(&$0, wall.start) }
                data.message(3) { Self.point(&$0, wall.end) }
            }
            return (13, w.bytes)
        case let .renameRoom(room, name):
            w.bytesField(1, Self.info(room).setting(3, .bytes(Array(name.utf8))).encoded())
            return (3, w.bytes)
        case let .setFloor(room, floor, angle):
            var info = Self.info(room).setting(4, int: floor.rawValue)
            if let angle { info = info.setting(5, int: angle) }
            w.bytesField(1, info.encoded())
            return (3, w.bytes)
        case let .setHeavilySoiled(room, on):
            w.bytesField(1, Self.info(room).setting(7, int: on ? 1 : 0).encoded())
            return (3, w.bytes)
        case let .setRoomType(room, type):
            w.bytesField(1, Self.info(room).setting(2, int: type).encoded())
            return (3, w.bytes)
        case let .rotateMap(degrees):
            w.varint(1, degrees)
            return (5, w.bytes)
        case let .renameMap(name):
            w.string(1, name)
            return (7, w.bytes)
        case let .mergeRooms(a, b):
            w.varint(1, a)
            w.varint(2, b)
            w.varint(3, min(a, b))
            return (2, w.bytes)
        case let .splitRoom(room, from, to):
            w.message(1) { Self.point(&$0, from) }
            w.message(2) { Self.point(&$0, to) }
            w.varint(3, room)
            w.varint(4, room)
            return (1, w.bytes)
        case let .addCarpet(id, corners, pixels, origin):
            w.varint(1, id)
            w.varint(3, 1)
            for p in corners { w.message(4) { Self.grid(&$0, p, pixels, origin) } }
            return (6, w.bytes)
        case let .deleteCarpet(id):
            w.varint(1, id)
            w.varint(3, 3)
            return (6, w.bytes)
        case let .setWholeRoomCarpet(carpet, on):
            w.varint(1, carpet.id)
            w.varint(3, 2)
            w.varint(6, on ? 1 : 0)
            if let room = carpet.roomId { w.varint(12, room) }
            return (6, w.bytes)
        case let .addNoCarpetArea(id, corners, pixels, origin):
            w.varint(1, 1)
            w.message(2) { area in
                area.varint(1, id)
                for p in corners { area.message(2) { Self.grid(&$0, p, pixels, origin) } }
            }
            return (14, w.bytes)
        case let .retypeFurniture(item, type):
            w.varint(1, 1)
            w.message(2) { Self.furniture(&$0, item, type: type) }
            return (8, w.bytes)
        case let .deleteFurniture(item):
            w.varint(1, 2)
            w.message(2) { Self.furniture(&$0, item, type: item.type) }
            return (8, w.bytes)
        }
    }

    static func point(_ w: inout ProtoWriter, _ p: MapPoint) {
        w.float(1, Float(p.x))
        w.float(2, Float(p.y))
    }

    /// A `Grid` point, in whichever frame this map's carpets use.
    static func grid(_ w: inout ProtoWriter, _ p: MapPoint, _ pixels: Bool, _ origin: (x: Int, y: Int)) {
        let x = Int((pixels ? p.x - Double(origin.x) : p.x).rounded())
        let y = Int((pixels ? p.y - Double(origin.y) : p.y).rounded())
        w.varint(1, x)
        w.varint(2, y)
    }

    static func furniture(_ w: inout ProtoWriter, _ item: Furniture, type: Int) {
        w.varint(1, item.id)
        w.varint(2, type)
        w.message(3) { box in
            box.message(1) { Self.point(&$0, item.center) }
            box.float(2, Float(item.width))
            box.float(3, Float(item.height))
        }
        w.float(4, Float(item.angle))
    }
}

extension MapEdit {
    /// The room's RoomInfo as the robot sent it, or a minimal one.
    static func info(_ room: Room) -> ProtoMessage {
        if !room.info.fields.isEmpty { return room.info }
        return ProtoMessage(fields: []).setting(1, int: room.id).setting(2, int: room.roomType)
    }
}

extension RobotMap {
    /// A new id for an item kind: one more than the largest in use.
    public func nextId(_ ids: [Int]) -> Int { (ids.max() ?? 0) + 1 }

    /// Rectangle corners (map coordinates) for a drawn zone (world coords).
    public static func corners(_ zone: Payloads.Zone) -> [MapPoint] {
        [(zone.minX, zone.minY), (zone.maxX, zone.minY), (zone.maxX, zone.maxY), (zone.minX, zone.maxY)]
            .map { MapPoint(x: Double($0.0), y: Double($0.1)) }
    }
}

extension Payloads {
    public static func mapOperation(_ map: RobotMap, _ edits: [MapEdit]) -> [UInt8] {
        mapOperation(map, edits.map(\.operation))
    }
}

extension MapEdit {
    /// Whether the map fetched after the edit shows it: the robot can accept
    /// a request without applying it.
    public func isApplied(before: RobotMap, after: RobotMap) -> Bool {
        switch self {
        case .addNoGoZone: return after.noGoZones.count > before.noGoZones.count
        case .deleteNoGoZone: return after.noGoZones.count < before.noGoZones.count
        case .addWall: return after.virtualWalls.count > before.virtualWalls.count
        case .deleteWall(let wall): return !after.virtualWalls.contains(wall)
        case let .renameRoom(room, name): return after.rooms.first { $0.id == room.id }?.userName == name
        case let .setFloor(room, floor, _): return after.rooms.first { $0.id == room.id }?.floor == floor
        case let .setHeavilySoiled(room, on): return after.rooms.first { $0.id == room.id }?.isHeavilySoiled == on
        case let .setRoomType(room, type): return after.rooms.first { $0.id == room.id }?.roomType == type
        case .rotateMap, .renameMap: return true
        case .mergeRooms: return after.rooms.count < before.rooms.count
        case .splitRoom: return after.rooms.count > before.rooms.count
        case .addCarpet: return after.carpets.count > before.carpets.count
        case .deleteCarpet(let id): return !after.carpets.contains { $0.id == id }
        case let .setWholeRoomCarpet(carpet, on): return after.carpets.first { $0.id == carpet.id }?.isFullRoom == on
        case .addNoCarpetArea: return after.noCarpetAreaIds.count > before.noCarpetAreaIds.count
        case let .retypeFurniture(item, type): return after.furniture.first { $0.id == item.id }?.type == type
        case .deleteFurniture(let item): return !after.furniture.contains { $0.id == item.id }
        }
    }
}

/// Something on the map a tap can pick, for editing.
public enum MapItem: Equatable, Sendable {
    case noGoZone(NoGoZone)
    case wall(VirtualWall)
    case furniture(Furniture)
    case carpet(CarpetArea)
    case room(Room)
}

extension RobotMap {
    /// The item under a point (map coordinates), smallest and most specific
    /// first: walls, no-go zones, furniture, carpets, then the room.
    public func item(at p: MapPoint, tolerance: Double = 3) -> MapItem? {
        if let wall = virtualWalls.first(where: { Self.distance(p, $0.start, $0.end) <= tolerance }) {
            return .wall(wall)
        }
        if let zone = noGoZones.first(where: { Self.contains($0.polygon, p) }) { return .noGoZone(zone) }
        if let item = furniture.first(where: { Self.contains(Self.corners(of: $0), p) }) { return .furniture(item) }
        if let carpet = carpets.first(where: { Self.contains($0.polygon, p) }) { return .carpet(carpet) }
        let g = gridPoint(for: p)
        if let id = roomId(atGridX: Int(g.x), y: Int(g.y)), let room = rooms.first(where: { $0.id == id }) {
            return .room(room)
        }
        return nil
    }

    /// Even-odd ray casting.
    static func contains(_ polygon: [MapPoint], _ p: MapPoint) -> Bool {
        guard polygon.count > 2 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    static func distance(_ p: MapPoint, _ a: MapPoint, _ b: MapPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length2 = dx * dx + dy * dy
        let t = length2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// A furniture box's corners (angle in degrees, counter-clockwise).
    public static func corners(of item: Furniture) -> [MapPoint] {
        let a = item.angle * .pi / 180
        let (c, s) = (cos(a), sin(a))
        let (hw, hh) = (item.width / 2, item.height / 2)
        return [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)].map { dx, dy in
            MapPoint(x: item.center.x + dx * c - dy * s, y: item.center.y + dx * s + dy * c)
        }
    }
}
