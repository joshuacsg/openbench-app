// SavedHosts.swift — persistent host list with unicast reachability.
//
// Bonjour only finds hosts on the local network; it can't traverse
// overlay networks like Tailscale, and iOS apps can't enumerate
// tailnet peers. So: every host we successfully connect to is saved
// here (keyed by its resolved IP — stable on Tailscale), and each
// saved host is health-checked with a tiny UDP probe that flux-host
// answers on pixel_port + 2 with the same metadata as its Bonjour TXT
// record. One manual connect, and your Mac shows up automatically
// (with a live status dot) from anywhere, forever.

import Foundation
import Network

public struct SavedHost: Codable, Identifiable, Equatable {
    public var name: String
    public var host: String      // IP or hostname (MagicDNS names work)
    public var pixelPort: UInt16
    public var penPort: UInt16
    public var id: String { "\(host):\(pixelPort)" }
}

@MainActor
public final class SavedHostsStore: ObservableObject {
    public static let shared = SavedHostsStore()

    @Published public private(set) var hosts: [SavedHost] = []
    /// host.id → reachable right now (nil = probing/unknown).
    @Published public private(set) var online: [String: Bool] = [:]

    private static let key = "savedHosts.v1"
    private static let probeMagic = "flux-discover-v1".data(using: .utf8)!
    private static let portOffset: UInt16 = 2

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([SavedHost].self, from: data) {
            hosts = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Record a successfully connected host (newest first, deduped by
    /// host:port, capped at 8).
    public func add(name: String, host: String, pixelPort: UInt16, penPort: UInt16) {
        var entry = SavedHost(name: name, host: host, pixelPort: pixelPort, penPort: penPort)
        if let existing = hosts.first(where: { $0.id == entry.id }), !existing.name.isEmpty,
           entry.name.isEmpty || entry.name == entry.host {
            entry.name = existing.name // keep the nicer name we had
        }
        hosts.removeAll { $0.id == entry.id }
        hosts.insert(entry, at: 0)
        if hosts.count > 8 { hosts.removeLast(hosts.count - 8) }
        online[entry.id] = true
        persist()
    }

    public func remove(_ host: SavedHost) {
        hosts.removeAll { $0.id == host.id }
        online[host.id] = nil
        persist()
    }

    /// Probe every saved host's discovery responder.
    public func refresh() {
        for host in hosts {
            probe(host)
        }
    }

    private func probe(_ saved: SavedHost) {
        let conn = NWConnection(
            to: .hostPort(
                host: .init(saved.host),
                port: .init(integerLiteral: saved.pixelPort &+ Self.portOffset)
            ),
            using: .udp
        )
        let id = saved.id
        var finished = false
        let finish: (Bool, String?) -> Void = { [weak self] reachable, freshName in
            guard !finished else { return }
            finished = true
            conn.cancel()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.online[id] = reachable
                if let freshName, !freshName.isEmpty,
                   let idx = self.hosts.firstIndex(where: { $0.id == id }),
                   self.hosts[idx].name != freshName {
                    self.hosts[idx].name = freshName
                    self.persist()
                }
            }
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                conn.send(content: Self.probeMagic, completion: .contentProcessed { _ in })
                conn.receiveMessage { data, _, _, _ in
                    guard let data,
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else {
                        finish(false, nil)
                        return
                    }
                    finish(true, obj["name"] as? String)
                }
            case .failed, .cancelled:
                finish(false, nil)
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .utility))
        // UDP probes into the void never fail on their own — time out.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            finish(false, nil)
        }
    }
}
