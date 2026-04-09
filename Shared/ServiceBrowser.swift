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
            for: .bonjour(type: "_flux._udp", domain: nil),
            using: params
        )
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            print("[ServiceBrowser] results changed: \(results.count) results, \(changes.count) changes")
            for result in results {
                print("[ServiceBrowser]   endpoint: \(result.endpoint), metadata: \(result.metadata)")
            }
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
            // TXT record may or may not be present — accept either way.
            var dict: [String: String] = [:]
            if case .bonjour(let txt) = result.metadata {
                dict = txt.dictionary
            }
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
        DispatchQueue.main.async {
            self.hosts = found
        }
    }
}

// NWTXTRecord convenience extension.
private extension NWTXTRecord {
    /// Read TXT record entries into a plain dictionary.
    /// NWTXTRecord supports String subscript natively.
    var dictionary: [String: String] {
        var d: [String: String] = [:]
        for key in ["version", "pixel_port", "pen_port", "cert_sha256"] {
            if let val = self[key] {
                d[key] = val
            }
        }
        return d
    }
}
