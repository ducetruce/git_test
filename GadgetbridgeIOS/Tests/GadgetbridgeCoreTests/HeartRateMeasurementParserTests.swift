import XCTest
@testable import GadgetbridgeCore

final class HeartRateMeasurementParserTests: XCTestCase {
    func testParsesUInt8FormatValue() {
        // flags = 0 (UINT8 format), value = 72
        let data = Data([0x00, 72])
        XCTAssertEqual(HeartRateMeasurementParser.parseBPM(from: data), 72)
    }

    func testParsesUInt16FormatValue() {
        // flags = 1 (UINT16 format), value = 300 (0x012C), little-endian
        let data = Data([0x01, 0x2C, 0x01])
        XCTAssertEqual(HeartRateMeasurementParser.parseBPM(from: data), 300)
    }

    func testReturnsNilForEmptyData() {
        XCTAssertNil(HeartRateMeasurementParser.parseBPM(from: Data()))
    }

    func testReturnsNilForTruncatedUInt16Payload() {
        let data = Data([0x01, 0x2C]) // flags say UINT16 but only one payload byte follows
        XCTAssertNil(HeartRateMeasurementParser.parseBPM(from: data))
    }
}
