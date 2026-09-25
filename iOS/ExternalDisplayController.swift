// ExternalDisplayController.swift — drives an external monitor with its
// own stream while the iPad shows a trackpad or a different display.
//
// iPads without system extended-display support (pre-M1) still let an
// app present its own content on a connected monitor through an
// external-display scene session (see ExternalDisplayScene.swift). This
// coordinator owns everything that scene shows:
//
//   * whether a monitor scene is attached and in the foreground,
//   * a SECOND StreamSession to the same host endpoint as the iPad's
//     session (the host serves concurrent viewers on one pixel port;
//     each connection has its own active display),
//   * which host display the monitor shows,
//   * which session receives input (iPad mode: Trackpad → monitor,
//     Second screen → iPad).
//
// The monitor session follows the iPad session: it only runs while the
// iPad session is connected, so on any host the iPad's connection is
// always the first one in. Hosts that predate multi-viewer support
// accept the QUIC handshake and immediately close with "already
// streaming". Network.framework does not reliably surface that close
// (observed: the connection stays `.ready`, silently), so a liveness
// watchdog also counts a connection that receives nothing — no
// datagram, no pong — within a few seconds as a rejection. Either way
// the monitor is parked in `.unsupported` (no reconnect loop) until the
// user retries. A host at
// its viewer cap closes with "viewer limit reached" → `.viewerLimit`,
// parked the same way.

import Foundation
import Combine
import Network
import CoreGraphics

@MainActor
final class ExternalDisplayController: ObservableObject {
    static let shared = ExternalDisplayController()

    /// What the iPad does while a monitor is attached.
    enum IPadMode: String, CaseIterable, Identifiable {
        /// iPad hides its video and becomes a full-screen trackpad for
        /// the monitor's display; input + keyboard go to the monitor.
        case trackpad
        /// iPad keeps streaming its own display; input stays on the iPad.
        case secondScreen

        var id: String { rawValue }
        var label: String {
            switch self {
            case .trackpad: return "Trackpad"
            case .secondScreen: return "Second screen"
            }
        }
    }

    enum MonitorStatus: Equatable {
        /// No monitor, or the iPad isn't streaming.
        case idle
        case connecting
        case streaming
        /// The host rejected a second concurrent viewer (older host).
        case unsupported
        /// The host is at its concurrent-viewer cap (FLUX_MAX_VIEWERS).
        case viewerLimit
        /// Transient failure — the session's own backoff is retrying.
        case failed(String)
    }

    /// A monitor scene is attached and foregrounded.
    @Published private(set) var isMonitorConnected = false
    @Published private(set) var status: MonitorStatus = .idle
    /// Host display the monitor shows (nil until the first Welcome).
    @Published private(set) var monitorDisplayID: UInt32?
    /// Trackpad cursor in the monitor session's canvas pixels.
    @Published var monitorCursor: CGPoint?

    /// Persisted like @AppStorage (same UserDefaults key); a plain
    /// @Published so views observing the controller re-render on change.
    @Published var iPadMode: IPadMode {
        didSet { UserDefaults.standard.set(iPadMode.rawValue, forKey: Self.modeKey) }
    }
    private static let modeKey = "externalDisplay.iPadMode"

    /// The monitor's own connection to the host. Long-lived; connected
    /// and disconnected as the monitor / iPad session come and go.
    let monitorSession = StreamSession()

    /// The display the iPad session is showing — the monitor defaults
    /// to a different one.
    var iPadDisplayID: UInt32?

    // iPad (primary) session the monitor session piggybacks on.
    private weak var primary: StreamSession?
    private var primaryEndpoint: NWEndpoint?
    private var primaryHostName = ""
    private var primaryPenPort: UInt16 = 9001
    private var primaryCancellables = Set<AnyCancellable>()
    private var cancellables = Set<AnyCancellable>()

    // Monitor scene state.
    private var sceneAttached = false
    private var sceneForeground = false

    // Per-connection bookkeeping for the monitor session.
    private var needsDisplayApply = false
    private var readyAt: CFAbsoluteTime?
    private var sawWelcome = false
    private var quickRejects = 0
    /// A connection that closes this soon after the handshake without a
    /// Welcome is treated as a host-side rejection.
    private static let rejectWindow: CFAbsoluteTime = 3
    /// A connected monitor session that has received no traffic by this
    /// point was silently closed by the host.
    private static let livenessTimeout: UInt64 = 5_000_000_000
    private var livenessTask: Task<Void, Never>?
    /// Monitor stream proved live (traffic arrived) since the last
    /// attach / retry. Until then the iPad keeps showing its own video:
    /// flipping it to a trackpad (and pausing its decode) for a stream
    /// the host may silently refuse would drop the iPad's first keyframe
    /// and leave its video black until the next one.
    @Published private(set) var hasBeenLive = false
    private var bytesAtConnect: UInt64 = 0

    private init() {
        iPadMode = IPadMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "")
            ?? .trackpad
        // Without a distinct SNI, Network.framework would fold this
        // session into the iPad session's QUIC connection (same process,
        // endpoint and parameters) instead of opening a second viewer.
        monitorSession.tlsServerName = "fastport-monitor"

        // Views observe only the controller; surface the monitor
        // session's stats/state changes through it.
        monitorSession.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Liveness: the first inbound traffic (datagrams or a pong) on a
        // monitor connection. Stats flush at ~2 Hz, pongs every 2 s.
        monitorSession.$stats
            .combineLatest(monitorSession.$rttMs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stats, rtt in
                guard let self, !self.hasBeenLive,
                      self.status == .streaming,
                      stats.bytesReceived > self.bytesAtConnect || rtt != nil else { return }
                self.hasBeenLive = true
            }
            .store(in: &cancellables)

        // receive(on:) delivers after the session's own state-change
        // handler returns (it schedules its reconnect right after
        // publishing .failed) — so a disconnect() from here reliably
        // cancels that reconnect.
        monitorSession.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.monitorStateChanged(state) }
            .store(in: &cancellables)

        monitorSession.$availableDisplays
            .receive(on: DispatchQueue.main)
            .sink { [weak self] displays in self?.monitorDisplaysChanged(displays) }
            .store(in: &cancellables)
    }

    // MARK: - Derived state

    /// A monitor is attached and the iPad is in a streaming session.
    var isActive: Bool { isMonitorConnected && primary != nil }

    /// True when input (touch, keyboard, pencil, host actions) should go
    /// to the monitor session and the iPad shows a trackpad surface.
    /// Falls back to the iPad session when the host can't serve a
    /// second stream.
    var inputTargetsMonitor: Bool {
        guard isActive, iPadMode == .trackpad, hasBeenLive else { return false }
        switch status {
        case .connecting, .streaming, .failed: return true
        case .idle, .unsupported, .viewerLimit: return false
        }
    }

    /// The session that should receive input right now.
    func inputSession(primary: StreamSession) -> StreamSession {
        inputTargetsMonitor ? monitorSession : primary
    }

    /// Displays offered in the monitor picker: the monitor session's own
    /// Welcome list (fresh per connection), else the iPad's.
    var pickerDisplays: [DisplayInfo] {
        monitorSession.availableDisplays.isEmpty
            ? (primary?.availableDisplays ?? [])
            : monitorSession.availableDisplays
    }

    // MARK: - iPad session lifecycle (called by StreamView)

    func attachPrimary(_ session: StreamSession, hostName: String, endpoint: NWEndpoint, penPort: UInt16) {
        primary = session
        primaryHostName = hostName
        primaryEndpoint = endpoint
        primaryPenPort = penPort
        // New host connection: forget the last host's verdict/display.
        quickRejects = 0
        hasBeenLive = false
        monitorDisplayID = nil
        if isParked { status = .idle }

        primaryCancellables.removeAll()
        session.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &primaryCancellables)
        reconcile()
    }

    func detachPrimary(_ session: StreamSession) {
        guard primary === session else { return }
        primaryCancellables.removeAll()
        primary = nil
        reconcile()
    }

    // MARK: - Monitor scene lifecycle (called by ExternalDisplaySceneDelegate)

    func monitorSceneDidConnect(foreground: Bool) {
        sceneAttached = true
        sceneForeground = foreground
        updateMonitorConnected()
    }

    func monitorSceneForegroundChanged(_ foreground: Bool) {
        sceneForeground = foreground
        updateMonitorConnected()
    }

    func monitorSceneDidDisconnect() {
        sceneAttached = false
        sceneForeground = false
        updateMonitorConnected()
    }

    private func updateMonitorConnected() {
        let connected = sceneAttached && sceneForeground
        guard connected != isMonitorConnected else { return }
        isMonitorConnected = connected
        if !connected { monitorCursor = nil }
        reconcile()
    }

    // MARK: - User actions

    /// Point the monitor at a host display.
    func selectMonitorDisplay(_ id: UInt32) {
        monitorDisplayID = id
        guard monitorSession.state == .connected else { return }
        monitorSession.resetDecodePipeline()
        monitorSession.sendControl(.setActiveDisplay(displayId: id))
    }

    /// The host turned the monitor stream away; stay down until retry.
    var isParked: Bool { status == .unsupported || status == .viewerLimit }

    /// Clear an `.unsupported` / failed verdict and try again.
    func retry() {
        quickRejects = 0
        hasBeenLive = false
        status = .idle
        monitorSession.disconnect()
        reconcile()
    }

    // MARK: - Session management

    /// Run the monitor session iff a monitor is attached, the iPad
    /// session is connected, and the host hasn't rejected us.
    private func reconcile() {
        guard isMonitorConnected,
              let primary, primary.state == .connected,
              !isParked else {
            livenessTask?.cancel()
            hasBeenLive = false
            if monitorSession.state != .disconnected { monitorSession.disconnect() }
            if !isParked { status = .idle }
            readyAt = nil
            return
        }
        guard monitorSession.state == .disconnected else { return }
        guard let endpoint = primary.resolvedEndpoint ?? primaryEndpoint else { return }
        status = .connecting
        readyAt = nil
        sawWelcome = false
        monitorSession.connect(endpoint: endpoint, hostName: primaryHostName, penPort: primaryPenPort)
    }

    private func monitorStateChanged(_ state: StreamSession.ConnectionState) {
        // Ignore stale deliveries after we've already stood down.
        guard !isParked, isActive,
              monitorSession.state != .disconnected else { return }
        switch state {
        case .connecting:
            status = .connecting
        case .connected:
            readyAt = CFAbsoluteTimeGetCurrent()
            sawWelcome = false
            bytesAtConnect = monitorSession.stats.bytesReceived
            // Each connection starts on the host's default display —
            // re-apply our choice once this connection's Welcome lands.
            needsDisplayApply = true
            applyStreamSettings()
            status = .streaming
            startLivenessWatchdog()
        case .failed(let message):
            handleMonitorFailure(message)
        case .disconnected:
            break
        }
    }

    /// Pings go out every 2 s and hosts send Welcome + frames right
    /// away, so a live connection always has inbound traffic by now.
    private func startLivenessWatchdog() {
        livenessTask?.cancel()
        let bytesAtStart = monitorSession.stats.bytesReceived
        livenessTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.livenessTimeout)
            guard let self, !Task.isCancelled,
                  self.status == .streaming,
                  self.monitorSession.state == .connected,
                  self.monitorSession.stats.bytesReceived == bytesAtStart,
                  self.monitorSession.rttMs == nil,
                  !self.sawWelcome, !self.hasBeenLive else { return }
            print("[ExternalDisplay] monitor connection silent for 5 s — host closed it (single-viewer host?)")
            self.park(.unsupported)
        }
    }

    /// Stand the monitor down after a host rejection. The session's own
    /// backoff loop is stopped; the iPad session is a separate
    /// connection and is untouched.
    private func park(_ verdict: MonitorStatus) {
        livenessTask?.cancel()
        hasBeenLive = false
        status = verdict
        monitorCursor = nil
        readyAt = nil
        monitorSession.disconnect()
    }

    private func handleMonitorFailure(_ message: String) {
        let alreadyStreaming = message.localizedCaseInsensitiveContains("already streaming")
        let atViewerLimit = message.localizedCaseInsensitiveContains("viewer limit")
        // Only judge connections that actually completed the handshake;
        // a duplicate .failed for the same connection (receive error +
        // state handler) arrives with readyAt already cleared.
        if let readyAt {
            let quick = !sawWelcome && CFAbsoluteTimeGetCurrent() - readyAt < Self.rejectWindow
            quickRejects = quick ? quickRejects + 1 : 0
        }
        readyAt = nil

        if atViewerLimit || alreadyStreaming || quickRejects >= 2 {
            print("[ExternalDisplay] host rejected the monitor stream (\(message)) — parked")
            park(atViewerLimit ? .viewerLimit : .unsupported)
        } else {
            status = .failed(message)
        }
    }

    private func monitorDisplaysChanged(_ displays: [DisplayInfo]) {
        guard !displays.isEmpty else { return }
        sawWelcome = true
        guard needsDisplayApply, monitorSession.state == .connected else { return }
        needsDisplayApply = false
        let id = resolveMonitorDisplay(in: displays)
        monitorDisplayID = id
        monitorSession.resetDecodePipeline()
        monitorSession.sendControl(.setActiveDisplay(displayId: id))
    }

    /// Keep the current choice if the host still has it; otherwise
    /// default to a display the iPad isn't showing, preferring one that
    /// isn't the host's first (main) display — e.g. a virtual display.
    private func resolveMonitorDisplay(in displays: [DisplayInfo]) -> UInt32? {
        if let current = monitorDisplayID, displays.contains(where: { $0.id == current }) {
            return current
        }
        return (displays.dropFirst().first { $0.id != iPadDisplayID }
            ?? displays.first { $0.id != iPadDisplayID }
            ?? displays.first)?.id
    }

    /// Mirror the viewer's persisted stream settings (StreamSettingsView
    /// keys and defaults) onto the monitor connection, as the iPad
    /// session does on connect.
    private func applyStreamSettings() {
        let defaults = UserDefaults.standard
        let fps = defaults.object(forKey: "stream.fps") as? Int ?? 30
        let bitrate = defaults.object(forKey: "stream.bitrateKbps") as? Int ?? 5_000
        let maxDimension = defaults.object(forKey: "stream.maxDimension") as? Int ?? 1920
        monitorSession.sendControl(.setStreamSettings(
            fps: UInt32(fps),
            bitrateKbps: UInt32(bitrate),
            maxDimension: UInt32(maxDimension)
        ))
    }
}
