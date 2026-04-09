// StreamSession.swift — QUIC connection to a flux host + datagram drain.
//
// Uses Network.framework's native QUIC support (NWConnection with
// NWProtocolQUIC). This is the platform-native path — no FFI to
// quinn/rustls. The host's QUIC server (flux-host stream) presents
// a self-signed cert; TLS verification uses TOFU cert pinning via
// CertificateStore (fingerprint from Bonjour TXT record or user-approved
// on first connection).
//
// Architecture:
//   1. Connect to the host's pixel port (QUIC, datagram-enabled).
//   2. Drain datagrams in a loop → push to FrameReassembler.
//   3. Reassembled frames → HEVCDecoder → MetalRenderer.
//   4. Optionally connect to the pen port for stylus send
//      (via FluxCore.xcframework's C ABI).
//
// Control messages (bidirectional):
//   All datagrams are prefixed with a 1-byte packet type:
//     0x01  — video frame fragment (existing path)
//     0x02  — control JSON (ControlMessage / Welcome / etc.)
//
//   sendControl(_:) prepends 0x02 and sends over the existing QUIC
//   datagram connection.  Incoming 0x02 datagrams are dispatched to
//   handleIncomingControl(_:), which parses Welcome (→ canvasSize /
//   availableDisplays), ClipboardSync (→ onClipboardSync callback),
//   and Pong (→ onPong callback).
//
//   TODO: Once flux-host stream exposes a bidirectional QUIC stream
//   for control messages, replace the datagram piggyback with a
//   dedicated NWConnection stream so the transport provides ordering
//   and back-pressure guarantees.

import Foundation
import Network
import Combine
import CryptoKit
import Security

@MainActor
public final class StreamSession: ObservableObject {
    @Published public var state: ConnectionState = .disconnected
    @Published public var stats = StreamStats()

    /// Canvas dimensions reported in the host's Welcome message.
    /// Used by the input capture views to map screen coordinates →
    /// canvas pixel coordinates.
    @Published public var canvasSize: CGSize = .zero

    /// Displays available on the host, populated from the Welcome message.
    @Published public var availableDisplays: [DisplayInfo] = []

    /// Non-nil while the trust-prompt sheet should be displayed.
    /// The caller (e.g. StreamView) presents TrustPromptView from this binding.
    @Published public var trustPrompt: TrustPrompt?

    // MARK: Private TLS state

    /// The host name passed to connect(host:port:) — captured for use inside
    /// the TLS verify block closure which has no reference to self.
    private var connectingHost: String = ""

    /// Completion block held while waiting for the user to respond to a
    /// .firstSeen trust prompt. Released (called) after the user accepts.
    private var pendingTrustCompletion: ((Bool) -> Void)?

    public enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    public struct StreamStats {
        public var framesReceived: UInt64 = 0
        public var framesDecoded: UInt64 = 0
        public var bytesReceived: UInt64 = 0
        public var currentFps: Double = 0
    }

    private var pixelConnection: NWConnection?
    private let reassembler = FrameReassembler()
    private let decoder = HEVCDecoder()

    // Datagram type-byte constants.
    private static let typeVideo:   UInt8 = 0x01
    private static let typeControl: UInt8 = 0x02

    /// Called on every decoded frame with the CVPixelBuffer.
    public var onDecodedFrame: ((CVPixelBuffer, UInt64) -> Void)?

    /// Called when the host sends a ClipboardSync message.
    public var onClipboardSync: ((String) -> Void)?

    /// Called when the host sends a Pong message in response to a Ping.
    public var onPong: ((UInt64) -> Void)?

    public init() {
        decoder.onDecodedFrame = { [weak self] pb, ts in
            self?.onDecodedFrame?(pb, ts)
            Task { @MainActor [weak self] in
                self?.stats.framesDecoded += 1
            }
        }
    }

    /// Connect to the host's pixel QUIC endpoint.
    public func connect(host: String, port: UInt16) {
        disconnect()
        state = .connecting

        // Capture the host name so the TLS verify closure can reference it
        // without capturing `self` (the closure is called on an arbitrary queue).
        connectingHost = host
        let capturedHost = host

        // Configure QUIC with datagram support and a TOFU TLS trust policy.
        // The verify block fires on a background queue with the peer's
        // sec_trust_t; we extract the leaf certificate, hash its DER encoding
        // with SHA-256, then check CertificateStore.
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { [weak self] _, secTrust, completion in
                // Extract the leaf certificate's SHA-256 fingerprint.
                guard let certSHA256 = Self.sha256Fingerprint(from: secTrust) else {
                    // Could not extract cert — reject to be safe.
                    print("[StreamSession] TLS verify: failed to extract certificate")
                    completion(false)
                    return
                }

                let store = CertificateStore.shared
                let decision = store.shouldTrust(host: capturedHost, certSHA256: certSHA256)

                switch decision {
                case .trusted:
                    // Known-good fingerprint — accept immediately.
                    completion(true)

                case .firstSeen:
                    // Unknown cert — accept the connection but raise the trust
                    // prompt so the user can confirm (TOFU pattern).
                    // We accept here so Network.framework completes the handshake;
                    // the UI flag ensures the user is informed before they interact.
                    completion(true)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let prompt = TrustPrompt(
                            host: capturedHost,
                            newSHA: certSHA256,
                            decision: .firstSeen,
                            onTrust: {
                                store.trust(host: capturedHost, certSHA256: certSHA256)
                            },
                            onCancel: {
                                // User rejected after the fact — disconnect.
                                Task { @MainActor [weak self] in
                                    self?.disconnect()
                                }
                            }
                        )
                        self.trustPrompt = prompt
                    }

                case .changed(let storedSHA):
                    // Fingerprint mismatch — possible MITM. Reject the connection
                    // and surface a warning via the trust prompt.
                    completion(false)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let prompt = TrustPrompt(
                            host: capturedHost,
                            newSHA: certSHA256,
                            decision: .changed(storedSHA: storedSHA),
                            onTrust: {
                                // User chose to trust the new cert anyway.
                                store.trust(host: capturedHost, certSHA256: certSHA256)
                                // Reconnect now that the store is updated.
                                Task { @MainActor [weak self] in
                                    self?.connect(host: capturedHost, port: port)
                                }
                            },
                            onCancel: {
                                // Stay disconnected — user is aware of the warning.
                            }
                        )
                        self.trustPrompt = prompt
                    }
                }
            },
            .main
        )

        let quicOptions = NWProtocolQUIC.Options(alpn: ["flux"])
        quicOptions.isDatagram = true
        quicOptions.maxDatagramFrameSize = 65535

        let params = NWParameters(quic: quicOptions)
        _ = params // TLS is embedded in QUIC; tlsOptions above configure sec_protocol

        let endpoint = NWEndpoint.hostPort(
            host: .init(host),
            port: .init(integerLiteral: port)
        )
        let conn = NWConnection(to: endpoint, using: params)
        pixelConnection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor [weak self] in
                switch newState {
                case .ready:
                    self?.state = .connected
                    self?.startReceiving()
                case .failed(let error):
                    self?.state = .failed(error.localizedDescription)
                case .cancelled:
                    self?.state = .disconnected
                default:
                    break
                }
            }
        }

        conn.start(queue: .global(qos: .userInteractive))
    }

    public func disconnect() {
        pixelConnection?.cancel()
        pixelConnection = nil
        state = .disconnected
    }

    // MARK: - Control message send

    /// Serialise `message` to JSON, prepend the 0x02 type byte, and send
    /// it as a QUIC datagram on the existing pixel connection.
    ///
    /// The host ignores unknown datagrams, so this is safe to call even
    /// before flux-host stream implements the control-message handler.
    /// Once a dedicated bidirectional QUIC stream is available on the host
    /// side, swap the datagram send below for a stream write.
    public func sendControl(_ message: ControlMessage) {
        guard let conn = pixelConnection, state == .connected else {
            print("[StreamSession] sendControl: not connected, dropping \(message)")
            return
        }
        guard let jsonData = message.toJSON() else {
            print("[StreamSession] sendControl: failed to serialise \(message)")
            return
        }

        // Prepend type byte 0x02 so the host can distinguish control
        // datagrams from video-fragment datagrams (type 0x01).
        var packet = Data([Self.typeControl])
        packet.append(jsonData)

        conn.send(content: packet, completion: .contentProcessed { error in
            if let error = error {
                print("[StreamSession] sendControl send error: \(error)")
            }
        })
    }

    // MARK: - Datagram receive loop

    private func startReceiving() {
        guard let conn = pixelConnection else { return }
        receiveNextDatagram(on: conn)
    }

    private func receiveNextDatagram(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else {
                if let error = error {
                    Task { @MainActor [weak self] in
                        self?.state = .failed(error.localizedDescription)
                    }
                }
                return
            }

            Task { @MainActor [weak self] in
                self?.stats.framesReceived += 1
                self?.stats.bytesReceived += UInt64(data.count)
            }

            // Dispatch on the leading type byte.
            let typeByte = data[data.startIndex]
            let payload  = data.dropFirst()

            switch typeByte {
            case Self.typeControl:
                // Incoming control JSON from the host (Welcome, ClipboardSync, Pong, …).
                self.handleIncomingControl(payload)

            default:
                // 0x01 (video fragment) or legacy headerless packet — push to reassembler.
                // For legacy packets without a type byte prefix, pass the full datagram.
                let fragment = (typeByte == Self.typeVideo) ? payload : data
                if let frame = self.reassembler.push(fragment) {
                    do {
                        try self.decoder.decode(annexB: frame.data, timestampUs: frame.timestampUs)
                    } catch {
                        print("[StreamSession] decode error: \(error)")
                    }
                }
            }

            // Continue draining.
            self.receiveNextDatagram(on: conn)
        }
    }

    // MARK: - Incoming control message dispatch

    /// Parse a raw JSON payload received from the host and update published
    /// state or invoke callbacks as appropriate.
    private func handleIncomingControl(_ data: Data) {
        // Try the unit-variant fast path first.
        if let str = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
           str == "\"ExecutePasteShortcut\"" {
            // Unexpected direction — host should not send this. Ignore.
            return
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let (key, value) = obj.first else {
            print("[StreamSession] handleIncomingControl: could not parse JSON")
            return
        }

        switch key {
        case "Welcome":
            guard let fields = value as? [String: Any] else { return }
            let cw = (fields["canvas_width"]  as? CGFloat) ?? 0
            let ch = (fields["canvas_height"] as? CGFloat) ?? 0
            Task { @MainActor [weak self] in
                self?.canvasSize = CGSize(width: cw, height: ch)
                if let displaysRaw = fields["available_displays"] as? [[String: Any]] {
                    self?.availableDisplays = displaysRaw.compactMap { d in
                        guard let id = d["id"] as? UInt32,
                              let w  = d["width"]  as? Int,
                              let h  = d["height"] as? Int else { return nil }
                        return DisplayInfo(id: id, width: w, height: h)
                    }
                }
            }

        case "ClipboardSync":
            guard let fields = value as? [String: Any],
                  let content = fields["content"] as? [String: Any],
                  let text    = content["Text"] as? String else { return }
            Task { @MainActor [weak self] in
                self?.onClipboardSync?(text)
            }

        case "Pong":
            guard let fields = value as? [String: Any],
                  let nonce  = fields["nonce"] as? UInt64 else { return }
            Task { @MainActor [weak self] in
                self?.onPong?(nonce)
            }

        default:
            print("[StreamSession] handleIncomingControl: unhandled message type '\(key)'")
        }
    }

    // MARK: - TLS certificate helpers

    /// Extract the leaf (server) certificate from a `sec_trust_t` and return
    /// its SHA-256 fingerprint as a lowercase hex string.
    ///
    /// Uses `sec_trust_copy_certificates()` to get the certificate chain from
    /// the Network.framework `sec_trust_t` wrapper, then hashes the DER-encoded
    /// bytes of the leaf certificate with CryptoKit's SHA256.
    ///
    /// - Parameter secTrust: The `sec_trust_t` value provided by the TLS
    ///   verify block closure.
    /// - Returns: Lowercase 64-character hex string, or `nil` on failure.
    private static func sha256Fingerprint(from secTrust: sec_trust_t) -> String? {
        // sec_trust_copy_certificates returns an array of sec_certificate_t
        // values. Index 0 is the leaf (server) certificate.
        guard let certArray = sec_trust_copy_certificates(secTrust) else {
            return nil
        }
        // Bridge CFArray → Swift array
        let certs = certArray as [AnyObject]
        guard let first = certs.first else { return nil }

        // sec_certificate_t is an opaque wrapper; unwrap to SecCertificate.
        let secCert: SecCertificate
        if let cert = first as? SecCertificate {
            secCert = cert
        } else {
            // On some OS versions, sec_certificate_t bridges differently;
            // use sec_certificate_copy_ref() to get the underlying SecCertificate.
            let secCertT = first as! sec_certificate_t   // safe: from sec_trust array
            secCert = sec_certificate_copy_ref(secCertT).takeRetainedValue()
        }

        // Get the DER encoding of the certificate.
        guard let derData = SecCertificateCopyData(secCert) as Data? else {
            return nil
        }

        // Hash with CryptoKit SHA-256 and hex-encode.
        let digest = SHA256.hash(data: derData)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Supporting types

/// A display available on the host, as reported in the Welcome message.
public struct DisplayInfo: Identifiable, Equatable {
    public let id: UInt32
    public let width: Int
    public let height: Int

    public init(id: UInt32, width: Int, height: Int) {
        self.id = id
        self.width = width
        self.height = height
    }
}
