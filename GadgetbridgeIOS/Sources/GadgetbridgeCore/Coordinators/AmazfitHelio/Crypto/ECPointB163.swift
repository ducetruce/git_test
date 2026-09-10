import Foundation

/// A point on the NIST B-163 binary elliptic curve (`sect163r2`):
/// `y^2 + xy = x^3 + a*x^2 + b` over GF(2^163), with `a = 1` for all NIST
/// "B" curves.
struct ECPointB163: Equatable {
    var x: GF2m163
    var y: GF2m163
    var isInfinity: Bool

    static let infinity = ECPointB163(x: .zero, y: .zero, isInfinity: true)

    static func == (lhs: ECPointB163, rhs: ECPointB163) -> Bool {
        if lhs.isInfinity || rhs.isInfinity { return lhs.isInfinity == rhs.isInfinity }
        return lhs.x == rhs.x && lhs.y == rhs.y
    }

    /// In characteristic 2, `-P = (x, x+y)`.
    func negated() -> ECPointB163 {
        isInfinity ? self : ECPointB163(x: x, y: x + y, isInfinity: false)
    }

    func doubled() -> ECPointB163 {
        guard !isInfinity, !x.isZero else { return .infinity }
        let lambda = x + (y / x)
        let x3 = lambda.squared() + lambda + CurveB163.a
        let y3 = x.squared() + (lambda + .one) * x3
        return ECPointB163(x: x3, y: y3, isInfinity: false)
    }

    func adding(_ other: ECPointB163) -> ECPointB163 {
        if isInfinity { return other }
        if other.isInfinity { return self }
        if x == other.x {
            // Either the same point (use doubling) or its negation (sum to infinity).
            return y == other.y ? doubled() : .infinity
        }
        let lambda = (y + other.y) / (x + other.x)
        let x3 = lambda.squared() + lambda + x + other.x + CurveB163.a
        let y3 = lambda * (x + x3) + x3 + y
        return ECPointB163(x: x3, y: y3, isInfinity: false)
    }

    /// Left-to-right double-and-add scalar multiplication over a big-endian
    /// scalar. This is **not constant-time**: execution time leaks the
    /// scalar's Hamming weight/bit pattern through branch timing. That's an
    /// acceptable trade-off for a one-off local BLE pairing handshake
    /// (there's no remote attacker positioned to measure timing here), but
    /// this type should not be reused as a general-purpose crypto primitive
    /// without hardening.
    func multiplied(by scalar: [UInt8]) -> ECPointB163 {
        var result = ECPointB163.infinity
        for byte in scalar {
            for bitIndex in stride(from: 7, through: 0, by: -1) {
                result = result.doubled()
                if (byte >> bitIndex) & 1 == 1 {
                    result = result.adding(self)
                }
            }
        }
        return result
    }
}

/// Domain parameters for `sect163r2` / NIST B-163, cross-referenced against
/// SEC 2 ("Recommended Elliptic Curve Domain Parameters") and NIST SP
/// 800-186 during development. **Caveat:** this sandbox's network egress
/// blocked direct access to secg.org, NIST, and the neuromancer.sk curve
/// database while building this, so `a`, `b`, and the generator point below
/// were reconstructed from search-result excerpts of those standards
/// (cross-checked across two independent searches) rather than fetched
/// directly from a primary source. Verify against an authoritative
/// reference before relying on this for anything beyond experimentation.
enum CurveB163 {
    /// `a = 1` for every NIST "B" curve (as opposed to the "K" Koblitz
    /// curves, which use `a = 0`).
    static let a = GF2m163.one

    static let b = GF2m163(bigEndianBytes: [
        0x02, 0x0A, 0x60, 0x19, 0x07, 0xB8, 0xC9, 0x53, 0xCA, 0x14, 0x81,
        0xEB, 0x10, 0x51, 0x2F, 0x78, 0x74, 0x4A, 0x32, 0x05, 0xFD,
    ])

    static let generator = ECPointB163(
        x: GF2m163(bigEndianBytes: [
            0x03, 0xF0, 0xEB, 0xA1, 0x62, 0x86, 0xA2, 0xD5, 0x7E, 0xA0, 0x99,
            0x11, 0x68, 0xD4, 0x99, 0x46, 0x37, 0xE8, 0x34, 0x3E, 0x36,
        ]),
        y: GF2m163(bigEndianBytes: [
            0x00, 0xD5, 0x1F, 0xBC, 0x6C, 0x71, 0xA0, 0x09, 0x4F, 0xA2, 0xCD,
            0xD5, 0x45, 0xB1, 0x1C, 0x5C, 0x0C, 0x79, 0x73, 0x24, 0xF1,
        ]),
        isInfinity: false
    )

    /// The base point's order is approximately 2^162 with cofactor 2. The
    /// exact 41-hex-digit value could not be reliably transcribed from the
    /// sources available in this environment (a single wrong digit in a
    /// value this long is easy to introduce and hard to notice), so it is
    /// deliberately **not** hardcoded here and nothing in this codebase
    /// depends on it — private scalars are used as raw random 163-bit
    /// values rather than reduced mod the order (harmless for correctness,
    /// see `ECDHB163.generateKeyPair`). Confirm the exact order against
    /// NIST SP 800-186 / SEC 2 v1.0 (`sect163r2`) before using this for
    /// anything where that distinction matters.
    static let cofactor = 2
}
