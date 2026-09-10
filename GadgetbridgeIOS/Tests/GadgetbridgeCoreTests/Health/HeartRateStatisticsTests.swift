import XCTest
@testable import GadgetbridgeCore

final class HeartRateStatisticsTests: XCTestCase {
    private func samples(bpms: [Int]) -> [HeartRateSample] {
        let deviceId = UUID()
        let start = Date()
        return bpms.enumerated().map { index, bpm in
            HeartRateSample(
                deviceId: deviceId,
                timestamp: start.addingTimeInterval(Double(index)),
                beatsPerMinute: bpm
            )
        }
    }

    func testRestingHeartRateUsesLowDecileNotTheMinimum() {
        // 50...149. The 10th percentile of 100 sorted values is index 9.
        let values = (0..<100).map { 50 + $0 }
        XCTAssertEqual(HeartRateStatistics.restingHeartRate(from: samples(bpms: values)), 59)
    }

    /// A single dropout shouldn't drag resting heart rate down with it,
    /// which is exactly what using the minimum would do.
    func testSingleOutlierDoesNotDetermineRestingHeartRate() {
        var values = Array(repeating: 62, count: 40)
        values[0] = 31
        XCTAssertEqual(HeartRateStatistics.restingHeartRate(from: samples(bpms: values)), 62)
    }

    func testTooFewSamplesProducesNoRestingEstimate() {
        XCTAssertNil(HeartRateStatistics.restingHeartRate(from: samples(bpms: [60, 61, 62])))
        XCTAssertNil(HeartRateStatistics.restingHeartRate(from: []))
    }

    func testAverage() {
        XCTAssertEqual(HeartRateStatistics.average(of: samples(bpms: [60, 70, 80])), 70)
        XCTAssertNil(HeartRateStatistics.average(of: []))
    }
}

final class HeartRateZoneTests: XCTestCase {
    func testZoneBoundariesAgainstMaximumHeartRate() {
        let max = 200
        XCTAssertEqual(HeartRateZone.zone(forBPM: 100, maximumHeartRate: max), .recovery)
        XCTAssertEqual(HeartRateZone.zone(forBPM: 119, maximumHeartRate: max), .recovery)
        XCTAssertEqual(HeartRateZone.zone(forBPM: 120, maximumHeartRate: max), .aerobicBase)
        XCTAssertEqual(HeartRateZone.zone(forBPM: 140, maximumHeartRate: max), .aerobic)
        XCTAssertEqual(HeartRateZone.zone(forBPM: 160, maximumHeartRate: max), .threshold)
        XCTAssertEqual(HeartRateZone.zone(forBPM: 180, maximumHeartRate: max), .maximum)
        XCTAssertEqual(HeartRateZone.zone(forBPM: 250, maximumHeartRate: max), .maximum)
    }

    func testBelowZoneOneIsNotAZone() {
        XCTAssertNil(HeartRateZone.zone(forBPM: 99, maximumHeartRate: 200))
        XCTAssertNil(HeartRateZone.zone(forBPM: 60, maximumHeartRate: 200))
    }

    func testInvalidMaximumIsRejected() {
        XCTAssertNil(HeartRateZone.zone(forBPM: 120, maximumHeartRate: 0))
    }

    func testAgeBasedMaximumEstimate() {
        XCTAssertEqual(HeartRateZone.estimatedMaximum(forAge: 30), 190)
        // Clamped, so an implausible age can't produce a nonsense ceiling.
        XCTAssertEqual(HeartRateZone.estimatedMaximum(forAge: 200), 100)
    }
}
