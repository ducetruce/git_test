import Foundation

/// Sink for protocol-level diagnostics — the raw bytes going to and coming
/// from a device, plus how this code interpreted them.
///
/// This exists specifically so the guessed parts of the Amazfit/Zepp OS
/// handshake can be checked against what real hardware actually sends (see
/// `AmazfitHelioSession`). It is a protocol so tests can capture output and
/// so an app can substitute its own sink.
public protocol ProtocolLogging: AnyObject {
    func log(_ message: String)
}

/// Records protocol diagnostics to an in-memory ring buffer and (by
/// default) echoes them to stdout, where they show up in Xcode's console
/// when running from Xcode. The buffer is what makes the transcript
/// retrievable from inside the app when running untethered.
public final class ProtocolLogger: ProtocolLogging, @unchecked Sendable {
    public static let shared = ProtocolLogger()

    private let lock = NSLock()
    private var lines: [String] = []
    private let maximumLines: Int
    private let echoesToConsole: Bool

    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public init(maximumLines: Int = 1000, echoesToConsole: Bool = true) {
        self.maximumLines = maximumLines
        self.echoesToConsole = echoesToConsole
    }

    public func log(_ message: String) {
        let line = "[\(timestampFormatter.string(from: Date()))] \(message)"
        if echoesToConsole {
            print(line)
        }
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
        if lines.count > maximumLines {
            lines.removeFirst(lines.count - maximumLines)
        }
    }

    /// The recorded lines, oldest first, ready to copy out and share.
    public var transcript: String {
        transcriptLines.joined(separator: "\n")
    }

    /// The recorded lines individually, so a viewer can style each one by
    /// what it means rather than rendering one opaque blob.
    public var transcriptLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        lines.removeAll()
    }
}

public extension Sequence where Element == UInt8 {
    /// Space-separated uppercase hex, the conventional way to read a
    /// protocol dump (`04 02 00 02 …`).
    var hexDump: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
