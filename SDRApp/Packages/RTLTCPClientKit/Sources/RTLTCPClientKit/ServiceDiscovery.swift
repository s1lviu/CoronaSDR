import Foundation
import Network
import Observation
import SDRSupport

/// Discovered SDR server on the local network.
public struct DiscoveredServer: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let host: String
    public let port: UInt16
    public let serviceType: String

    public init(name: String, host: String, port: UInt16, serviceType: String) {
        self.id = "\(host):\(port)"
        self.name = name
        self.host = host
        self.port = port
        self.serviceType = serviceType
    }
}

/// Browses the local network for rtl_tcp (and related) Bonjour services.
@Observable
@MainActor
public final class ServiceDiscovery {
    public var discoveredServers: [DiscoveredServer] = []
    public var isBrowsing: Bool = false

    private var browser: NWBrowser?
    private var resolvers: [NWConnection] = []

    public static let rtlTcpServiceType = "_rtltcp._tcp"

    public init() {}

    /// Start browsing for SDR services on the local network.
    public func startBrowsing(serviceType: String = rtlTcpServiceType) {
        stopBrowsing()

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isBrowsing = true
                    SDRLogger.network.info("Bonjour browser ready for \(serviceType)")
                case .failed(let error):
                    SDRLogger.network.error("Bonjour browser failed: \(error)")
                    self.isBrowsing = false
                case .cancelled:
                    self.isBrowsing = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.handleBrowseResults(results)
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    /// Stop browsing and clean up.
    public func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        resolvers.forEach { $0.cancel() }
        resolvers.removeAll()
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        for result in results {
            switch result.endpoint {
            case .service(let name, let type, let domain, _):
                resolveService(name: name, type: type, domain: domain)
            default:
                break
            }
        }
    }

    private func resolveService(name: String, type: String, domain: String) {
        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
        let connection = NWConnection(to: endpoint, using: .tcp)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let innerEndpoint = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = innerEndpoint {
                    let hostStr: String
                    switch host {
                    case .ipv4(let addr):
                        hostStr = "\(addr)"
                    case .ipv6(let addr):
                        hostStr = "\(addr)"
                    case .name(let hostname, _):
                        hostStr = hostname
                    @unknown default:
                        hostStr = "\(host)"
                    }
                    let server = DiscoveredServer(
                        name: name,
                        host: hostStr,
                        port: port.rawValue,
                        serviceType: type
                    )
                    Task { @MainActor [weak self] in
                        if self?.discoveredServers.contains(where: { $0.id == server.id }) == false {
                            self?.discoveredServers.append(server)
                        }
                    }
                    SDRLogger.network.info("Resolved: \(name) -> \(hostStr):\(port.rawValue)")
                }
                connection.cancel()
            case .failed:
                connection.cancel()
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .utility))
        resolvers.append(connection)
    }
}
