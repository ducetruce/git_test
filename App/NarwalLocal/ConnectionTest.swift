import Foundation
import Network

/// Plain TCP check of the robot's port, independent of the WebSocket layer:
/// separates "network/permission problem" from "protocol problem".
enum ConnectionTest {
    static func tcp(host: String, port: UInt16 = 9002, timeout: TimeInterval = 5) async -> String {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return "Invalid port" }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let once = Once()
        return await withCheckedContinuation { continuation in
            func finish(_ text: String) {
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: text)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish("Port \(port) on \(host) is open.")
                case .waiting(let error):
                    finish("Can't reach port \(port) on \(host): \(error.localizedDescription)")
                case .failed(let error):
                    finish("Connection to \(host):\(port) failed: \(error.localizedDescription)")
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish("No answer from \(host):\(port) within \(Int(timeout)) s. Wrong address, or the robot is on a different network.")
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
