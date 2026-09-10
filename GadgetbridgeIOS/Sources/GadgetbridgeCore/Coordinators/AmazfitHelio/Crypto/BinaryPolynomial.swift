import Foundation

/// Arithmetic on polynomials over GF(2), represented as little-endian
/// arrays of 64-bit limbs (limb 0 holds bits 0...63, limb 1 holds bits
/// 64...127, etc). A "1" bit at position `i` means the polynomial has a
/// term `x^i`. Addition in GF(2) is XOR, so these are pure bitwise
/// operations — no carries.
///
/// This is the generic building block `GF2m163` (the NIST B-163 field used
/// by Amazfit/Zepp OS's device-auth handshake) is built on. It exists as
/// its own type because computing a modular inverse needs the extended
/// Euclidean algorithm, which operates on polynomials of varying degree
/// (not just fixed-width field elements).
enum BinaryPolynomial {
    static func degree(of limbs: [UInt64]) -> Int? {
        for word in stride(from: limbs.count - 1, through: 0, by: -1) where limbs[word] != 0 {
            return word * 64 + (63 - limbs[word].leadingZeroBitCount)
        }
        return nil
    }

    static func isZero(_ limbs: [UInt64]) -> Bool {
        limbs.allSatisfy { $0 == 0 }
    }

    static func xor(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        let count = max(a.count, b.count)
        var result = [UInt64](repeating: 0, count: count)
        for i in 0..<count {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            result[i] = av ^ bv
        }
        return result
    }

    /// XORs `src` (shifted left by `shift` bits) into `dest`, growing `dest`
    /// if needed so no bits are lost.
    static func xorShifted(_ dest: inout [UInt64], _ src: [UInt64], by shift: Int) {
        let wordShift = shift / 64
        let bitShift = shift % 64
        let requiredCount = src.count + wordShift + 1
        if dest.count < requiredCount {
            dest.append(contentsOf: repeatElement(0, count: requiredCount - dest.count))
        }
        for (index, word) in src.enumerated() where word != 0 {
            let destIndex = index + wordShift
            if bitShift == 0 {
                dest[destIndex] ^= word
            } else {
                dest[destIndex] ^= word << bitShift
                dest[destIndex + 1] ^= word >> (64 - bitShift)
            }
        }
    }

    static func shiftLeft(_ limbs: [UInt64], by shift: Int) -> [UInt64] {
        var result = [UInt64](repeating: 0, count: limbs.count + shift / 64 + 1)
        xorShifted(&result, limbs, by: shift)
        return result
    }

    /// Multiplies two GF(2)[x] polynomials ("carry-less multiply"). The
    /// result is unreduced and may have degree up to
    /// `degree(a) + degree(b)`.
    static func multiply(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        guard let bDegree = degree(of: b) else { return [0] }
        var result = [UInt64](repeating: 0, count: a.count + b.count + 1)
        for bit in 0...bDegree where (b[bit / 64] >> UInt64(bit % 64)) & 1 == 1 {
            xorShifted(&result, a, by: bit)
        }
        return result
    }

    /// Polynomial long division over GF(2): returns (quotient, remainder)
    /// such that `numerator == quotient*denominator XOR remainder` and
    /// `degree(remainder) < degree(denominator)`.
    static func divide(_ numerator: [UInt64], by denominator: [UInt64]) -> (quotient: [UInt64], remainder: [UInt64]) {
        guard let denominatorDegree = degree(of: denominator) else {
            preconditionFailure("division by zero polynomial")
        }
        var remainder = numerator
        var quotient = [UInt64](repeating: 0, count: numerator.count)
        while let remainderDegree = degree(of: remainder), remainderDegree >= denominatorDegree {
            let shift = remainderDegree - denominatorDegree
            xorShifted(&remainder, denominator, by: shift)
            let wordShift = shift / 64
            if wordShift >= quotient.count {
                quotient.append(contentsOf: repeatElement(0, count: wordShift - quotient.count + 1))
            }
            quotient[wordShift] ^= 1 << UInt64(shift % 64)
        }
        return (quotient, remainder)
    }

    /// Extended Euclidean algorithm: finds `inverse` such that
    /// `(a * inverse) mod modulus == 1`, given `modulus` is irreducible
    /// (so gcd(a, modulus) == 1 for any nonzero a of lower degree).
    static func inverse(_ a: [UInt64], modulo modulus: [UInt64]) -> [UInt64] {
        var r0 = modulus, r1 = a
        var s0: [UInt64] = [0], s1: [UInt64] = [1]

        while !isZero(r1) {
            let (q, r2) = divide(r0, by: r1)
            let s2 = xor(s0, multiply(q, s1))
            r0 = r1; r1 = r2
            s0 = s1; s1 = s2
        }
        // r0 is now gcd(a, modulus), which must be 1 (the constant
        // polynomial) for an irreducible modulus and nonzero a.
        return s0
    }
}
