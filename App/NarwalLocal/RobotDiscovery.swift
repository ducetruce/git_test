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
        var id: String { host }
    }

    private(set) var found: [Found] = []
    private(set) var isSearching = false

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var resolvers: [NWConnection] = []

    func start() {
        stop()
        isSearching = true
        let browser = NWBrowser(for: .bonjour(type: NarwalDefaults.bonjourType, domain: nil), using: .tcp)
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
            // Connecting to the service endpoint is the supported way to learn
            // its address; the connection is dropped as soon as it resolves.
            let connection = NWConnection(to: result.endpoint, using: .tcp)
            connection.stateUpdateHandler = { [weak self] state in
                guard case .ready = state else { return }
                if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint {
                    var address = "\(host)"
                    if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
                    Task { @MainActor in self?.add(Found(name: name, host: address)) }
                }
                connection.cancel()
            }
            connection.start(queue: .main)
            resolvers.append(connection)
        }
    }

    private func add(_ robot: Found) {
        guard !found.contains(robot) else { return }
        // Prefer IPv4: the reference integration lost robots when discovery
        // handed back an IPv6 address that later changed.
        found.append(robot)
        found.sort { ($0.host.contains(":") ? 1 : 0, $0.name) < ($1.host.contains(":") ? 1 : 0, $1.name) }
    }
}
