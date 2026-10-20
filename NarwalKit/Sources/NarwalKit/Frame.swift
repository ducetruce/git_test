import Foundation

/// One WebSocket binary frame.
///
///     byte 0   0x01                frame type
///     byte 1   len(topic) + 2      length of the field-4 TLV wrapping the topic
///     byte 2   0x22 | 0x2a         0x22 = request/broadcast, 0x2a = command response
///     byte 3   len(topic)
///     4...     topic (UTF-8)       empty on responses
///     rest     protobuf payload
///
/// A wrong header byte makes the robot drop the socket without an error.
public struct NarwalFrame: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case message = 0x22
        case response = 0x2A
    }

    public static let frameTypeByte: UInt8 = 0x01

    public let kind: Kind
    public let topic: String
    public let payload: [UInt8]

    public init(kind: Kind = .message, topic: String, payload: [UInt8] = []) {
        self.kind = kind
        self.topic = topic
        self.payload = payload
    }

    /// `/{productKey}/{deviceId}/status/working_status` -> `status/working_status`.
    public var shortTopic: String {
        let parts = topic.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return topic }
        return parts[3...].joined(separator: "/")
    }

    /// The device id embedded in a broadcast topic, if any.
    public var topicDeviceId: String? {
        let parts = topic.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 4, !parts[2].isEmpty else { return nil }
        return String(parts[2])
    }

    public var topicProductKey: String? {
        let parts = topic.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 4, !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    public enum ParseError: Error, Equatable {
        case tooShort
        case badFrameType(UInt8)
        case badKind(UInt8)
        case truncatedTopic
    }

    public init(bytes: [UInt8]) throws {
        guard bytes.count >= 4 else { throw ParseError.tooShort }
        guard bytes[0] == Self.frameTypeByte else { throw ParseError.badFrameType(bytes[0]) }
        guard let kind = Kind(rawValue: bytes[2]) else { throw ParseError.badKind(bytes[2]) }
        let topicLength = Int(bytes[3])
        let topicEnd = 4 + topicLength
        guard bytes.count >= topicEnd else { throw ParseError.truncatedTopic }
        self.kind = kind
        self.topic = String(decoding: bytes[4..<topicEnd], as: UTF8.self)
        self.payload = Array(bytes[topicEnd...])
    }

    public func encoded() -> [UInt8] {
        let topicBytes = Array(topic.utf8)
        precondition(topicBytes.count <= 253, "topic too long for a one-byte length")
        return [Self.frameTypeByte, UInt8(topicBytes.count + 2), kind.rawValue, UInt8(topicBytes.count)]
            + topicBytes + payload
    }
}
