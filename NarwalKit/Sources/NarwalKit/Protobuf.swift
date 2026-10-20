import Foundation

/// Schema-less protobuf codec.
///
/// Narwal publishes no .proto files; every field number in this package comes
/// from community captures (see docs/PROTOCOL-NOTES.md). Decoding therefore
/// keeps raw wire values and lets callers interpret them by field number.

public enum ProtoError: Error, Equatable {
    case truncated
    case malformedVarint
    case unsupportedWireType(Int)
}

public enum ProtoValue: Equatable, Sendable {
    case varint(UInt64)
    case fixed64(UInt64)
    case bytes([UInt8])
    case fixed32(UInt32)
}

public struct ProtoField: Equatable, Sendable {
    public let number: Int
    public let value: ProtoValue
}

public struct ProtoMessage: Equatable, Sendable {
    public let fields: [ProtoField]

    public init(fields: [ProtoField]) {
        self.fields = fields
    }

    public init(bytes: [UInt8]) throws {
        var reader = ProtoReader(bytes: bytes)
        var fields: [ProtoField] = []
        while !reader.isAtEnd {
            fields.append(try reader.readField())
        }
        self.fields = fields
    }

    public init(data: Data) throws {
        try self.init(bytes: [UInt8](data))
    }

    public func all(_ number: Int) -> [ProtoValue] {
        fields.filter { $0.number == number }.map(\.value)
    }

    public func first(_ number: Int) -> ProtoValue? {
        fields.first { $0.number == number }?.value
    }

    public func has(_ number: Int) -> Bool {
        first(number) != nil
    }

    /// Varint as a signed integer (int32/int64/enum/bool fields).
    public func int(_ number: Int) -> Int? {
        switch first(number) {
        case .varint(let v): return Int(truncatingIfNeeded: v)
        case .fixed32(let v): return Int(v)
        case .fixed64(let v): return Int(truncatingIfNeeded: v)
        default: return nil
        }
    }

    /// float32 field. Also accepts a varint carrying the float's bit pattern,
    /// which some captures show for the same field.
    public func float(_ number: Int) -> Float? {
        switch first(number) {
        case .fixed32(let v): return Float(bitPattern: v)
        case .varint(let v): return Float(bitPattern: UInt32(truncatingIfNeeded: v))
        default: return nil
        }
    }

    public func bytes(_ number: Int) -> [UInt8]? {
        if case .bytes(let b) = first(number) { return b }
        return nil
    }

    public func string(_ number: Int) -> String? {
        bytes(number).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A nested message, or nil if the field is absent or not a valid message.
    public func message(_ number: Int) -> ProtoMessage? {
        guard let b = bytes(number) else { return nil }
        return try? ProtoMessage(bytes: b)
    }

    public func messages(_ number: Int) -> [ProtoMessage] {
        all(number).compactMap { value in
            if case .bytes(let b) = value { return try? ProtoMessage(bytes: b) }
            return nil
        }
    }

    /// A repeated varint field, whether sent packed or one value per tag.
    public func varints(_ number: Int) -> [Int] {
        var out: [Int] = []
        for value in all(number) {
            switch value {
            case .varint(let v):
                out.append(Int(truncatingIfNeeded: v))
            case .bytes(let b):
                var reader = ProtoReader(bytes: b)
                while !reader.isAtEnd, let v = try? reader.readVarint() {
                    out.append(Int(truncatingIfNeeded: v))
                }
            default:
                break
            }
        }
        return out
    }
}

public struct ProtoReader {
    private let bytes: [UInt8]
    private(set) var position = 0

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    public var isAtEnd: Bool { position >= bytes.count }

    public mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard position < bytes.count else { throw ProtoError.truncated }
            let byte = bytes[position]
            position += 1
            if shift >= 64 { throw ProtoError.malformedVarint }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func readFixed(_ count: Int) throws -> UInt64 {
        guard position + count <= bytes.count else { throw ProtoError.truncated }
        var result: UInt64 = 0
        for i in 0..<count {
            result |= UInt64(bytes[position + i]) << (8 * UInt64(i))
        }
        position += count
        return result
    }

    mutating func readField() throws -> ProtoField {
        let key = try readVarint()
        let number = Int(key >> 3)
        let wireType = Int(key & 0x7)
        guard number > 0 else { throw ProtoError.malformedVarint }
        switch wireType {
        case 0:
            return ProtoField(number: number, value: .varint(try readVarint()))
        case 1:
            return ProtoField(number: number, value: .fixed64(try readFixed(8)))
        case 2:
            let length = try readVarint()
            guard length <= UInt64(bytes.count - position) else { throw ProtoError.truncated }
            let end = position + Int(length)
            let slice = Array(bytes[position..<end])
            position = end
            return ProtoField(number: number, value: .bytes(slice))
        case 5:
            return ProtoField(number: number, value: .fixed32(UInt32(try readFixed(4))))
        default:
            throw ProtoError.unsupportedWireType(wireType)
        }
    }
}

/// Builds a protobuf message field by field, in call order.
public struct ProtoWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public static func encodeVarint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        while v > 0x7F {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    public mutating func varint(_ number: Int, _ value: Int) {
        bytes += Self.encodeVarint(UInt64(number << 3))
        bytes += Self.encodeVarint(UInt64(bitPattern: Int64(value)))
    }

    /// A float32 (fixed32) field, as used by `Point`.
    public mutating func float(_ number: Int, _ value: Float) {
        bytes += Self.encodeVarint(UInt64(number << 3 | 5))
        let bits = value.bitPattern
        bytes += [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24)]
    }

    public mutating func bytesField(_ number: Int, _ data: [UInt8]) {
        bytes += Self.encodeVarint(UInt64(number << 3 | 2))
        bytes += Self.encodeVarint(UInt64(data.count))
        bytes += data
    }

    public mutating func string(_ number: Int, _ text: String) {
        bytesField(number, Array(text.utf8))
    }

    public mutating func message(_ number: Int, _ build: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        build(&inner)
        bytesField(number, inner.bytes)
    }
}
