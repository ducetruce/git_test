import Foundation

/// The per-device 16-byte secret Zepp OS devices are provisioned with when
/// first paired through the official Zepp app. There is no way around
/// obtaining this: Huami/Zepp devices since the Mi Band Lite generation
/// have the key generated and signed by Huami's servers during that first
/// pairing, not by the watch or a locally-run app — see Gadgetbridge's
/// "Huami/Xiaomi server pairing" documentation. This type only stores and
/// validates a key the user has already extracted from their own paired
/// account; it does not attempt to obtain one.
public struct HuamiAuthKey: Codable, Hashable, Sendable {
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    /// Parses a 32-character hex string (as the key is typically copied
    /// out of the Zepp/Mi Fit app's local database or account export).
    public init?(hexString: String) {
        let cleaned = hexString.replacingOccurrences(of: " ", with: "")
        guard cleaned.count == 32 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes: bytes)
    }
}
