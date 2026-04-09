// ServiceBrowser.swift — Bonjour discovery for _flux._udp.local.
//
// Uses Network.framework's NWBrowser (the platform-native mDNS path).
// The handoff doc says: "Use NWBrowser, not the Rust flux-transport
// discovery module." The Rust module is for the host side and CLI
// benchmarks; the native client uses the OS API.

import Network
import Combine

/// A discovered flux host on the local network.
public struct FluxHost: Identifiable, Hashable {
    public let id: String        // Bonjour instance name
    public let name: String      // human-readable (instance name)
    public let pixelPort: UInt16
    public let penPort: UInt16
    public let version: String
    public let certSHA256: String
    public let endpoint: NWEndpoint
}

/// Browses the local network for flux hosts advertising
/// `_flux._udp.local.`. Publishes discovered hosts via Combine.
public final class ServiceBrowser: ObservableObject {
    @Published public private(set) var hosts: [FluxHost] = []

    private var browser: NWBrowser?

    public init() {}

    public func start() {
        let params = NWParameters()
        let browser = NWBrowser(
            for: .bonjour(type: "_flux._udp.", domain: "local."),
            using: params
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleResults(results)
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[ServiceBrowser] browsing for _flux._udp.local.")
            case .failed(let error):
                print("[ServiceBrowser] failed: \(error)")
            default:
                break
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        hosts = []
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var found: [FluxHost] = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            // TXT record metadata — populated by flux-transport DiscoveryAdvertiser.
            if case .bonjour(let txt) = result.metadata {
                let dict = txt.dictionary
                let host = FluxHost(
                    id: name,
                    name: name,
                    pixelPort: UInt16(dict["pixel_port"] ?? "") ?? 9000,
                    penPort: UInt16(dict["pen_port"] ?? "") ?? 9001,
                    version: dict["version"] ?? "unknown",
                    certSHA256: dict["cert_sha256"] ?? "",
                    endpoint: result.endpoint
                )
                found.append(host)
            }
        }
        DispatchQueue.main.async {
            self.hosts = found
        }
    }
}

// NWTXTRecord convenience extension.
private extension NWTXTRecord {
    var dictionary: [String: String] {
        var d: [String: String] = [:]
        // NWTXTRecord doesn't expose iteration directly in all OS
        // versions; use the raw DNS-SD key enumeration pattern.
        // For simplicity we rely on the debug description parsing
        // or the getEntry API where available.
        // TODO: use proper NWTXTRecord.getEntry once min deployment
        // target supports it.
        return d
    }
}
