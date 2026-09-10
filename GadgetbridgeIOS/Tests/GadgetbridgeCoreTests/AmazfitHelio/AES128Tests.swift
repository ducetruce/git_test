import XCTest
@testable import GadgetbridgeCore

final class AES128Tests: XCTestCase {
    /// The canonical FIPS-197 Appendix B known-answer test vector — about
    /// as close to an unambiguous ground truth as cryptographic test data
    /// gets, and reproduced identically across essentially every AES
    /// implementation and textbook.
    func testFIPS197KnownAnswerVector() {
        let key: [UInt8] = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
                             0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F]
        let plaintext: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                                   0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        let expectedCiphertext: [UInt8] = [0x69, 0xC4, 0xE0, 0xD8, 0x6A, 0x7B, 0x04, 0x30,
                                            0xD8, 0xCD, 0xB7, 0x80, 0x70, 0xB4, 0xC5, 0x5A]

        let roundKeys = AES128.expandKey(key)
        let ciphertext = AES128.encryptBlock(plaintext, roundKeys: roundKeys)
        XCTAssertEqual(ciphertext, expectedCiphertext)

        let decrypted = AES128.decryptBlock(ciphertext, roundKeys: roundKeys)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testECBRoundTripsAcrossMultipleBlocks() {
        let key: [UInt8] = (0..<16).map { UInt8($0 * 7) }
        let plaintext: [UInt8] = (0..<48).map { UInt8($0) } // 3 blocks

        let ciphertext = AES128.ecbEncrypt(plaintext, key: key)
        XCTAssertEqual(ciphertext.count, plaintext.count)
        XCTAssertNotEqual(ciphertext, plaintext)

        let decrypted = AES128.ecbDecrypt(ciphertext, key: key)
        XCTAssertEqual(decrypted, plaintext)
    }
}
