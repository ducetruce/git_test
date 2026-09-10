import XCTest
@testable import GadgetbridgeCore

final class ECDHB163Tests: XCTestCase {
    /// The strongest correctness check available without a real device or
    /// official NIST test vectors (both were unreachable in this
    /// environment — see `AmazfitHelioSession`'s doc comment): if the
    /// field arithmetic, point arithmetic, and domain parameters are all
    /// internally consistent, two independently generated key pairs must
    /// agree on the same shared secret from both sides.
    func testBothSidesOfECDHAgreeOnSharedSecret() throws {
        let alice = ECDHB163.generateKeyPair()
        let bob = ECDHB163.generateKeyPair()

        let aliceSharedSecret = try ECDHB163.sharedSecret(privateKey: alice.privateKey, peerPublicKey: bob.publicKey)
        let bobSharedSecret = try ECDHB163.sharedSecret(privateKey: bob.privateKey, peerPublicKey: alice.publicKey)

        XCTAssertEqual(aliceSharedSecret, bobSharedSecret)
        XCTAssertEqual(aliceSharedSecret.count, 24)
    }

    func testDifferentKeyPairsProduceDifferentSharedSecrets() throws {
        let alice = ECDHB163.generateKeyPair()
        let bob = ECDHB163.generateKeyPair()
        let carol = ECDHB163.generateKeyPair()

        let aliceBob = try ECDHB163.sharedSecret(privateKey: alice.privateKey, peerPublicKey: bob.publicKey)
        let aliceCarol = try ECDHB163.sharedSecret(privateKey: alice.privateKey, peerPublicKey: carol.publicKey)

        XCTAssertNotEqual(aliceBob, aliceCarol)
    }

    func testPublicKeyIsOnTheCurve() {
        let keyPair = ECDHB163.generateKeyPair()
        let x = GF2m163(bigEndianBytes: Array(keyPair.publicKey[0..<24]))
        let y = GF2m163(bigEndianBytes: Array(keyPair.publicKey[24..<48]))

        // y^2 + xy == x^3 + a*x^2 + b
        let lhs = y.squared() + x * y
        let rhs = x.squared() * x + CurveB163.a * x.squared() + CurveB163.b
        XCTAssertEqual(lhs, rhs)
    }

    func testGeneratorSatisfiesCurveEquation() {
        let g = CurveB163.generator
        let lhs = g.y.squared() + g.x * g.y
        let rhs = g.x.squared() * g.x + CurveB163.a * g.x.squared() + CurveB163.b
        XCTAssertEqual(lhs, rhs, "The published sect163r2 generator point must satisfy the curve equation; a failure here means a or b or Gx/Gy was transcribed incorrectly")
    }

    func testPointAdditionIsCommutative() {
        let a = ECDHB163.generateKeyPair()
        let b = ECDHB163.generateKeyPair()
        let pointA = ECPointB163(
            x: GF2m163(bigEndianBytes: Array(a.publicKey[0..<24])),
            y: GF2m163(bigEndianBytes: Array(a.publicKey[24..<48])),
            isInfinity: false
        )
        let pointB = ECPointB163(
            x: GF2m163(bigEndianBytes: Array(b.publicKey[0..<24])),
            y: GF2m163(bigEndianBytes: Array(b.publicKey[24..<48])),
            isInfinity: false
        )
        XCTAssertEqual(pointA.adding(pointB), pointB.adding(pointA))
    }

    func testDoublingMatchesSelfAddition() {
        let keyPair = ECDHB163.generateKeyPair()
        let point = ECPointB163(
            x: GF2m163(bigEndianBytes: Array(keyPair.publicKey[0..<24])),
            y: GF2m163(bigEndianBytes: Array(keyPair.publicKey[24..<48])),
            isInfinity: false
        )
        XCTAssertEqual(point.doubled(), point.adding(point))
    }

    func testPointPlusItsNegationIsInfinity() {
        let g = CurveB163.generator
        XCTAssertEqual(g.adding(g.negated()), .infinity)
    }
}
