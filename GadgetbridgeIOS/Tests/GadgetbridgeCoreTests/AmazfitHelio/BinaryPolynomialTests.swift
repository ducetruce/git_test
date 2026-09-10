import XCTest
@testable import GadgetbridgeCore

final class BinaryPolynomialTests: XCTestCase {
    func testDegreeOfZeroIsNil() {
        XCTAssertNil(BinaryPolynomial.degree(of: [0, 0, 0]))
    }

    func testDegreeFindsHighestSetBitAcrossLimbs() {
        // Bit 65 is the second bit of the second 64-bit limb.
        XCTAssertEqual(BinaryPolynomial.degree(of: [0, 0b10, 0]), 65)
    }

    func testMultiplyByOneIsIdentity() {
        let a: [UInt64] = [0x1234_5678, 0, 0]
        let product = BinaryPolynomial.multiply(a, [1])
        XCTAssertEqual(BinaryPolynomial.degree(of: product), BinaryPolynomial.degree(of: a))
        XCTAssertEqual(product[0], a[0])
    }

    func testDivideRecoversNumeratorViaQuotientAndRemainder() {
        // (x^3 + x + 1) / (x + 1): verify numerator == quotient*denominator XOR remainder.
        let numerator: [UInt64] = [0b1011]
        let denominator: [UInt64] = [0b11]
        let (quotient, remainder) = BinaryPolynomial.divide(numerator, by: denominator)
        let reconstructed = BinaryPolynomial.xor(BinaryPolynomial.multiply(quotient, denominator), remainder)
        XCTAssertEqual(reconstructed[0] & 0xF, numerator[0] & 0xF)
        XCTAssertTrue((BinaryPolynomial.degree(of: remainder) ?? -1) < (BinaryPolynomial.degree(of: denominator) ?? 0))
    }

    func testInverseSatisfiesMultiplicativeIdentity() {
        // Use the NIST B-163 reduction polynomial as the modulus, matching
        // how GF2m163 uses this function.
        let modulus = GF2m163.reductionPolynomial
        let a: [UInt64] = [0xABCDEF0123456789, 0x1, 0]
        let inverse = BinaryPolynomial.inverse(a, modulo: modulus)
        let product = BinaryPolynomial.multiply(a, inverse)
        let (_, remainder) = BinaryPolynomial.divide(product, by: modulus)
        // a * a^-1 mod modulus should be the constant polynomial 1.
        XCTAssertEqual(BinaryPolynomial.degree(of: remainder), 0)
    }
}
