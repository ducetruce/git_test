import Foundation

/// Tools for decoding features nobody has mapped yet, from an iPhone alone:
/// snapshot what the robot reports, change one setting in the Narwal app,
/// snapshot again, and diff.
public enum Research {
    /// Query topics believed to be read-only. Deliberately excludes
    /// developer/get_robot_info, which returns the Wi-Fi password in clear text.
    public static let probeTopics: [String] = [
        "config/get",
        "schedule/clean_schedule/get",
        "clean/current_clean_task/get",
        "info/get_clean_time_line",
        "common/get_feature_list",
        "common/get_device_info",
        "status/get_device_base_status",
        "consumable/get_consumable_info",
        "config/key_mapping/get",
        "info/battery_info",
    ]

    /// Topics never sent from the lab: their answers include secrets.
    public static let blockedTopics: Set<String> = ["developer/get_robot_info"]

    /// Custom lab topics must look like queries, so the lab can't send a
    /// command that changes the robot.
    public static func isSafeQuery(_ topic: String) -> Bool {
        guard !blockedTopics.contains(topic), let last = topic.split(separator: "/").last else { return false }
        return last.contains("get") || last.hasSuffix("info")
    }

    /// One leaf of a decoded message, e.g. `2.12[1].3 = "Kitchen"`.
    public struct Leaf: Equatable, Sendable, Hashable, Codable {
        public let path: String
        public let value: String
    }

    /// Flattens a message into leaves. Length-delimited fields are shown as
    /// text when printable, as nested messages when they parse, else as hex.
    public static func flatten(_ message: ProtoMessage, prefix: String = "", depth: Int = 0) -> [Leaf] {
        var counts: [Int: Int] = [:]
        for field in message.fields { counts[field.number, default: 0] += 1 }
        var seen: [Int: Int] = [:]
        var out: [Leaf] = []
        for field in message.fields {
            let index = seen[field.number, default: 0]
            seen[field.number] = index + 1
            var path = prefix.isEmpty ? "\(field.number)" : "\(prefix).\(field.number)"
            if counts[field.number, default: 0] > 1 { path += "[\(index)]" }
            out += leaves(field.value, path: path, depth: depth)
        }
        return out
    }

    private static func leaves(_ value: ProtoValue, path: String, depth: Int) -> [Leaf] {
        switch value {
        case .varint(let v):
            return [Leaf(path: path, value: "\(Int64(bitPattern: v))")]
        case .fixed32(let v):
            let f = Float(bitPattern: v)
            let shown = f.isFinite && abs(f) < 1e9 && (f == 0 || abs(f) > 1e-6) ? "\(f)f" : "0x\(String(v, radix: 16))"
            return [Leaf(path: path, value: shown)]
        case .fixed64(let v):
            return [Leaf(path: path, value: "\(Double(bitPattern: v))d")]
        case .bytes(let b):
            if b.isEmpty { return [Leaf(path: path, value: "{}")] }
            if let text = printable(b) { return [Leaf(path: path, value: "\"\(text)\"")] }
            if depth < 12, let nested = try? ProtoMessage(bytes: b), plausible(nested) {
                return flatten(nested, prefix: path, depth: depth + 1)
            }
            let hex = b.prefix(64).map { String(format: "%02x", $0) }.joined()
            return [Leaf(path: path, value: "0x\(hex)\(b.count > 64 ? "… (\(b.count) bytes)" : "")")]
        }
    }

    private static func printable(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 2, let s = String(bytes: bytes, encoding: .utf8) else { return nil }
        let ok = s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F || $0 == "\n" }
        return ok ? s : nil
    }

    private static func plausible(_ m: ProtoMessage) -> Bool {
        !m.fields.isEmpty && m.fields.allSatisfy { $0.number < 1000 }
    }

    public struct Change: Equatable, Sendable, Hashable, Codable {
        public let path: String
        public let before: String?
        public let after: String?
    }

    /// Leaves that were added, removed or changed between two snapshots.
    public static func diff(_ before: [Leaf], _ after: [Leaf]) -> [Change] {
        let a = Dictionary(before.map { ($0.path, $0.value) }, uniquingKeysWith: { first, _ in first })
        let b = Dictionary(after.map { ($0.path, $0.value) }, uniquingKeysWith: { first, _ in first })
        return Set(a.keys).union(b.keys).sorted(by: pathOrder).compactMap { path in
            a[path] == b[path] ? nil : Change(path: path, before: a[path], after: b[path])
        }
    }

    /// Numeric-aware ordering: 2 < 10, 12[1] < 12[2].
    static func pathOrder(_ l: String, _ r: String) -> Bool {
        let ln = l.split(whereSeparator: { ".[]".contains($0) }).map { Int($0) ?? 0 }
        let rn = r.split(whereSeparator: { ".[]".contains($0) }).map { Int($0) ?? 0 }
        return ln.lexicographicallyPrecedes(rn)
    }
}
