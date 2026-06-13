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
import QuartzCore
import Network
import Combine
import CoreVideo
import CoreImage
import ImageIO
import Security
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

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

    /// Per-display JPEG snapshots from the host (display sidebar).
    /// Populated on demand after sending .requestDisplayThumbnails.
    @Published public var displayThumbnails: [UInt32: CGImage] = [:]

    /// In-flight thumbnail chunk reassembly, keyed by display id.
    /// Only touched from the receive queue.
    private var thumbnailChunks: [UInt32: (generation: UInt32, total: Int, parts: [Int: String])] = [:]

#if canImport(UIKit)
    /// Low-rate thumbnail for the minimap (~5 fps).
    @Published public var thumbnail: UIImage?
    private var lastThumbnailTime: CFAbsoluteTime = 0
#endif

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
        /// Host pipeline delay (capture → encode done), in ms, rolling.
        /// Only populated when the host emits FrameTiming (FLUX_FRAME_TIMING).
        /// `nil` until the first correlated frame arrives, so the HUD can
        /// hide the breakdown when no timing data is present.
        public var hostPdMs: Double? = nil
        /// Host send-queue delay (encode done → sent), in ms, rolling.
        public var hostQueueMs: Double? = nil
    }

    private var pixelConnection: NWConnection?
    private let reassembler = FrameReassembler()
    private let decoder = HEVCDecoder()

    // Pen flow: dedicated QUIC connection (RFC-0002 dual-flow) so
    // 240 Hz stylus samples never queue behind pixel traffic.
    private var penConnection: NWConnection?
    private var penPort: UInt16 = 9001
    private var penReady = false

    // Ping/Pong RTT tracking
    private var pingTimer: Timer?
    private var pendingPingNonce: UInt64?
    private var pendingPingTime: CFAbsoluteTime?

    // Loss recovery: ask the host for a keyframe when the reassembler
    // discards an incomplete frame, instead of showing corruption /
    // freeze until the next interval keyframe. Rate-limited.
    private var lastSeenDiscarded: UInt64 = 0

    // Drop-to-live watchdog. The decode chain cannot skip P-frames, so
    // when decoding falls behind arrival the backlog hides inside
    // Network.framework and end-to-end delay grows without bound. We
    // measure lag drift via host frame timestamps (constant clock
    // offset cancels out against the session minimum) and, past the
    // threshold, stop decoding, drain to live, and resync on a fresh
    // keyframe.
    private var lagBaselineUs: Int64?
    private var skippingUntilKeyframe = false
    private static let maxLagMs: Double = 500

    // Host-side FrameTiming correlation. The host (flux-stream, only
    // when FLUX_FRAME_TIMING is set) sends a FrameTiming control message
    // per frame; we stash it keyed by capture_us — which equals the
    // frame's capture timestamp_us carried in the video packet header /
    // ReassembledFrame.timestampUs — then look it up when that frame is
    // displayed to break the latency down by host stage.
    //
    // All accessed on the receive queue (handleIncomingControl and
    // handleCompletedFrame both run there), so no extra locking is
    // needed. Bounded to the most recent entries; lossy QUIC datagrams
    // mean some timing messages or frames go missing, so eviction is
    // by age (insertion order) rather than exact pairing.
    private struct HostFrameTiming {
        let encodeDoneUs: UInt64
        let sentUs: UInt64
    }
    private var frameTimings: [UInt64: HostFrameTiming] = [:]
    private var frameTimingOrder: [UInt64] = []   // capture_us, oldest first
    private static let maxFrameTimings = 240       // ~2 s at 120 fps
    /// Rolling host PD / queue, exponentially smoothed. Flushed to the
    /// @Published stats only on change of the displayed frame so the HUD
    /// doesn't churn the main actor.
    private var rollingHostPdMs: Double?
    private var rollingHostQueueMs: Double?
    /// Require this many CONSECUTIVE over-threshold frames before
    /// dropping to live, so a single anomalous timestamp (e.g. a host
    /// idle re-emit) can't trigger a spurious keyframe storm on an
    /// otherwise-healthy stream. See RFC-0009 #1 (defense in depth).
    private var consecutiveLaggedFrames = 0
    private static let lagTripCount = 3
    /// True once any connection has reached `.ready`; gates the
    /// reconnect-only decode-pipeline reset. See RFC-0009 #2.
    private var hasBecomeReady = false

    /// Shared rate limit for ALL keyframe requests (loss detector +
    /// lag watchdog) so concurrent triggers can't storm the host.
    private var lastKeyframeRequestSent: CFAbsoluteTime = 0

    /// Set by the UI when the minimap is visible; thumbnail generation
    /// is skipped entirely otherwise (it was costing a full-resolution
    /// CIContext render per tick even when hidden).
    public var thumbnailEnabled = false

    /// Decode-thread frame counter, drained by the 1 Hz fps timer —
    /// avoids a MainActor hop per decoded frame.
    private let decodeCountLock = NSLock()
    private var decodedSinceLastTick: Int = 0
    private var lastKnownCanvas: CGSize = .zero
    private static let thumbnailCIContext = CIContext(options: [.useSoftwareRenderer: false])

    // Stats accumulated on the receive queue and flushed to the
    // @Published struct at ~2 Hz — a per-datagram MainActor hop (450/s
    // at 5 Mbps) is real overhead on the path that must outrun the
    // network.
    private var pendingRecvBytes: UInt64 = 0
    private var pendingRecvCount: UInt64 = 0
    private var lastStatsFlush: CFAbsoluteTime = 0

    // Periodic QualityFeedback for the host's AIMD bitrate controller.
    private var feedbackTimer: Timer?
    private var lastFeedbackBytes: UInt64 = 0
    private var lastFeedbackDiscarded: UInt64 = 0
    private var lastFeedbackFrames: UInt64 = 0

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

    /// Called once per connection with the resolved remote IP + pixel
    /// port (Bonjour endpoints resolve at connect time). Used to
    /// persist hosts for off-LAN reconnection.
    public var onResolvedEndpoint: ((String, UInt16) -> Void)?

    // FPS tracking — count decoded frames per second.
    private var fpsFrameCount: Int = 0
    private var fpsTimer: Timer?

    public init() {
        decoder.onDecodedFrame = { [weak self] pb, ts in
            guard let self else { return }
            // Stay off the main actor on this per-frame path: count
            // frames under a cheap lock (drained by the 1 Hz fps
            // timer) and only hop for rare events.
            self.decodeCountLock.lock()
            self.decodedSinceLastTick += 1
            self.decodeCountLock.unlock()

            // Infer canvas size from the first decoded frame (and on
            // change) so InputCaptureView.mapToCanvas() works even when
            // the host doesn't send a Welcome.
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            let frameSize = CGSize(width: w, height: h)
            if w > 0 && h > 0 && self.lastKnownCanvas != frameSize {
                self.lastKnownCanvas = frameSize
                Task { @MainActor [weak self] in
                    self?.canvasSize = frameSize
                }
            }
#if canImport(UIKit)
            // Minimap thumbnail at ~5 fps, only while the minimap is
            // visible. Render off-main with a cached CIContext at
            // minimap scale (was: fresh CIContext + full-res render on
            // the main thread, even when hidden).
            if self.thumbnailEnabled {
                let now = CFAbsoluteTimeGetCurrent()
                if now - self.lastThumbnailTime > 0.2 {
                    self.lastThumbnailTime = now
                    if let image = Self.thumbnailFromPixelBuffer(pb) {
                        Task { @MainActor [weak self] in
                            self?.thumbnail = image
                        }
                    }
                }
            }
#endif
            self.onDecodedFrame?(pb, ts)
        }
    }

    private func startFpsCounter() {
        fpsTimer?.invalidate()
        decodeCountLock.lock()
        decodedSinceLastTick = 0
        decodeCountLock.unlock()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.decodeCountLock.lock()
                let n = self.decodedSinceLastTick
                self.decodedSinceLastTick = 0
                self.decodeCountLock.unlock()
                self.stats.currentFps = Double(n)
                self.stats.framesDecoded += UInt64(n)
            }
        }
        // .common keeps stats/ping/feedback alive during UI tracking
        // (drags/scrolls park .default-mode timers).
        RunLoop.main.add(timer, forMode: .common)
        fpsTimer = timer
    }

    private func stopFpsCounter() {
        fpsTimer?.invalidate()
        fpsTimer = nil
        stats.currentFps = 0
    }

    private func startPingLoop() {
        pingTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            Task { @MainActor [weak self] in
                guard let self, self.state == .connected else { return }
                let nonce = UInt64.random(in: 0...UInt64.max)
                self.pendingPingNonce = nonce
                self.pendingPingTime = CFAbsoluteTimeGetCurrent()
                self.sendControl(.ping(nonce: nonce))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func stopPingLoop() {
        pingTimer?.invalidate()
        pingTimer = nil
        rttMs = nil
    }

    /// Store one host FrameTiming, keyed by capture_us, with age-bounded
    /// eviction. Runs on the receive queue.
    private func storeFrameTiming(captureUs: UInt64, encodeDoneUs: UInt64, sentUs: UInt64) {
        if frameTimings[captureUs] == nil {
            frameTimingOrder.append(captureUs)
        }
        frameTimings[captureUs] = HostFrameTiming(encodeDoneUs: encodeDoneUs, sentUs: sentUs)
        while frameTimingOrder.count > Self.maxFrameTimings {
            let oldest = frameTimingOrder.removeFirst()
            frameTimings.removeValue(forKey: oldest)
        }
    }

    /// Correlate the displayed frame's capture timestamp with a stored
    /// host FrameTiming and fold the host PD / queue split into the
    /// rolling values. Returns true if a matching timing was found (so
    /// the HUD breakdown becomes available). Runs on the receive queue.
    @discardableResult
    private func correlateHostTiming(captureUs: UInt64) -> Bool {
        guard let t = frameTimings[captureUs] else { return false }
        // Host-monotonic µs from the same clock: differences are valid
        // even though the host clock base differs from ours. Guard
        // against a non-monotonic pair (clock glitch / reordered fields)
        // producing a negative span.
        let pdMs    = t.encodeDoneUs >= captureUs
            ? Double(t.encodeDoneUs &- captureUs) / 1000.0 : 0
        let queueMs = t.sentUs >= t.encodeDoneUs
            ? Double(t.sentUs &- t.encodeDoneUs) / 1000.0 : 0

        // Light EMA so the HUD reads a stable number, not per-frame jitter.
        let alpha = 0.2
        rollingHostPdMs    = rollingHostPdMs.map    { $0 * (1 - alpha) + pdMs * alpha }    ?? pdMs
        rollingHostQueueMs = rollingHostQueueMs.map { $0 * (1 - alpha) + queueMs * alpha } ?? queueMs

        // Drop the consumed entry (and anything older — those frames are
        // already on screen or were dropped) to keep the map small.
        if let idx = frameTimingOrder.firstIndex(of: captureUs) {
            for key in frameTimingOrder[...idx] { frameTimings.removeValue(forKey: key) }
            frameTimingOrder.removeSubrange(...idx)
        } else {
            frameTimings.removeValue(forKey: captureUs)
        }

        let pd = rollingHostPdMs
        let queue = rollingHostQueueMs
        Task { @MainActor [weak self] in
            self?.stats.hostPdMs = pd
            self?.stats.hostQueueMs = queue
        }
        return true
    }

    /// Decode a reassembled frame, unless we've fallen behind live —
    /// then drain without decoding until the next keyframe so delay
    /// stays bounded instead of compounding.
    private func handleCompletedFrame(_ frame: FrameReassembler.ReassembledFrame) {
        // Correlate host timing for this frame (no-op unless the host is
        // emitting FrameTiming). frame.timestampUs IS the capture_us key.
        correlateHostTiming(captureUs: frame.timestampUs)

        // Monotonic clock: CFAbsoluteTime is wall time and NTP steps
        // would permanently poison the lag baseline (a backwards step
        // ratchets the minimum down → every later frame reads as lagged
        // → endless resync slideshow).
        let nowUs = Int64(CACurrentMediaTime() * 1_000_000)
        let offset = nowUs &- Int64(bitPattern: UInt64(frame.timestampUs))

        // Track the session-minimum offset as the "zero lag" baseline;
        // clock bases differ between host and viewer but the offset is
        // constant, so growth above the minimum is pure queueing delay.
        if let base = lagBaselineUs {
            if offset < base { lagBaselineUs = offset }
            // A wildly different offset (> 60 s either way) means the
            // host's timestamp base changed (pipeline restart on the
            // legacy path) — re-baseline rather than skip forever.
            if abs(offset - base) > 60_000_000 { lagBaselineUs = offset }
        } else {
            lagBaselineUs = offset
        }
        let lagMs = Double(offset - (lagBaselineUs ?? offset)) / 1000.0

        if skippingUntilKeyframe {
            if frame.isKeyframe {
                skippingUntilKeyframe = false
                consecutiveLaggedFrames = 0
                // If the backlog is drained and lag STILL exceeds the
                // threshold, it's standing transport delay (path change,
                // bufferbloat), not decoder queueing — re-anchor the
                // baseline instead of resyncing forever.
                if lagMs > Self.maxLagMs {
                    lagBaselineUs = offset
                    print("[StreamSession] re-anchored lag baseline (+\(Int(lagMs)) ms standing delay)")
                } else {
                    print("[StreamSession] resynced to live on keyframe (lag was \(Int(lagMs)) ms)")
                }
            } else {
                return // draining to live — skip decode entirely
            }
        } else if lagMs > Self.maxLagMs {
            // Only drop to live after several consecutive lagged frames:
            // a lone bad timestamp shouldn't storm the host.
            consecutiveLaggedFrames += 1
            if consecutiveLaggedFrames >= Self.lagTripCount {
                skippingUntilKeyframe = !frame.isKeyframe
                print("[StreamSession] \(Int(lagMs)) ms behind live (\(consecutiveLaggedFrames)×) — dropping to live, requesting keyframe")
                requestKeyframe()
                if skippingUntilKeyframe { return }
            }
        } else {
            consecutiveLaggedFrames = 0
        }

        do {
            try decoder.decode(annexB: frame.data, timestampUs: frame.timestampUs)
        } catch {
            print("[StreamSession] decode error: \(error)")
        }
    }

    /// If the reassembler discarded an incomplete frame since we last
    /// looked, ask the host for a keyframe (recovery in ~1 RTT instead
    /// of waiting out the keyframe interval). At most one request per
    /// 250 ms.
    private func requestKeyframeIfLossDetected() {
        let discarded = reassembler.discarded
        guard discarded > lastSeenDiscarded else { return }
        lastSeenDiscarded = discarded
        print("[StreamSession] frame lost (discards=\(discarded), FEC recoveries=\(reassembler.recovered)) — requesting keyframe")
        requestKeyframe()
    }

    /// Single funnel (and rate limit) for keyframe requests from both
    /// the loss detector and the lag watchdog.
    private func requestKeyframe() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastKeyframeRequestSent >= 0.25 else { return }
        lastKeyframeRequestSent = now
        sendControl(.requestKeyframe)
    }

    private func startFeedbackLoop() {
        feedbackTimer?.invalidate()
        lastFeedbackBytes = stats.bytesReceived
        lastFeedbackDiscarded = reassembler.discarded
        lastFeedbackFrames = stats.framesReceived
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            Task { @MainActor [weak self] in
                guard let self, self.state == .connected else { return }
                let bytes = self.stats.bytesReceived
                let deliveredNow = self.reassembler.delivered
                let discards = self.reassembler.discarded
                let dBytes = bytes &- self.lastFeedbackBytes
                let dDelivered = deliveredNow &- self.lastFeedbackFrames
                let dDiscards = discards &- self.lastFeedbackDiscarded
                self.lastFeedbackBytes = bytes
                self.lastFeedbackFrames = deliveredNow
                self.lastFeedbackDiscarded = discards

                // True frame-loss ratio: lost / (lost + delivered).
                // (The old datagram denominator diluted loss ~10-25×,
                // leaving the host's AIMD controller effectively blind.)
                let lossPct: Float = (dDiscards + dDelivered) > 0
                    ? Float(dDiscards) / Float(dDiscards + dDelivered) * 100.0
                    : 0
                let bandwidthKbps = UInt32(dBytes * 8 / 2 / 1000)
                self.sendControl(.qualityFeedback(
                    rttMs: UInt32(self.rttMs ?? 0),
                    lossPct: lossPct,
                    bandwidthKbps: bandwidthKbps
                ))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        feedbackTimer = timer
    }

    private func stopFeedbackLoop() {
        feedbackTimer?.invalidate()
        feedbackTimer = nil
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
    public func connect(host: String, port: UInt16, penPort: UInt16? = nil) {
        let endpoint = NWEndpoint.hostPort(
            host: .init(host),
            port: .init(integerLiteral: port)
        )
        connect(endpoint: endpoint, hostName: host, penPort: penPort ?? (port &+ 1))
    }

    /// Connect to a Bonjour-discovered endpoint directly. Network.framework
    /// resolves the NWEndpoint.service address automatically.
    public func connect(endpoint: NWEndpoint, hostName: String = "", penPort: UInt16 = 9001) {
        disconnect()
        self.penPort = penPort
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

        conn.stateUpdateHandler = { [weak self, weak conn] newState in
            Task { @MainActor [weak self] in
                guard let self, let conn, conn === self.pixelConnection else {
                    // Stale callback from a replaced connection — a late
                    // .failed/.cancelled here used to clobber the state
                    // of the healthy new session and even tear it down
                    // via a spurious reconnect.
                    return
                }
                switch newState {
                case .ready:
                    // On RECONNECT (not first connect), clear stale decode
                    // + watchdog state. A surviving lagBaselineUs or
                    // skippingUntilKeyframe from the dead connection would
                    // drop every frame until a keyframe — which on a
                    // static screen can be seconds away. See RFC-0009 #2.
                    if self.hasBecomeReady {
                        self.resetDecodePipeline()
                    }
                    self.hasBecomeReady = true
                    self.state = .connected
                    self.reconnectDelay = 0.5
                    self.reconnectTask = nil
                    self.startFpsCounter()
                    self.startPingLoop()
                    self.startFeedbackLoop()
                    self.startReceiving()
                    self.startPenConnection()
                    if case .hostPort(let h, let p)? = conn.currentPath?.remoteEndpoint {
                        self.onResolvedEndpoint?("\(h)", p.rawValue)
                    }
                case .failed(let error):
                    self.state = .failed(error.localizedDescription)
                    self.scheduleReconnect()
                case .cancelled:
                    self.state = .disconnected
                default:
                    break
                }
            }
        }

        conn.start(queue: .global(qos: .userInteractive))
    }

    /// Reset the decode pipeline (decoder + reassembler) so new frames
    /// from a different display/resolution start clean. Call this before
    /// sending SetActiveDisplay.
    public func resetDecodePipeline() {
        decoder.reset()
        reassembler.reset()
        lagBaselineUs = nil
        skippingUntilKeyframe = false
        consecutiveLaggedFrames = 0
        frameTimings.removeAll()
        frameTimingOrder.removeAll()
        rollingHostPdMs = nil
        rollingHostQueueMs = nil
    }

    public func disconnect() {
        stopFpsCounter()
        stopPingLoop()
        stopFeedbackLoop()
        reconnectTask?.cancel()
        reconnectTask = nil
        pixelConnection?.cancel()
        pixelConnection = nil
        penConnection?.cancel()
        penConnection = nil
        penReady = false
        state = .disconnected
    }

    // MARK: - Pen flow (stylus)

    /// Open the dedicated pen QUIC connection. Called when the pixel
    /// connection is ready, so Bonjour endpoints are already resolved
    /// to a concrete host we can pair with the pen port.
    private func startPenConnection() {
        penConnection?.cancel()
        penReady = false

        guard let path = pixelConnection?.currentPath,
              case .hostPort(let host, _)? = path.remoteEndpoint else {
            print("[StreamSession] pen: no resolved host yet — stylus falls back to mouse events")
            return
        }

        let quicOptions = NWProtocolQUIC.Options(alpn: ["flux"])
        quicOptions.isDatagram = true
        quicOptions.maxDatagramFrameSize = 65535
        sec_protocol_options_set_peer_authentication_required(
            quicOptions.securityProtocolOptions,
            false
        )
        let conn = NWConnection(
            to: .hostPort(host: host, port: .init(integerLiteral: penPort)),
            using: NWParameters(quic: quicOptions)
        )
        penConnection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] newState in
            Task { @MainActor [weak self] in
                guard let self, let conn, conn === self.penConnection else { return }
                switch newState {
                case .ready:
                    self.penReady = true
                    print("[StreamSession] pen flow connected (:\(self.penPort))")
                case .failed, .cancelled:
                    self.penReady = false
                default:
                    break
                }
            }
        }
        conn.start(queue: .global(qos: .userInteractive))
    }

    /// True when the active network path is cellular / metered, so the
    /// UI can warn before sending a large clipboard blob.
    public var isExpensivePath: Bool {
        pixelConnection?.currentPath?.isExpensive ?? false
    }

    /// Send a large clipboard payload to the host over a dedicated
    /// reliable QUIC stream (stream mode, not datagrams) to the pen
    /// port. Opens, sends one framed blob, closes. `onComplete` is
    /// invoked on the main actor with success/failure.
    public func sendClipboardBlob(_ blob: ClipboardBlobData, onComplete: ((Bool) -> Void)? = nil) {
        guard let path = pixelConnection?.currentPath,
              case .hostPort(let host, _)? = path.remoteEndpoint else {
            print("[StreamSession] clipboard: no resolved host — cannot send blob")
            onComplete?(false)
            return
        }

        let quicOptions = NWProtocolQUIC.Options(alpn: ["flux"])
        quicOptions.isDatagram = false // reliable stream for the bulk blob
        sec_protocol_options_set_peer_authentication_required(
            quicOptions.securityProtocolOptions,
            false
        )
        let conn = NWConnection(
            to: .hostPort(host: host, port: .init(integerLiteral: penPort)),
            using: NWParameters(quic: quicOptions)
        )
        let payload = blob.encodeWire()
        conn.stateUpdateHandler = { newState in
            switch newState {
            case .ready:
                // isComplete: true closes the send side (stream FIN) so
                // the host's read_to_end completes.
                conn.send(content: payload, isComplete: true,
                          completion: .contentProcessed { error in
                    let ok = (error == nil)
                    if let error {
                        print("[StreamSession] clipboard send error: \(error)")
                    } else {
                        print("[StreamSession] clipboard blob sent (\(payload.count) bytes)")
                    }
                    if let onComplete { DispatchQueue.main.async { onComplete(ok) } }
                    // Let the FIN flush before tearing the connection down.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                        conn.cancel()
                    }
                })
            case .failed(let e):
                print("[StreamSession] clipboard connection failed: \(e)")
                if let onComplete { DispatchQueue.main.async { onComplete(false) } }
                conn.cancel()
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    /// Ship one stylus sample on the pen flow; falls back to plain
    /// mouse events (no pressure) when the pen connection is down so
    /// the Pencil always draws something.
    public func sendStylusSample(_ sample: StylusSampleData) {
        if penReady, let conn = penConnection {
            conn.send(content: sample.encodeWire(), completion: .idempotent)
            return
        }
        guard !sample.predicted else { return }
        switch sample.phase {
        case 1:
            sendControl(.mouseMove(x: Int32(sample.x), y: Int32(sample.y), absolute: true))
            sendControl(.mouseButton(button: 0, pressed: true))
        case 3, 4:
            sendControl(.mouseButton(button: 0, pressed: false))
        default:
            sendControl(.mouseMove(x: Int32(sample.x), y: Int32(sample.y), absolute: true))
        }
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
                    guard let self, conn === self.pixelConnection else { return }
                    self.state = .failed(error.localizedDescription)
                    // The state handler doesn't always see a .failed
                    // transition for receive-side errors; without this
                    // the loop died and the stream froze with no
                    // recovery.
                    self.scheduleReconnect()
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

            // Accumulate on the receive queue; flush to @Published at
            // ~2 Hz instead of hopping to the main actor per datagram.
            self.pendingRecvBytes &+= UInt64(data.count)
            self.pendingRecvCount &+= 1
            let nowAbs = CFAbsoluteTimeGetCurrent()
            if nowAbs - self.lastStatsFlush >= 0.5 {
                self.lastStatsFlush = nowAbs
                let bytes = self.pendingRecvBytes
                let count = self.pendingRecvCount
                self.pendingRecvBytes = 0
                self.pendingRecvCount = 0
                Task { @MainActor [weak self] in
                    self?.stats.framesReceived += count
                    self?.stats.bytesReceived += bytes
                }
            }

            // Dispatch by type byte: 0x01 = video, 0x02 = control JSON.
            let typeByte = data[data.startIndex]
            if typeByte == Self.typeControl {
                // Strip the type byte and handle the JSON payload.
                let json = data.dropFirst()
                self.handleIncomingControl(Data(json))
            } else {
                // Video fragment — pass full datagram (including type byte)
                // to the reassembler.
                if let frame = self.reassembler.push(data) {
                    self.handleCompletedFrame(frame)
                }
                self.requestKeyframeIfLossDetected()
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
            // canvas_width/height are inside the "layout" sub-object.
            let layout = fields["layout"] as? [String: Any]
            let cw = (layout?["canvas_width"]  as? CGFloat) ?? (fields["canvas_width"]  as? CGFloat) ?? 0
            let ch = (layout?["canvas_height"] as? CGFloat) ?? (fields["canvas_height"] as? CGFloat) ?? 0
            Task { @MainActor [weak self] in
                if cw > 0 && ch > 0 {
                    self?.canvasSize = CGSize(width: cw, height: ch)
                }
                if let displaysRaw = fields["available_displays"] as? [[String: Any]] {
                    self?.availableDisplays = displaysRaw.compactMap { d in
                        guard let id = d["id"] as? UInt32,
                              let w  = d["width"]  as? Int,
                              let h  = d["height"] as? Int else { return nil }
                        let name = d["name"] as? String ?? ""
                        return DisplayInfo(id: id, name: name, width: w, height: h)
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

        case "FrameTiming":
            // Host timing breakdown (only when FLUX_FRAME_TIMING is set
            // on the host). Stash keyed by capture_us; correlated when
            // the matching frame is displayed in handleCompletedFrame.
            // Runs on the receive queue, same as handleCompletedFrame —
            // no locking needed.
            guard let fields = value as? [String: Any],
                  let captureUs    = fields["capture_us"]     as? UInt64,
                  let encodeDoneUs = fields["encode_done_us"] as? UInt64,
                  let sentUs       = fields["sent_us"]        as? UInt64 else { return }
            storeFrameTiming(captureUs: captureUs,
                             encodeDoneUs: encodeDoneUs, sentUs: sentUs)

        case "DisplayThumbnailChunk":
            guard let fields = value as? [String: Any],
                  let displayId  = fields["display_id"] as? UInt32,
                  let generation = fields["generation"] as? UInt32,
                  let seq        = fields["seq"] as? Int,
                  let total      = fields["total"] as? Int,
                  let dataB64    = fields["data_b64"] as? String,
                  total > 0, seq >= 0, seq < total else { return }
            handleThumbnailChunk(
                displayId: displayId, generation: generation,
                seq: seq, total: total, dataB64: dataB64
            )

        default:
            print("[StreamSession] handleIncomingControl: unhandled message type '\(key)'")
        }
    }

    /// Reassemble one display-thumbnail chunk; when all chunks of a
    /// generation have arrived, decode the JPEG and publish it.
    /// Datagrams are lossy — an incomplete generation just sits until
    /// the next sweep supersedes it. Runs on the receive queue.
    private func handleThumbnailChunk(
        displayId: UInt32, generation: UInt32, seq: Int, total: Int, dataB64: String
    ) {
        var entry = thumbnailChunks[displayId]
            ?? (generation: generation, total: total, parts: [:])
        if entry.generation != generation || entry.total != total {
            // Stale chunk from an older sweep, or a fresh sweep
            // superseding a partial one — keep only the newest.
            if generation < entry.generation { return }
            entry = (generation: generation, total: total, parts: [:])
        }
        entry.parts[seq] = dataB64
        if entry.parts.count < total {
            thumbnailChunks[displayId] = entry
            return
        }
        thumbnailChunks[displayId] = nil

        let joined = (0..<total).compactMap { entry.parts[$0] }.joined()
        guard let jpeg = Data(base64Encoded: joined),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            print("[StreamSession] thumbnail decode failed for display \(displayId)")
            return
        }
        Task { @MainActor [weak self] in
            self?.displayThumbnails[displayId] = image
        }
    }

#if canImport(UIKit)
    // MARK: - Thumbnail generation

    private static func thumbnailFromPixelBuffer(_ pb: CVPixelBuffer) -> UIImage? {
        // Cached CIContext (creating one per call sets up a Metal
        // pipeline each time) and render at minimap scale instead of
        // full stream resolution (a 4K BGRA render is ~33 MB a tick).
        var ciImage = CIImage(cvPixelBuffer: pb)
        let targetWidth: CGFloat = 320
        let scale = targetWidth / max(ciImage.extent.width, 1)
        if scale < 1 {
            ciImage = ciImage.transformed(by: .init(scaleX: scale, y: scale))
        }
        guard let cgImage = thumbnailCIContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
#endif

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
    public let name: String
    public let width: Int
    public let height: Int

    public init(id: UInt32, name: String = "", width: Int, height: Int) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
    }
}
