import Foundation
#if canImport(Compression)
import Compression
#endif

public struct Room: Equatable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var userName: String
    public var roomType: Int
    public var category: Int
    public var instanceIndex: Int

    /// The user's name, else the app's room-type name, numbered for duplicates.
    public var displayName: String {
        if !userName.isEmpty { return userName }
        let base = RoomType.names[roomType] ?? "Room"
        return instanceIndex > 1 ? "\(base) \(instanceIndex)" : base
    }
}

/// One map pixel. Values are `roomId << 8 | type`.
public enum MapPixel: Equatable, Sendable {
    case unknown
    case floor(room: Int)
    case wall(room: Int)
    case unassignedFloor
    case unassignedObstacle

    public init(raw: UInt32) {
        switch raw {
        case 0: self = .unknown
        case 0x20: self = .unassignedFloor
        case 0x28: self = .unassignedObstacle
        default:
            let room = Int(raw >> 8)
            self = raw & 0x10 != 0 ? .wall(room: room) : .floor(room: room)
        }
    }
}

/// The saved house map from map/get_map.
public struct RobotMap: Equatable, Sendable {
    public var mapId: Int
    public var width: Int
    public var height: Int
    /// Millimetres per pixel.
    public var resolution: Int
    public var rooms: [Room]
    public var originX: Int
    public var originY: Int
    /// Dock position in grid coordinates (y up).
    public var dock: MapPoint?
    /// Row-major pixels, row 0 at the BOTTOM (map y grows upward).
    public var pixels: [UInt32]
    /// StaticMapPayload field 9, in map coordinates (see `gridPoint(for:)`).
    public var noGoZones: [NoGoZone] = []
    /// StaticMapPayload field 50, in map coordinates.
    public var virtualWalls: [VirtualWall] = []

    public enum ParseError: Error {
        case noActiveMap
    }

    /// Parses the field-2 map payload of a get_map response.
    public init(response: ProtoMessage) throws {
        guard let map = response.message(2), let id = map.int(1), id != 0 else {
            throw ParseError.noActiveMap
        }
        mapId = id
        resolution = map.int(3) ?? 0
        width = map.int(4) ?? 0
        height = map.int(5) ?? 0
        let transform = map.message(6)
        originY = transform?.int(1) ?? 0
        originX = transform?.int(3) ?? 0

        rooms = map.messages(12).compactMap { r in
            guard let id = r.int(1), id > 0 else { return nil }
            return Room(
                id: id, userName: r.string(3) ?? "", roomType: r.int(2) ?? 0,
                category: r.int(4) ?? 0, instanceIndex: r.int(8) ?? 0
            )
        }

        if let pos = map.message(8)?.message(1), let x = pos.float(1), let y = pos.float(2),
           x.isFinite, y.isFinite {
            dock = MapPoint(x: Double(x) - Double(originX), y: Double(y) - Double(originY))
        } else {
            dock = nil
        }

        noGoZones = map.messages(9).map(NoGoZone.init)
        virtualWalls = map.messages(50).map(VirtualWall.init)

        let count = width * height
        var decoded = Self.decodePixels(Self.inflate(map.bytes(17) ?? []))
        if decoded.count < count {
            decoded += Array(repeating: 0, count: count - decoded.count)
        }
        pixels = Array(decoded.prefix(count))
    }

    public init(mapId: Int, width: Int, height: Int, resolution: Int, rooms: [Room],
                originX: Int = 0, originY: Int = 0, dock: MapPoint? = nil, pixels: [UInt32]) {
        self.mapId = mapId
        self.width = width
        self.height = height
        self.resolution = resolution
        self.rooms = rooms
        self.originX = originX
        self.originY = originY
        self.dock = dock
        self.pixels = pixels
    }

    public func pixel(x: Int, y: Int) -> MapPixel {
        guard x >= 0, y >= 0, x < width, y < height else { return .unknown }
        return MapPixel(raw: pixels[y * width + x])
    }

    /// The room under a grid point (y up), or nil.
    public func roomId(atGridX x: Int, y: Int) -> Int? {
        switch pixel(x: x, y: y) {
        case .floor(let room), .wall(let room): return room > 0 ? room : nil
        default: return nil
        }
    }

    /// Live/display coordinates -> grid coordinates.
    public func gridPoint(for p: MapPoint) -> MapPoint {
        MapPoint(x: p.x - Double(originX), y: p.y - Double(originY))
    }

    /// Mean floor-pixel position per room, for labels (grid coords, y up).
    public func roomCentroids() -> [Int: MapPoint] {
        var sums: [Int: (x: Int, y: Int, n: Int)] = [:]
        for y in 0..<height {
            for x in 0..<width {
                if case .floor(let room) = MapPixel(raw: pixels[y * width + x]), room > 0 {
                    let s = sums[room] ?? (0, 0, 0)
                    sums[room] = (s.x + x, s.y + y, s.n + 1)
                }
            }
        }
        return sums.mapValues { MapPoint(x: Double($0.x) / Double($0.n), y: Double($0.y) / Double($0.n)) }
    }

    /// The grid is a zlib stream holding a protobuf packed varint field.
    static func decodePixels(_ data: [UInt8]) -> [UInt32] {
        var pos = 0
        if data.first == 0x0A {
            pos = 1
            while pos < data.count, data[pos] & 0x80 != 0 { pos += 1 }
            pos += 1
        }
        var out: [UInt32] = []
        out.reserveCapacity(data.count)
        while pos < data.count {
            var value: UInt32 = 0
            var shift: UInt32 = 0
            while pos < data.count {
                let b = data[pos]
                pos += 1
                if shift < 32 { value |= UInt32(b & 0x7F) << shift }
                shift += 7
                if b & 0x80 == 0 { break }
            }
            out.append(value)
        }
        return out
    }

    /// zlib (78 xx header) -> raw bytes. Apple's ZLIB codec is raw DEFLATE,
    /// so the two-byte header is stripped first.
    static func inflate(_ data: [UInt8]) -> [UInt8] {
        guard data.count > 2 else { return data }
        #if canImport(Compression)
        let hasZlibHeader = data[0] & 0x0F == 8 && (UInt16(data[0]) << 8 | UInt16(data[1])) % 31 == 0
        let body = hasZlibHeader ? Array(data[2...]) : data
        return rawInflate(body) ?? data
        #else
        return data
        #endif
    }

    #if canImport(Compression)
    /// Streaming decode, which stops at the end of the DEFLATE stream and so
    /// ignores the trailing zlib checksum.
    static func rawInflate(_ input: [UInt8]) -> [UInt8]? {
        let chunk = 64 * 1024
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }

        var output: [UInt8] = []
        var status = COMPRESSION_STATUS_OK
        input.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = src.count
            repeat {
                stream.pointee.dst_ptr = dst
                stream.pointee.dst_size = chunk
                status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(contentsOf: UnsafeBufferPointer(start: dst, count: chunk - stream.pointee.dst_size))
            } while status == COMPRESSION_STATUS_OK
        }
        return status == COMPRESSION_STATUS_END ? output : nil
    }
    #endif
}
