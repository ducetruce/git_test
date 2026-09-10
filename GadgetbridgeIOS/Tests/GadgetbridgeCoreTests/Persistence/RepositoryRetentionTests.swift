import XCTest
@testable import GadgetbridgeCore

final class RepositoryRetentionTests: XCTestCase {
    private var directory: URL!
    private let deviceId = UUID()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetentionTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sample(daysAgo: Int, bpm: Int = 60) -> HeartRateSample {
        HeartRateSample(
            deviceId: deviceId,
            timestamp: Date().addingTimeInterval(-Double(daysAgo) * 86_400),
            beatsPerMinute: bpm
        )
    }

    /// Samples land in per-day buckets, so a query spanning several days
    /// still has to return all of them.
    func testQuerySpanningMultipleDayBucketsReturnsEverything() throws {
        let repository = try JSONFileActivityRepository(directory: directory)
        try repository.save(sample(daysAgo: 0, bpm: 60))
        try repository.save(sample(daysAgo: 1, bpm: 61))
        try repository.save(sample(daysAgo: 2, bpm: 62))

        let results = try repository.heartRateSamples(
            for: deviceId,
            in: Date().addingTimeInterval(-3 * 86_400)...Date()
        )

        XCTAssertEqual(Set(results.map(\.beatsPerMinute)), [60, 61, 62])
    }

    func testQueryDoesNotReturnSamplesOutsideTheRange() throws {
        let repository = try JSONFileActivityRepository(directory: directory)
        try repository.save(sample(daysAgo: 0, bpm: 60))
        try repository.save(sample(daysAgo: 10, bpm: 99))

        let results = try repository.heartRateSamples(
            for: deviceId,
            in: Date().addingTimeInterval(-2 * 86_400)...Date()
        )

        XCTAssertEqual(results.map(\.beatsPerMinute), [60])
    }

    /// The bucket layout is what makes retention cheap: whole files are
    /// removed rather than rewriting a single log.
    func testPruneDeletesOldBucketsAndKeepsRecentOnes() throws {
        let repository = try JSONFileActivityRepository(directory: directory)
        try repository.save(sample(daysAgo: 0, bpm: 60))
        try repository.save(sample(daysAgo: 20, bpm: 80))

        try repository.prune(before: Date().addingTimeInterval(-10 * 86_400))

        let all = try repository.heartRateSamples(
            for: deviceId,
            in: Date().addingTimeInterval(-90 * 86_400)...Date()
        )
        XCTAssertEqual(all.map(\.beatsPerMinute), [60])
    }

    func testPruneLeavesOtherDevicesDataForTheSameDayAlone() throws {
        let repository = try JSONFileActivityRepository(directory: directory)
        let other = UUID()
        try repository.save(sample(daysAgo: 0, bpm: 60))
        try repository.save(HeartRateSample(deviceId: other, timestamp: Date(), beatsPerMinute: 70))

        try repository.prune(before: Date().addingTimeInterval(-10 * 86_400))

        let range = Date().addingTimeInterval(-86_400)...Date()
        XCTAssertEqual(try repository.heartRateSamples(for: deviceId, in: range).count, 1)
        XCTAssertEqual(try repository.heartRateSamples(for: other, in: range).count, 1)
    }

    func testHRVAndActivitySharePruningButNotBuckets() throws {
        let repository = try JSONFileActivityRepository(directory: directory)
        try repository.save(ActivitySample(deviceId: deviceId, timestamp: Date(), steps: 100))
        try repository.save(HRVSample(
            deviceId: deviceId,
            timestamp: Date(),
            rmssdMilliseconds: 42,
            sdnnMilliseconds: 40,
            beatCount: 30
        ))

        let range = Date().addingTimeInterval(-86_400)...Date()
        XCTAssertEqual(try repository.activitySamples(for: deviceId, in: range).count, 1)
        XCTAssertEqual(try repository.hrvSamples(for: deviceId, in: range).count, 1)

        try repository.prune(before: Date().addingTimeInterval(86_400))
        XCTAssertTrue(try repository.activitySamples(for: deviceId, in: range).isEmpty)
        XCTAssertTrue(try repository.hrvSamples(for: deviceId, in: range).isEmpty)
    }

    func testInMemoryRepositoryPrunesToo() throws {
        let repository = InMemoryActivityRepository()
        try repository.save(sample(daysAgo: 0, bpm: 60))
        try repository.save(sample(daysAgo: 20, bpm: 80))

        try repository.prune(before: Date().addingTimeInterval(-10 * 86_400))

        let all = try repository.heartRateSamples(
            for: deviceId,
            in: Date().addingTimeInterval(-90 * 86_400)...Date()
        )
        XCTAssertEqual(all.map(\.beatsPerMinute), [60])
    }
}
