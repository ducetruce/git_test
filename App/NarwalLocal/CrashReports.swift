import Foundation
import MetricKit

/// Keeps the crash and hang reports iOS hands over (via MetricKit, on the
/// launch after a crash) so they can be shared from Settings > Diagnostics.
final class CrashReports: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashReports()

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CrashReports", isDirectory: true)
    }

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        for payload in payloads {
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            guard crashes + hangs > 0 else { continue }
            let stamp = ISO8601DateFormatter().string(from: payload.timeStampEnd)
                .replacingOccurrences(of: ":", with: "-")
            let name = "\(stamp)-\(crashes > 0 ? "crash" : "hang").json"
            try? payload.jsonRepresentation().write(to: Self.directory.appendingPathComponent(name))
        }
    }

    /// Newest first.
    static func all() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
