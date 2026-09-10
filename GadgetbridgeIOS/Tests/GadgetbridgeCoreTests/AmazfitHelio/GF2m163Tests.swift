import XCTest
@testable import GadgetbridgeCore

final class GF2m163Tests: XCTestCase {
    func testAdditionIsItsOwnInverse() {
        let a = GF2m163(bigEndianBytes: [0x01, 0x02, 0x03])
        let b = GF2m163(bigEndianBytes: [0xAA, 0xBB, 0xCC])
        XCTAssertEqual((a + b) + b, a) // (a+b)+b == a, since +/- are both XOR in GF(2^m)
    }

    func testMultiplicationByOneIsIdentity() {
        let a = GF2m163(bigEndianBytes: [0x12, 0x34, 0x56, 0x78])
        XCTAssertEqual(a * .one, a)
    }

    func testMultiplicationByZeroIsZero() {
        let a = GF2m163(bigEndianBytes: [0x12, 0x34, 0x56, 0x78])
        XCTAssertEqual(a * .zero, .zero)
    }

    func testMultiplicationIsCommutative() {
        let a = GF2m163(bigEndianBytes: [0x01, 0x23, 0x45, 0x67, 0x89])
        let b = GF2m163(bigEndianBytes: [0x9A, 0xBC, 0xDE, 0xF0])
        XCTAssertEqual(a * b, b * a)
    }

    func testInverseRoundTrips() {
        let a = GF2m163(bigEndianBytes: [0x7F, 0x11, 0x22, 0x33, 0x44])
        let inverse = a.inverted()
        XCTAssertEqual(a * inverse, .one)
        XCTAssertEqual(inverse.inverted(), a)
    }

    func testBigEndianByteRoundTrip() {
        let bytes: [UInt8] = [0x03, 0xF0, 0xEB, 0xA1, 0x62, 0x86, 0xA2, 0xD5, 0x7E, 0xA0, 0x99,
                               0x11, 0x68, 0xD4, 0x99, 0x46, 0x37, 0xE8, 0x34, 0x3E, 0x36]
        let element = GF2m163(bigEndianBytes: bytes)
        XCTAssertEqual(element.bigEndianBytes(width: bytes.count), bytes)
    }

    func testValuesAreMaskedTo163Bits() {
        // Setting bits above 162 should have no effect on the stored value.
        let withHighBit = GF2m163(limbs: [0, 0, 1 << 40]) // bit 168, out of range
        XCTAssertEqual(withHighBit, GF2m163.zero)
    }
}
