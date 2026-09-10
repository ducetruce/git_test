import XCTest
@testable import GadgetbridgeCore

final class HeartRateVariabilityTests: XCTestCase {
    func testRMSSDMatchesHandComputedValue() {
        // Intervals 1.000s, 1.100s, 1.000s -> successive differences of
        // +100ms and -100ms. RMS of those is exactly 100ms.
        let rmssd = HeartRateVariability.rmssd(intervals: [1.0, 1.1, 1.0])
        XCTAssertEqual(rmssd ?? 0, 100.0, accuracy: 0.001)
    }

    func testSDNNMatchesHandComputedValue() {
        // 1000, 1100, 1000 ms: mean 1033.33, sample variance 3333.33,
        // standard deviation 57.735.
        let sdnn = HeartRateVariability.sdnn(intervals: [1.0, 1.1, 1.0])
        XCTAssertEqual(sdnn ?? 0, 57.735, accuracy: 0.01)
    }

    func testPerfectlyRegularIntervalsHaveZeroVariability() {
        XCTAssertEqual(HeartRateVariability.rmssd(intervals: [0.9, 0.9, 0.9, 0.9]) ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(HeartRateVariability.sdnn(intervals: [0.9, 0.9, 0.9, 0.9]) ?? -1, 0, accuracy: 0.0001)
    }

    func testNeedsAtLeastTwoIntervals() {
        XCTAssertNil(HeartRateVariability.rmssd(intervals: []))
        XCTAssertNil(HeartRateVariability.rmssd(intervals: [1.0]))
        XCTAssertNil(HeartRateVariability.sdnn(intervals: [1.0]))
    }

    /// A missed or double-counted beat produces an interval far outside any
    /// plausible heart rate, and one such artefact dominates RMSSD entirely
    /// — so they're dropped before the maths.
    func testArtefactsAreFilteredOut() {
        let withArtefact = HeartRateVariability.rmssd(intervals: [1.0, 5.0, 1.0])
        XCTAssertEqual(withArtefact ?? -1, 0, accuracy: 0.0001, "The 5s interval should be discarded, leaving two identical intervals")

        XCTAssertEqual(HeartRateVariability.filterArtefacts([0.1, 1.0, 3.0, 0.8]), [1.0, 0.8])
    }

    func testSampleCarriesBeatCountAndBothMetrics() {
        let deviceId = UUID()
        let sample = HeartRateVariability.sample(deviceId: deviceId, intervals: [1.0, 1.1, 1.0])

        XCTAssertEqual(sample?.deviceId, deviceId)
        XCTAssertEqual(sample?.beatCount, 3)
        XCTAssertEqual(sample?.rmssdMilliseconds ?? 0, 100.0, accuracy: 0.001)
        XCTAssertEqual(sample?.sdnnMilliseconds ?? 0, 57.735, accuracy: 0.01)
    }
}

final class HRVAccumulatorTests: XCTestCase {
    func testEmitsNothingBeforeTheWindowCloses() {
        let accumulator = HRVAccumulator(window: 60, minimumBeats: 3)
        let start = Date()

        XCTAssertNil(accumulator.add([1.0, 1.0], deviceId: UUID(), now: start))
        XCTAssertNil(accumulator.add([1.0, 1.0], deviceId: UUID(), now: start.addingTimeInterval(30)))
    }

    func testEmitsSampleOnceWindowClosesWithEnoughBeats() {
        let accumulator = HRVAccumulator(window: 60, minimumBeats: 4)
        let deviceId = UUID()
        let start = Date()

        _ = accumulator.add([1.0, 1.1], deviceId: deviceId, now: start)
        let sample = accumulator.add([1.0, 1.1], deviceId: deviceId, now: start.addingTimeInterval(61))

        XCTAssertNotNil(sample)
        XCTAssertEqual(sample?.beatCount, 4)
    }

    /// A window that closes with too few usable beats produces no reading
    /// rather than a meaningless one.
    func testWindowWithTooFewBeatsProducesNothing() {
        let accumulator = HRVAccumulator(window: 60, minimumBeats: 20)
        let start = Date()

        _ = accumulator.add([1.0, 1.0], deviceId: UUID(), now: start)
        XCTAssertNil(accumulator.add([1.0, 1.0], deviceId: UUID(), now: start.addingTimeInterval(61)))
    }

    func testWindowRestartsAfterEmitting() {
        let accumulator = HRVAccumulator(window: 60, minimumBeats: 2)
        let deviceId = UUID()
        let start = Date()

        _ = accumulator.add([1.0, 1.1], deviceId: deviceId, now: start)
        XCTAssertNotNil(accumulator.add([1.0, 1.1], deviceId: deviceId, now: start.addingTimeInterval(61)))
        // Immediately after emitting, the next window has just begun.
        XCTAssertNil(accumulator.add([1.0, 1.1], deviceId: deviceId, now: start.addingTimeInterval(62)))
    }
}
