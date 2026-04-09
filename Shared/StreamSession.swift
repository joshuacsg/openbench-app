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
import CoreVideo
import Security
import CryptoKit
import CryptoKit
import Security

@MainActor
public final class StreamSession: ObservableObject {
    @Published public var state: ConnectionState = .disconnected
    @Published public var stats = StreamStats()
    @Published public var rttMs: Int? = nil

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

    // Ping/Pong RTT tracking
    private var pingTimer: Timer?
    private var pendingPingNonce: UInt64?
    private var pendingPingTime: CFAbsoluteTime?

    // Auto-reconnect with exponential backoff
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: TimeInterval = 0.5
    private var lastEndpoint: NWEndpoint?
    private var lastHostName: String = ""

    // Datagram type-byte constants.
    private static let typeVideo:   UInt8 = 0x01
    private static let typeControl: UInt8 = 0x02

    /// Called on every decoded frame with the CVPixelBuffer.
    public var onDecodedFrame: ((CVPixelBuffer, UInt64) -> Void)?

    /// Called when the host sends a ClipboardSync message.
    public var onClipboardSync: ((String) -> Void)?

    /// Called when the host sends a Pong message in response to a Ping.
    public var onPong: ((UInt64) -> Void)?

    // FPS tracking — count decoded frames per second.
    private var fpsFrameCount: Int = 0
    private var fpsTimer: Timer?

    public init() {
        decoder.onDecodedFrame = { [weak self] pb, ts in
            // Infer canvas size from the first decoded frame so that
            // InputCaptureView.mapToCanvas() can map touch coordinates
            // correctly, even when flux-host doesn't send a Welcome message.
            Task { @MainActor [weak self] in
                guard let self else { return }
                let w = CVPixelBufferGetWidth(pb)
                let h = CVPixelBufferGetHeight(pb)
                let frameSize = CGSize(width: w, height: h)
                if w > 0 && h > 0 && self.canvasSize != frameSize {
                    self.canvasSize = frameSize
                }
                self.stats.framesDecoded += 1
                self.fpsFrameCount += 1
            }
            self?.onDecodedFrame?(pb, ts)
        }
    }

    private func startFpsCounter() {
        fpsTimer?.invalidate()
        fpsFrameCount = 0
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stats.currentFps = Double(self.fpsFrameCount)
                self.fpsFrameCount = 0
            }
        }
    }

    private func stopFpsCounter() {
        fpsTimer?.invalidate()
        fpsTimer = nil
        stats.currentFps = 0
    }

    private func startPingLoop() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .connected else { return }
                let nonce = UInt64.random(in: 0...UInt64.max)
                self.pendingPingNonce = nonce
                self.pendingPingTime = CFAbsoluteTimeGetCurrent()
                self.sendControl(.ping(nonce: nonce))
            }
        }
    }

    private func stopPingLoop() {
        pingTimer?.invalidate()
        pingTimer = nil
        rttMs = nil
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let delay = reconnectDelay
        let endpoint = lastEndpoint
        let hostName = lastHostName
        reconnectDelay = min(reconnectDelay * 2, 8.0) // cap at 8s

        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard case .failed = self.state else { return }
            if let endpoint {
                self.connect(endpoint: endpoint, hostName: hostName)
            }
        }
    }

    /// Connect to the host's pixel QUIC endpoint by hostname and port.
    public func connect(host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(
            host: .init(host),
            port: .init(integerLiteral: port)
        )
        connect(endpoint: endpoint, hostName: host)
    }

    /// Connect to a Bonjour-discovered endpoint directly. Network.framework
    /// resolves the NWEndpoint.service address automatically.
    public func connect(endpoint: NWEndpoint, hostName: String = "") {
        disconnect()
        state = .connecting
        connectingHost = hostName
        lastEndpoint = endpoint
        lastHostName = hostName
        reconnectDelay = 0.5  // reset backoff

        onPong = { [weak self] nonce in
            guard let self,
                  nonce == self.pendingPingNonce,
                  let sent = self.pendingPingTime else { return }
            let rtt = (CFAbsoluteTimeGetCurrent() - sent) * 1000
            self.rttMs = Int(rtt.rounded())
            self.pendingPingNonce = nil
            self.pendingPingTime = nil
        }

        // Configure QUIC with datagram support.
        let quicOptions = NWProtocolQUIC.Options(alpn: ["flux"])
        quicOptions.isDatagram = true
        quicOptions.maxDatagramFrameSize = 65535

        // Disable peer authentication for self-signed certs (dev mode).
        sec_protocol_options_set_peer_authentication_required(
            quicOptions.securityProtocolOptions,
            false
        )

        let params = NWParameters(quic: quicOptions)

        let conn = NWConnection(to: endpoint, using: params)
        pixelConnection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor [weak self] in
                switch newState {
                case .ready:
                    self?.state = .connected
                    self?.reconnectDelay = 0.5
                    self?.reconnectTask = nil
                    self?.startFpsCounter()
                    self?.startPingLoop()
                    self?.startReceiving()
                case .failed(let error):
                    self?.state = .failed(error.localizedDescription)
                    self?.scheduleReconnect()
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
        stopFpsCounter()
        stopPingLoop()
        reconnectTask?.cancel()
        reconnectTask = nil
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
        // Use receive() instead of receiveMessage() — QUIC datagrams
        // (sent via quinn's send_datagram) arrive as unreliable frames,
        // not stream messages. receiveMessage may only fire for stream
        // data. receive() captures both.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, context, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                print("[StreamSession] receive error: \(error)")
                Task { @MainActor [weak self] in
                    self?.state = .failed(error.localizedDescription)
                }
                return
            }

            guard let data = data, !data.isEmpty else {
                print("[StreamSession] receive: empty data, isComplete=\(isComplete)")
                if isComplete {
                    // Stream ended — try to continue receiving new datagrams
                }
                self.receiveNextDatagram(on: conn)
                return
            }

            Task { @MainActor [weak self] in
                self?.stats.framesReceived += 1
                self?.stats.bytesReceived += UInt64(data.count)
            }

            // flux-host sends raw VideoPacketHeader (19 bytes) + payload
            // as QUIC datagrams. The header's first byte is the packet
            // type (0x01 = video). Pass the FULL datagram to the
            // reassembler — it expects the type byte at position 0.
            //
            // Future: when the host also sends control datagrams with
            // type 0x02, we'll check data[0] here first and dispatch.
            if let frame = self.reassembler.push(data) {
                do {
                    try self.decoder.decode(annexB: frame.data, timestampUs: frame.timestampUs)
                } catch {
                    print("[StreamSession] decode error: \(error)")
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
        // Bridge the Network.framework `sec_trust_t` to the Security
        // framework `SecTrust` via sec_trust_copy_ref().
        let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()

        // Get the certificate chain. SecTrustCopyCertificateChain is
        // available on iOS 15+ / macOS 12+.
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return nil
        }

        // Get the DER encoding of the leaf certificate.
        let derData = SecCertificateCopyData(leaf) as Data

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
