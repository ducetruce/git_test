import Foundation

/// An element of GF(2^163), the binary extension field NIST curve B-163
/// (aka `sect163r2`) is defined over. Zepp OS devices (including the
/// Amazfit Helio Strap) use this curve for their device-pairing key
/// exchange — notably *not* one of the prime-field curves (P-256, P-384,
/// Curve25519) that `CryptoKit`/`Security.framework` support, which is why
/// this field arithmetic has to be implemented from scratch here, the same
/// way Gadgetbridge's own developers had to port a small C library
/// (`kokke/tiny-ECDH-c`, public domain) rather than use a system crypto API.
///
/// Reduction polynomial (from the NIST/SEC2 domain parameters for
/// `sect163r2`): f(x) = x^163 + x^7 + x^6 + x^3 + 1.
struct GF2m163: Equatable {
    static let bitWidth = 163
    static let limbCount = 3 // 3 * 64 = 192 bits of storage for a 163-bit value

    /// f(x) as a bit pattern: bits {163, 7, 6, 3, 0} set.
    static let reductionPolynomial: [UInt64] = {
        var limbs = [UInt64](repeating: 0, count: 3)
        for bit in [163, 7, 6, 3, 0] {
            limbs[bit / 64] |= 1 << UInt64(bit % 64)
        }
        return limbs
    }()

    static let zero = GF2m163(limbs: [0, 0, 0])
    static let one = GF2m163(limbs: [1, 0, 0])

    /// Little-endian limbs, always exactly `limbCount` long, masked to
    /// `bitWidth` bits.
    private(set) var limbs: [UInt64]

    init(limbs: [UInt64]) {
        var padded = limbs
        while padded.count < Self.limbCount { padded.append(0) }
        padded[2] &= 0x0000_0007_FFFF_FFFF // keep only the low 35 bits (128 + 35 = 163)
        self.limbs = Array(padded.prefix(Self.limbCount))
    }

    /// Parses a big-endian byte array (as used on the wire) into a field
    /// element. Accepts any length up to 21 bytes (168 bits, enough for 163).
    init(bigEndianBytes bytes: [UInt8]) {
        var limbs = [UInt64](repeating: 0, count: Self.limbCount)
        for (index, byte) in bytes.reversed().enumerated() {
            let bitOffset = index * 8
            limbs[bitOffset / 64] |= UInt64(byte) << UInt64(bitOffset % 64)
        }
        self.init(limbs: limbs)
    }

    /// Serializes to a fixed-width 24-byte (192-bit) big-endian array,
    /// matching the coordinate width Gadgetbridge's Zepp OS auth uses on
    /// the wire for this curve.
    func bigEndianBytes(width: Int = 24) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width)
        for i in 0..<width {
            let bitOffset = i * 8
            let word = bitOffset / 64
            guard word < limbs.count else { continue }
            bytes[width - 1 - i] = UInt8((limbs[word] >> UInt64(bitOffset % 64)) & 0xFF)
        }
        return bytes
    }

    var isZero: Bool { BinaryPolynomial.isZero(limbs) }

    static func + (a: GF2m163, b: GF2m163) -> GF2m163 {
        GF2m163(limbs: BinaryPolynomial.xor(a.limbs, b.limbs))
    }

    static func * (a: GF2m163, b: GF2m163) -> GF2m163 {
        let wide = BinaryPolynomial.multiply(a.limbs, b.limbs)
        let (_, remainder) = BinaryPolynomial.divide(wide, by: reductionPolynomial)
        return GF2m163(limbs: remainder)
    }

    func squared() -> GF2m163 { self * self }

    /// Multiplicative inverse via the extended Euclidean algorithm. `self`
    /// must be nonzero.
    func inverted() -> GF2m163 {
        precondition(!isZero, "cannot invert zero in GF(2^163)")
        return GF2m163(limbs: BinaryPolynomial.inverse(limbs, modulo: Self.reductionPolynomial))
    }

    static func / (a: GF2m163, b: GF2m163) -> GF2m163 {
        a * b.inverted()
    }
}
