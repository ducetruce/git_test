import XCTest
@testable import GadgetbridgeCore

final class GenericBLESessionEncodingTests: XCTestCase {
    func testEncodeAlertUsesCallCategoryForCallAlerts() {
        let alert = NotificationAlert(category: .call, title: "Mom", body: "Incoming call")
        let data = GenericBLESession.encodeAlert(alert)

        XCTAssertEqual(data[data.startIndex], 0x01) // call category ID per ANP spec
        XCTAssertEqual(data[data.startIndex + 1], 0x01) // alert count
    }

    func testEncodeCurrentTimeProducesTenByteExactTimePayload() {
        var components = DateComponents()
        components.year = 2024
        components.month = 3
        components.day = 15
        components.hour = 9
        components.minute = 30
        components.second = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let date = calendar.date(from: components)!

        let data = GenericBLESession.encodeCurrentTime(date)

        XCTAssertEqual(data.count, 10)
        // Year is little-endian UINT16 across the first two bytes.
        let year = UInt16(data[data.startIndex]) | (UInt16(data[data.startIndex + 1]) << 8)
        XCTAssertEqual(year, 2024)
        XCTAssertEqual(data[data.startIndex + 2], 3) // month
        XCTAssertEqual(data[data.startIndex + 3], 15) // day
    }
}
