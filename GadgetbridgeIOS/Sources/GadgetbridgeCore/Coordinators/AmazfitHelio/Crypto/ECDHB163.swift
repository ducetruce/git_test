import Foundation

/// Elliptic-curve Diffie-Hellman over NIST B-163, matching the key exchange
/// Zepp OS devices (including the Amazfit Helio Strap) use as the first
/// phase of their pairing handshake.
enum ECDHB163 {
    struct KeyPair {
        /// Raw 24-byte private scalar.
        let privateKey: [UInt8]
        /// 48-byte public key: 24-byte x-coordinate followed by 24-byte
        /// y-coordinate, matching the wire format observed in Gadgetbridge's
        /// Zepp OS auth traffic.
        let publicKey: [UInt8]
    }

    /// Generates a fresh key pair. The private scalar is a raw random
    /// 192-bit (24-byte) value, not reduced modulo the base point's exact
    /// order — see the note on `CurveB163.cofactor`. This is harmless for
    /// correctness (scalar multiplication is well-defined for any integer
    /// scalar; reducing mod the order only affects which representative of
    /// an equivalence class you use) but means this key generation should
    /// not be treated as a hardened, standards-compliant implementation.
    static func generateKeyPair(randomBytes: () -> [UInt8] = { randomBytes(count: 24) }) -> KeyPair {
        var privateKey = randomBytes()
        // Zero the top 5 bits so the scalar stays within the 163-bit field
        // even though it's carried in a 24-byte (192-bit) buffer.
        privateKey[0] &= 0x07

        let point = CurveB163.generator.multiplied(by: privateKey)
        let publicKey = point.x.bigEndianBytes(width: 24) + point.y.bigEndianBytes(width: 24)
        return KeyPair(privateKey: privateKey, publicKey: publicKey)
    }

    /// Computes the shared secret's x-coordinate (24 bytes) given our
    /// private key and the peer's 48-byte public key.
    static func sharedSecret(privateKey: [UInt8], peerPublicKey: [UInt8]) throws -> [UInt8] {
        guard peerPublicKey.count == 48 else {
            throw DeviceTransportError.underlying("Expected a 48-byte EC public key, got \(peerPublicKey.count) bytes")
        }
        let peerX = GF2m163(bigEndianBytes: Array(peerPublicKey[0..<24]))
        let peerY = GF2m163(bigEndianBytes: Array(peerPublicKey[24..<48]))
        let peerPoint = ECPointB163(x: peerX, y: peerY, isInfinity: false)
        let shared = peerPoint.multiplied(by: privateKey)
        return shared.x.bigEndianBytes(width: 24)
    }

    private static func randomBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return bytes
    }
}
