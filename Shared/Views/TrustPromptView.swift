// TrustPromptView.swift — SwiftUI alert shown when a host presents an
// unknown or changed TLS certificate.
//
// Usage:
//   .sheet(item: $session.trustPrompt) { prompt in
//       TrustPromptView(prompt: prompt)
//   }
//
// The caller sets `session.trustPrompt` when the verify block fires with
// a .firstSeen or .changed decision; clearing it dismisses the sheet.

import SwiftUI

// MARK: - TrustPrompt (data passed into the view)

/// Describes the trust situation that triggered the prompt.
public struct TrustPrompt: Identifiable {
    public let id = UUID()
    public let host: String
    public let newSHA: String
    public let decision: TrustDecision     // .firstSeen or .changed(storedSHA:)

    /// "Trust" callback — stores the cert and unblocks the connection.
    public var onTrust: () -> Void
    /// "Cancel" callback — caller should disconnect / abort.
    public var onCancel: () -> Void

    public init(
        host: String,
        newSHA: String,
        decision: TrustDecision,
        onTrust: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.host = host
        self.newSHA = newSHA
        self.decision = decision
        self.onTrust = onTrust
        self.onCancel = onCancel
    }
}

// MARK: - TrustPromptView

/// Sheet/alert-style view presented when the server cert is unknown or has
/// changed. The user can choose to trust the new cert or cancel.
public struct TrustPromptView: View {
    public let prompt: TrustPrompt
    @Environment(\.dismiss) private var dismiss

    public init(prompt: TrustPrompt) {
        self.prompt = prompt
    }

    public var body: some View {
        NavigationStack {
            Form {
                // MARK: Host info
                Section {
                    LabeledContent("Host", value: prompt.host)
                    LabeledContent("Fingerprint (SHA-256)") {
                        Text(truncatedFingerprint(prompt.newSHA))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Certificate Information")
                }

                // MARK: Warning (only when cert changed)
                if case .changed(let storedSHA) = prompt.decision {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .font(.title3)
                            Text(
                                "The certificate for this host has changed. " +
                                "This could indicate a security issue."
                            )
                            .font(.footnote)
                        }
                        LabeledContent("Previous fingerprint") {
                            Text(truncatedFingerprint(storedSHA))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                        LabeledContent("New fingerprint") {
                            Text(truncatedFingerprint(prompt.newSHA))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                    } header: {
                        Text("Security Warning")
                    }
                }

                // MARK: Actions
                Section {
                    Button(trustButtonLabel, role: nil) {
                        prompt.onTrust()
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {
                        prompt.onCancel()
                        dismiss()
                    }
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle(navigationTitle)
#if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
    }

    // MARK: Helpers

    private var navigationTitle: String {
        if case .changed = prompt.decision {
            return "Certificate Changed"
        }
        return "New Certificate"
    }

    private var trustButtonLabel: String {
        if case .changed = prompt.decision {
            return "Trust Anyway"
        }
        return "Trust This Host"
    }

    /// Show first 8 + last 8 hex chars separated by "…" for readability.
    /// Full fingerprint is 64 hex characters.
    private func truncatedFingerprint(_ sha: String) -> String {
        let clean = sha.replacingOccurrences(of: ":", with: "")
        guard clean.count == 64 else { return sha }
        let head = clean.prefix(8)
        let tail = clean.suffix(8)
        return "\(head)…\(tail)"
    }
}

// MARK: - Preview

#if DEBUG
#Preview("First Seen") {
    TrustPromptView(
        prompt: TrustPrompt(
            host: "my-mac.local",
            newSHA: "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9",
            decision: .firstSeen,
            onTrust: {},
            onCancel: {}
        )
    )
}

#Preview("Changed") {
    TrustPromptView(
        prompt: TrustPrompt(
            host: "my-mac.local",
            newSHA: "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9",
            decision: .changed(storedSHA: "deadbeefcafebabe0102030405060708deadbeefcafebabe0102030405060708"),
            onTrust: {},
            onCancel: {}
        )
    )
}
#endif
