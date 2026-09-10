import XCTest
@testable import GadgetbridgeCore

/// The `0x2A37` flags byte selects which optional fields follow, so the
/// field offsets shift depending on earlier flags. These cover each
/// combination that changes the layout.
final class HeartRateMeasurementParserTests: XCTestCase {
    func testUInt8FormatWithNoOptionalFields() {
        let measurement = HeartRateMeasurementParser.parse(Data([0x00, 72]))
        XCTAssertEqual(measurement?.beatsPerMinute, 72)
        XCTAssertEqual(measurement?.sensorContact, .notSupported)
        XCTAssertNil(measurement?.energyExpendedKilojoules)
        XCTAssertTrue(measurement?.rrIntervals.isEmpty ?? false)
    }

    func testUInt16FormatValue() {
        // flags bit 0 set: heart rate is a little-endian UINT16.
        let measurement = HeartRateMeasurementParser.parse(Data([0x01, 0x2C, 0x01]))
        XCTAssertEqual(measurement?.beatsPerMinute, 300)
    }

    func testSensorContactDetectedAndNotDetected() {
        // bits 1-2: contact supported (0x04) plus detected (0x02).
        let detected = HeartRateMeasurementParser.parse(Data([0x06, 65]))
        XCTAssertEqual(detected?.sensorContact, .detected)

        let notDetected = HeartRateMeasurementParser.parse(Data([0x04, 65]))
        XCTAssertEqual(notDetected?.sensorContact, .notDetected)

        // Contact bit set without the supported bit means unsupported.
        let unsupported = HeartRateMeasurementParser.parse(Data([0x02, 65]))
        XCTAssertEqual(unsupported?.sensorContact, .notSupported)
    }

    func testEnergyExpendedShiftsRRIntervalOffset() {
        // flags 0x18 = energy expended (0x08) + RR intervals (0x10).
        // Layout: flags, bpm, energy(2), rr(2)
        let data = Data([0x18, 60, 0xE8, 0x03, 0x00, 0x04])
        let measurement = HeartRateMeasurementParser.parse(data)

        XCTAssertEqual(measurement?.beatsPerMinute, 60)
        XCTAssertEqual(measurement?.energyExpendedKilojoules, 1000)
        // 0x0400 = 1024 units of 1/1024 s = exactly 1 second.
        XCTAssertEqual(measurement?.rrIntervals.first ?? 0, 1.0, accuracy: 0.0001)
    }

    func testMultipleRRIntervalsInOneNotification() {
        // flags 0x10 = RR intervals only. Two intervals: 1024 and 512.
        let data = Data([0x10, 60, 0x00, 0x04, 0x00, 0x02])
        let measurement = HeartRateMeasurementParser.parse(data)

        XCTAssertEqual(measurement?.rrIntervals.count, 2)
        XCTAssertEqual(measurement?.rrIntervals[0] ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(measurement?.rrIntervals[1] ?? 0, 0.5, accuracy: 0.0001)
    }

    func testReturnsNilForEmptyOrTruncatedPayloads() {
        XCTAssertNil(HeartRateMeasurementParser.parse(Data()))
        XCTAssertNil(HeartRateMeasurementParser.parse(Data([0x00])))
        // Flags claim UINT16 but only one payload byte follows.
        XCTAssertNil(HeartRateMeasurementParser.parse(Data([0x01, 0x2C])))
    }

    func testTruncatedRRFieldIsIgnoredRatherThanCrashing() {
        // RR flag set but only one trailing byte: not a whole UINT16.
        let measurement = HeartRateMeasurementParser.parse(Data([0x10, 60, 0x00]))
        XCTAssertEqual(measurement?.beatsPerMinute, 60)
        XCTAssertTrue(measurement?.rrIntervals.isEmpty ?? false)
    }
}
