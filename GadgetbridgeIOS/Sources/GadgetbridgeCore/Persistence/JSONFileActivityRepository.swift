import Foundation

/// Append-only, JSON-lines backed `ActivityRepository`. Adequate for a
/// single user's local history without pulling in Core Data/SQLite; each
/// sample type gets its own `.jsonl` file under `directory`. Reads parse
/// the whole file, so a real device with months of continuous heart-rate
/// data should eventually move to a database — this exists as a working,
/// dependency-free default.
public final class JSONFileActivityRepository: ActivityRepository {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let queue = DispatchQueue(label: "GadgetbridgeCore.JSONFileActivityRepository")

    public init(directory: URL) throws {
        self.directory = directory
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func save(_ sample: ActivitySample) throws {
        try queue.sync { try append(sample, to: fileURL(for: .activity)) }
    }

    public func save(_ sample: HeartRateSample) throws {
        try queue.sync { try append(sample, to: fileURL(for: .heartRate)) }
    }

    public func save(_ sample: HRVSample) throws {
        try queue.sync { try append(sample, to: fileURL(for: .hrv)) }
    }

    public func save(_ session: SleepSession) throws {
        try queue.sync { try append(session, to: fileURL(for: .sleep)) }
    }

    public func activitySamples(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [ActivitySample] {
        try queue.sync {
            let all: [ActivitySample] = try readAll(from: fileURL(for: .activity))
            return all.filter { $0.deviceId == deviceId && range.contains($0.timestamp) }
        }
    }

    public func heartRateSamples(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [HeartRateSample] {
        try queue.sync {
            let all: [HeartRateSample] = try readAll(from: fileURL(for: .heartRate))
            return all.filter { $0.deviceId == deviceId && range.contains($0.timestamp) }
        }
    }

    public func hrvSamples(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [HRVSample] {
        try queue.sync {
            let all: [HRVSample] = try readAll(from: fileURL(for: .hrv))
            return all.filter { $0.deviceId == deviceId && range.contains($0.timestamp) }
        }
    }

    public func sleepSessions(for deviceId: UUID, in range: ClosedRange<Date>) throws -> [SleepSession] {
        try queue.sync {
            let all: [SleepSession] = try readAll(from: fileURL(for: .sleep))
            return all.filter { $0.deviceId == deviceId && range.overlaps($0.start...$0.end) }
        }
    }

    // MARK: - Private

    private enum DataKind: String {
        case activity, heartRate, hrv, sleep
    }

    private func fileURL(for kind: DataKind) -> URL {
        directory.appendingPathComponent("\(kind.rawValue).jsonl")
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
