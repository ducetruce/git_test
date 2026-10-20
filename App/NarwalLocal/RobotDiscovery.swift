import Foundation
import Network
import NarwalKit
import Observation

/// Finds robots advertising `_narwal_sweeper._tcp` on the local network and
/// resolves each to an IP address.
@MainActor
@Observable
final class RobotDiscovery {
    struct Found: Identifiable, Hashable {
        let name: String
        let host: String
        /// The service's Bonjour TXT record, which may carry the device id.
        var txt: [String: String] = [:]
        var id: String { host }

        /// A 32-hex-character value in the TXT record: the robot's device id.
        var deviceIdCandidate: String? {
            txt.values.first { $0.count == 32 && $0.allSatisfy(\.isHexDigit) }?.lowercased()
        }
    }

    /// Called for each newly resolved robot.
    @ObservationIgnored var onFound: ((Found) -> Void)?

    private(set) var found: [Found] = []
    private(set) var isSearching = false

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var resolvers: [NWConnection] = []

    func start() {
        stop()
        isSearching = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: NarwalDefaults.bonjourType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.resolve(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolvers.forEach { $0.cancel() }
        resolvers = []
        isSearching = false
    }

    private func resolve(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata { txt = record.dictionary }
            // Connecting to the service endpoint is the supported way to learn
            // its address; the connection is dropped as soon as it resolves.
            // IPv4 only: an IPv6 link-local address is unusable without its
            // interface suffix, and robots' IPv6 addresses change.
            let parameters = NWParameters.tcp
            if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = .v4
            }
            let connection = NWConnection(to: result.endpoint, using: parameters)
            connection.stateUpdateHandler = { [weak self] state in
                guard case .ready = state else { return }
                if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint {
                    // From the raw bytes: the host's description carries an
                    // interface suffix ("%en0") that breaks URLs.
                    if case .ipv4(let ipv4) = host {
                        let address = ipv4.rawValue.map(String.init).joined(separator: ".")
                        Task { @MainActor in self?.add(Found(name: name, host: address, txt: txt)) }
                    }
                }
                connection.cancel()
            }
            connection.start(queue: .main)
            resolvers.append(connection)
        }
    }

    private func add(_ robot: Found) {
        guard !found.contains(robot) else { return }
        found.append(robot)
        found.sort { $0.name < $1.name }
        onFound?(robot)
    }
}
