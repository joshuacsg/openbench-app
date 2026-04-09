// CertificateStore.swift — TOFU (Trust On First Use) certificate store.
//
// Persists trusted certificate SHA-256 fingerprints in UserDefaults keyed
// by host name. Callers check the trust decision before accepting a TLS
// connection and prompt the user when the cert is new or has changed.

import Foundation

// MARK: - TrustDecision

public enum TrustDecision: Equatable {
    /// The fingerprint matches the stored one — proceed silently.
    case trusted
    /// No fingerprint stored for this host — prompt user to trust.
    case firstSeen
    /// Stored fingerprint differs — possible MITM, warn user.
    case changed(storedSHA: String)
}

// MARK: - CertificateStore

public final class CertificateStore {

    // MARK: Shared instance

    public static let shared = CertificateStore()

    // MARK: Private storage

    private let defaults: UserDefaults
    private let keyPrefix = "CertificateStore.fingerprint."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Public API

    /// Decide whether to trust a connection to `host` presenting `certSHA256`.
    ///
    /// - Parameters:
    ///   - host: The host name (or Bonjour instance name) of the remote peer.
    ///   - certSHA256: Lowercase hex SHA-256 fingerprint of the peer's DER cert.
    /// - Returns: A `TrustDecision` indicating how the caller should proceed.
    public func shouldTrust(host: String, certSHA256: String) -> TrustDecision {
        let key = storageKey(for: host)
        guard let stored = defaults.string(forKey: key) else {
            return .firstSeen
        }
        if stored.lowercased() == certSHA256.lowercased() {
            return .trusted
        }
        return .changed(storedSHA: stored)
    }

    /// Persist `certSHA256` as the trusted fingerprint for `host`.
    ///
    /// Call this after the user explicitly accepts a new or changed certificate.
    public func trust(host: String, certSHA256: String) {
        defaults.set(certSHA256.lowercased(), forKey: storageKey(for: host))
    }

    /// Remove any stored fingerprint for `host`.
    ///
    /// After calling this the next connection attempt will return `.firstSeen`.
    public func forget(host: String) {
        defaults.removeObject(forKey: storageKey(for: host))
    }

    // MARK: Private helpers

    private func storageKey(for host: String) -> String {
        keyPrefix + host
    }
}
