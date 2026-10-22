import Foundation

/// An obstacle the robot's camera recognised: StaticMapPayload 32
/// VisionData {2 visionObs: VisionObs {1 id, 2 label, 3 box, 4 taskId}}.
public struct VisionObstacle: Equatable, Sendable, Identifiable {
    public var id: Int
    public var label: Int
    /// Map coordinates, like furniture.
    public var center: MapPoint
    public var width: Double
    public var height: Double
    public var taskId: Int

    public var name: String { Self.names[label] ?? "Obstacle" }

    /// VisionObsLabel (docs/schema/enums.txt).
    public static let names: [Int: String] = [
        1: "Cable", 2: "Tissue", 3: "Pet mess", 4: "Liquid", 5: "Shoes", 6: "Object", 7: "Socks",
        8: "Plastic bag", 9: "Trash can", 11: "Can't clean here", 12: "Fabric", 15: "Pet",
        16: "Drop-off", 17: "Squat toilet", 18: "Chair legs", 19: "Chair wheels", 20: "Floor mirror",
        21: "Book", 22: "Stick", 24: "Jewellery", 25: "Phone", 26: "Wallet", 27: "Key", 28: "Money",
        29: "Remote", 30: "Glasses", 31: "Watch", 32: "Card", 33: "Headphones", 34: "Baby toy",
        35: "Plant", 36: "Fitness equipment", 37: "Pet toy", 38: "Hazard", 39: "Decoration",
        40: "Box", 41: "Cat", 42: "Dog",
    ]
}

extension VisionObstacle {
    init(_ m: ProtoMessage) {
        id = m.int(1) ?? 0
        label = m.int(2) ?? 0
        let box = m.message(3)
        center = box?.message(1).map(MapCoordinates.point) ?? MapPoint(x: 0, y: 0)
        width = Double(box?.float(2) ?? 0)
        height = Double(box?.float(3) ?? 0)
        taskId = m.int(4) ?? 0
    }
}

extension Payloads {
    /// map/get_vision_image: GetVisionImage.Request {1 type = IMAGE_TYPE_OBS, 2 id}.
    public static func obstaclePhoto(_ id: Int) -> [UInt8] {
        var w = ProtoWriter()
        w.varint(1, 1)
        w.varint(2, id)
        return w.bytes
    }
}

/// GetVisionImage.Response {1 result, 2 originImage, 3 url, ...}: the photo
/// when the robot sends it inline. A URL alone points at Narwal's cloud and
/// isn't fetched.
public enum ObstaclePhoto {
    public static func imageData(_ m: ProtoMessage) -> Data? {
        guard let bytes = m.bytes(2), bytes.count > 64 else { return nil }
        return Data(bytes)
    }
}
