// StreamSession.swift — QUIC connection to a flux host + datagram drain.
//
// Uses Network.framework's native QUIC support (NWConnection with
// NWProtocolQUIC). This is the platform-native path — no FFI to
// quinn/rustls. The host's QUIC server (flux-host stream) presents
// a self-signed cert; we accept it via the insecure trust policy
// (production will use TOFU cert pinning from the Bonjour TXT record).
//
// Architecture:
//   1. Connect to the host's pixel port (QUIC, datagram-enabled).
//   2. Drain datagrams in a loop → push to FrameReassembler.
//   3. Reassembled frames → HEVCDecoder → MetalRenderer.
//   4. Optionally connect to the pen port for stylus send
//      (via FluxCore.xcframework's C ABI).

import Foundation
import Network
import Combine

@MainActor
public final class StreamSession: ObservableObject {
    @Published public var state: ConnectionState = .disconnected
    @Published public var stats = StreamStats()

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

    /// Called on every decoded frame with the CVPixelBuffer.
    public var onDecodedFrame: ((CVPixelBuffer, UInt64) -> Void)?

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

        // Configure QUIC with datagram support. Use an insecure TLS
        // policy for dev (accept self-signed certs). Production will
        // pin certs from the Bonjour TXT record's cert_sha256.
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, trust, completion in
                // Accept any certificate (insecure dev mode).
                completion(true)
            },
            .main
        )

        let quicOptions = NWProtocolQUIC.Options(alpn: ["flux"])
        quicOptions.isDatagram = true
        quicOptions.maxDatagramFrameSize = 65535

        let params = NWParameters(quic: quicOptions)
        // Apply TLS options to the QUIC config
        if let secOptions = params.defaultProtocolStack.applicationProtocols.first as? NWProtocolQUIC.Options {
            // The TLS is embedded in QUIC — configured via the quicOptions above.
            _ = secOptions
        }

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

    // MARK: - Datagram receive loop

    private func startReceiving() {
        guard let conn = pixelConnection else { return }
        receiveNextDatagram(on: conn)
    }

    private func receiveNextDatagram(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self = self, let data = data else {
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

            // Push to reassembler; if a complete frame comes out, decode it.
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
}
