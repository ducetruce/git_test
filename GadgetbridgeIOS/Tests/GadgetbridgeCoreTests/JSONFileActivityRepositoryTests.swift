import XCTest
@testable import GadgetbridgeCore

final class JSONFileActivityRepositoryTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GadgetbridgeCoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testSavedHeartRateSamplesRoundTripWithinDateRange() throws {
        let repository = try JSONFileActivityRepository(directory: tempDirectory)
        let deviceId = UUID()
        let now = Date()

        try repository.save(HeartRateSample(deviceId: deviceId, timestamp: now, beatsPerMinute: 65))
        try repository.save(HeartRateSample(deviceId: deviceId, timestamp: now.addingTimeInterval(60), beatsPerMinute: 70))
        try repository.save(HeartRateSample(deviceId: UUID(), timestamp: now, beatsPerMinute: 999)) // different device

        let results = try repository.heartRateSamples(
            for: deviceId,
            in: now.addingTimeInterval(-10)...now.addingTimeInterval(120)
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(Set(results.map(\.beatsPerMinute)), [65, 70])
    }

    func testSamplesOutsideRangeAreExcluded() throws {
        let repository = try JSONFileActivityRepository(directory: tempDirectory)
        let deviceId = UUID()
        let now = Date()

        try repository.save(HeartRateSample(deviceId: deviceId, timestamp: now.addingTimeInterval(-3600), beatsPerMinute: 60))

        let results = try repository.heartRateSamples(
            for: deviceId,
            in: now.addingTimeInterval(-10)...now.addingTimeInterval(10)
        )

        XCTAssertTrue(results.isEmpty)
    }

    func testActivitySamplesPersistAcrossRepositoryInstances() throws {
        let deviceId = UUID()
        let now = Date()

        do {
            let repository = try JSONFileActivityRepository(directory: tempDirectory)
            try repository.save(ActivitySample(deviceId: deviceId, timestamp: now, steps: 1234))
        }

        let reopened = try JSONFileActivityRepository(directory: tempDirectory)
        let results = try reopened.activitySamples(
            for: deviceId,
            in: now.addingTimeInterval(-10)...now.addingTimeInterval(10)
        )

        XCTAssertEqual(results.first?.steps, 1234)
    }
}
