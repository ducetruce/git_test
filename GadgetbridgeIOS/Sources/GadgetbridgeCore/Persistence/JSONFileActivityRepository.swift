import Foundation

/// Append-only, JSON-lines backed `ActivityRepository`, bucketed by day.
///
/// The bucketing is what makes it viable: a single flat file has to be
/// parsed in full for every query, so an app charting the last hour would
/// decode months of history each time it refreshed. One file per day per
/// sample type means a range query only touches the days it overlaps, and
/// retention is a matter of deleting whole files.
///
/// This is still a text format rather than a database — appropriate for a
/// few thousand rows a day, and worth replacing with SQLite if this ever
/// stores full-resolution data over long periods.
public final class JSONFileActivityRepository: ActivityRepository {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let queue = DispatchQueue(label: "GadgetbridgeCore.JSONFileActivityRepository")

    /// Buckets are cut on UTC day boundaries so the file a sample lands in
    /// doesn't shift when the user changes timezone or the clocks go back.
    private static let bucketFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static var utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    public init(directory: URL) throws {
        self.directory = directory
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Writes

    public func save(_ sample: ActivitySample) throws {
        try queue.sync { try append(sample, to: fileURL(for: .activity, containing: sample.timestamp)) }
    }

    public func save(_ sample: HeartRateSample) throws {
        try queue.sync { try append(sample, to: fileURL(for: .heartRate, containing: sample.timestamp)) }
    }

    public func save(_ sample: HRVSample) throws {
        try queue.sync { try append(sample, to: fileURL(for: .hrv, containing: sample.timestamp)) }
    }

    public func save(_ session: SleepSession) throws {
        try queue.sync { try append(session, to: fileURL(for: .sleep, containing: session.start)) }
    }

    // MARK: - Reads

    public func activitySamples(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [ActivitySample] {
        try read(.activity, in: range).filter { $0.deviceId == deviceId && range.contains($0.timestamp) }
    }

    public func heartRateSamples(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [HeartRateSample] {
        try read(.heartRate, in: range).filter { $0.deviceId == deviceId && range.contains($0.timestamp) }
    }

    public func hrvSamples(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [HRVSample] {
        try read(.hrv, in: range).filter { $0.deviceId == deviceId && range.contains($0.timestamp) }
    }

    public func sleepSessions(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [SleepSession] {
        // A session can start the day before the range and run into it, so
        // widen the buckets read by a day on the leading edge.
        let widened = range.lowerBound.addingTimeInterval(-86_400)...range.upperBound
        let all: [SleepSession] = try read(.sleep, in: widened)
        return all.filter { $0.deviceId == deviceId && range.overlaps($0.start...$0.end) }
    }

    // MARK: - Retention

    /// Deletes whole buckets older than `date`. Retention is the only thing
    /// keeping this from growing without bound.
    public func prune(before date: Date) throws {
        try queue.sync {
            let cutoff = Self.bucketFormatter.string(from: date)
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            for url in contents where url.pathExtension == "jsonl" {
                // "heartRate-2026-09-10.jsonl" -> "2026-09-10"
                let name = url.deletingPathExtension().lastPathComponent
                guard let day = name.split(separator: "-", maxSplits: 1).last.map(String.init),
                      day.count == 10,
                      day < cutoff else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Private

    private enum DataKind: String, CaseIterable {
        case activity, heartRate, hrv, sleep
    }

    private func fileURL(for kind: DataKind, containing date: Date) -> URL {
        directory.appendingPathComponent("\(kind.rawValue)-\(Self.bucketFormatter.string(from: date)).jsonl")
    }

    /// The buckets a range touches, oldest first. Bounded by the range's
    /// length rather than by how much history exists.
    private func bucketURLs(for kind: DataKind, in range: ClosedRange<Date>) -> [URL] {
        var urls: [URL] = []
        var day = Self.utcCalendar.startOfDay(for: range.lowerBound)
        let last = Self.utcCalendar.startOfDay(for: range.upperBound)
        while day <= last {
            urls.append(fileURL(for: kind, containing: day))
            guard let next = Self.utcCalendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return urls
    }

    private func read<T: Decodable>(_ kind: DataKind, in range: ClosedRange<Date>) throws -> [T] {
        try queue.sync {
            try bucketURLs(for: kind, in: range).flatMap { try readAll(from: $0) as [T] }
        }
    }

    private func append<T: Encodable>(_ value: T, to url: URL) throws {
        var line = try encoder.encode(value)
        line.append(UInt8(ascii: "\n"))

        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url)
        }
    }

    private func readAll<T: Decodable>(from url: URL) throws -> [T] {
        guard let data = FileManager.default.contents(atPath: url.path), !data.isEmpty else { return [] }
        return data
            .split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(T.self, from: Data($0)) }
    }
}
