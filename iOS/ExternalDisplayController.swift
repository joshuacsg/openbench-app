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

    /// Clockwise rotation applied to the monitor's picture, for a monitor
    /// mounted on its side or upside down (iPadOS can't rotate an
    /// external display itself).
    enum MonitorRotation: Int, CaseIterable, Identifiable {
        case none = 0
        case clockwise90 = 90
        case upsideDown = 180
        case clockwise270 = 270

        var id: Int { rawValue }
        var degrees: Double { Double(rawValue) }
        /// Width and height swap on screen.
        var isQuarterTurn: Bool { self == .clockwise90 || self == .clockwise270 }
        var label: String {
            switch self {
            case .none: return "Standard"
            case .clockwise90: return "90°"
            case .upsideDown: return "180°"
            case .clockwise270: return "270°"
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
    /// Host display the monitor shows (nil until the first Welcome, or
    /// while it shows all displays).
    @Published private(set) var monitorDisplayID: UInt32?
    /// The monitor shows the host's composite of every display side by
    /// side; the trackpad cursor crosses between them.
    @Published private(set) var monitorShowsAllDisplays = false
    /// Trackpad cursor in the monitor session's canvas pixels.
    @Published var monitorCursor: CGPoint?

    /// Persisted like @AppStorage (same UserDefaults key); a plain
    /// @Published so views observing the controller re-render on change.
    @Published var iPadMode: IPadMode {
        didSet { UserDefaults.standard.set(iPadMode.rawValue, forKey: Self.modeKey) }
    }
    private static let modeKey = "externalDisplay.iPadMode"

    /// Persisted the same way as iPadMode.
    @Published var monitorRotation: MonitorRotation {
        didSet { UserDefaults.standard.set(monitorRotation.rawValue, forKey: Self.rotationKey) }
    }
    private static let rotationKey = "externalDisplay.rotation"

    /// Where the monitor sits relative to the iPad, for the trackpad
    /// cursor to cross between them in Second screen mode. Persisted.
    @Published var arrangement: DisplayArrangement {
        didSet {
            if let data = try? JSONEncoder().encode(arrangement) {
                UserDefaults.standard.set(data, forKey: Self.arrangementKey)
            }
        }
    }
    private static let arrangementKey = "externalDisplay.arrangement"

    /// Second screen mode: the iPad's trackpad cursor has crossed onto
    /// the monitor, so input goes to the monitor session.
    @Published private(set) var cursorOnMonitor = false

    /// The monitor's own connection to the host. Long-lived; connected
    /// and disconnected as the monitor / iPad session come and go.
    let monitorSession = StreamSession()
    private let controlRepeater = ControlMessageRepeater()

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
        monitorRotation = MonitorRotation(rawValue: UserDefaults.standard.integer(forKey: Self.rotationKey))
            ?? .none
        arrangement = UserDefaults.standard.data(forKey: Self.arrangementKey)
            .flatMap { try? JSONDecoder().decode(DisplayArrangement.self, from: $0) }
            ?? DisplayArrangement()
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
        inputTargetsMonitor || cursorOnMonitor ? monitorSession : primary
    }

    /// The monitor shows a trackpad cursor (Trackpad mode, or the iPad's
    /// cursor crossed over in Second screen mode).
    var monitorShowsCursor: Bool { inputTargetsMonitor || cursorOnMonitor }

    /// Called by the iPad's input view as its cursor crosses over.
    func setCursorOnMonitor(_ onMonitor: Bool) {
        guard onMonitor != cursorOnMonitor else { return }
        cursorOnMonitor = onMonitor
        if !onMonitor { monitorCursor = nil }
    }

    /// Native size of the picture showing `displayID` (nil = all
    /// displays side by side), shaped to that stream's canvas aspect.
    private func pictureSize(_ displayID: UInt32?, canvas: CGSize) -> CGSize? {
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let displays = pickerDisplays
        let width: CGFloat
        if let displayID {
            guard let display = displays.first(where: { $0.id == displayID }) else { return canvas }
            width = CGFloat(display.width)
        } else {
            width = CGFloat(displays.reduce(0) { $0 + $1.width })
        }
        guard width > 0 else { return canvas }
        return CGSize(width: width, height: width * canvas.height / canvas.width)
    }

    /// The iPad's picture and the monitor's, as arranged (iPad first).
    /// Nil unless both are streaming different displays.
    var arrangedSizes: (iPad: CGSize, monitor: CGSize)? {
        guard isActive, iPadMode == .secondScreen,
              let primary, primary.state == .connected,
              monitorSession.state == .connected,
              !(monitorShowsAllDisplays && iPadDisplayID == nil),
              monitorShowsAllDisplays || monitorDisplayID != iPadDisplayID,
              let iPad = pictureSize(iPadDisplayID, canvas: primary.canvasSize),
              let monitor = pictureSize(monitorShowsAllDisplays ? nil : monitorDisplayID,
                                        canvas: monitorSession.canvasSize) else { return nil }
        return (iPad, monitor)
    }

    /// Sizes for the arrangement editor: the live pictures when both
    /// stream, else typical shapes so it can be set up ahead of time.
    var arrangementPreviewSizes: (iPad: CGSize, monitor: CGSize) {
        if let sizes = arrangedSizes { return sizes }
        let iPad = primary.flatMap { pictureSize(iPadDisplayID, canvas: $0.canvasSize) }
        let monitor = pictureSize(monitorShowsAllDisplays ? nil : monitorDisplayID,
                                  canvas: monitorSession.canvasSize)
        return (iPad ?? CGSize(width: 1512, height: 982), monitor ?? CGSize(width: 1920, height: 1080))
    }

    /// Name of a host display for labels (nil = all displays).
    func displayName(_ id: UInt32?) -> String {
        guard let id else { return "All displays" }
        guard let display = pickerDisplays.first(where: { $0.id == id }) else { return "Display" }
        return display.name.isEmpty ? "\(display.width)×\(display.height)" : display.name
    }

    /// Link handed to the iPad's input view so its trackpad cursor can
    /// cross onto the monitor (Second screen mode only).
    var secondScreenLink: InputCaptureView.TrackpadLink? {
        guard let sizes = arrangedSizes else { return nil }
        let rects = arrangement.rects(iPad: sizes.iPad, monitor: sizes.monitor)
        return .init(localRect: rects.iPad, remoteRect: rects.monitor,
                     remoteCanvasSize: monitorSession.canvasSize)
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
        monitorShowsAllDisplays = false
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
        if !connected {
            monitorCursor = nil
            cursorOnMonitor = false
        }
        reconcile()
    }

    // MARK: - User actions

    /// Point the monitor at a host display, or at all of them (nil).
    func selectMonitorDisplay(_ id: UInt32?) {
        monitorDisplayID = id
        monitorShowsAllDisplays = id == nil
        guard monitorSession.state == .connected else { return }
        monitorSession.resetDecodePipeline()
        controlRepeater.send(.setActiveDisplay(displayId: id)) { [weak monitorSession] in
            monitorSession?.sendControl($0)
        }
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
            controlRepeater.cancelAll()
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
        if state != .connected { controlRepeater.cancelAll() }
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
        controlRepeater.cancelAll()
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
        let id = monitorShowsAllDisplays ? nil : resolveMonitorDisplay(in: displays)
        monitorDisplayID = id
        monitorSession.resetDecodePipeline()
        controlRepeater.send(.setActiveDisplay(displayId: id)) { [weak monitorSession] in
            monitorSession?.sendControl($0)
        }
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

/// Where the monitor's picture sits relative to the iPad's, like macOS
/// "Arrange Displays": on one edge, slid along it. Geometry lives in a
/// shared space with the iPad's picture at the origin at native size.
struct DisplayArrangement: Codable, Equatable {
    enum Edge: String, Codable { case top, bottom, left, right }

    var edge: Edge = .top
    /// The monitor's center along the shared edge, relative to the
    /// iPad's center, as a fraction of the iPad's length on that axis.
    var offset: CGFloat = 0

    func rects(iPad: CGSize, monitor: CGSize) -> (iPad: CGRect, monitor: CGRect) {
        let ipad = CGRect(origin: .zero, size: iPad)
        let along = Self.clampedOffset(offset, edge: edge, iPad: iPad, monitor: monitor)
        let origin: CGPoint
        switch edge {
        case .top, .bottom:
            let x = iPad.width / 2 + along * iPad.width - monitor.width / 2
            origin = CGPoint(x: x, y: edge == .top ? -monitor.height : iPad.height)
        case .left, .right:
            let y = iPad.height / 2 + along * iPad.height - monitor.height / 2
            origin = CGPoint(x: edge == .left ? -monitor.width : iPad.width, y: y)
        }
        return (ipad, CGRect(origin: origin, size: monitor))
    }

    /// Snap a dragged monitor center (in arrangement space) to the
    /// nearest iPad edge, keeping at least a sliver of shared edge.
    static func snapped(monitorCenter c: CGPoint, iPad: CGSize, monitor: CGSize) -> Self {
        let dx = (c.x - iPad.width / 2) / max((iPad.width + monitor.width) / 2, 1)
        let dy = (c.y - iPad.height / 2) / max((iPad.height + monitor.height) / 2, 1)
        var result = Self()
        if abs(dy) >= abs(dx) {
            result.edge = dy < 0 ? .top : .bottom
            result.offset = (c.x - iPad.width / 2) / max(iPad.width, 1)
        } else {
            result.edge = dx < 0 ? .left : .right
            result.offset = (c.y - iPad.height / 2) / max(iPad.height, 1)
        }
        result.offset = clampedOffset(result.offset, edge: result.edge, iPad: iPad, monitor: monitor)
        return result
    }

    private static func clampedOffset(_ offset: CGFloat, edge: Edge, iPad: CGSize, monitor: CGSize) -> CGFloat {
        let (a, b) = edge == .top || edge == .bottom
            ? (iPad.width, monitor.width) : (iPad.height, monitor.height)
        guard a > 0 else { return 0 }
        // Centers may sit at most this far apart and still share 10% of
        // the shorter edge.
        let limit = max((a + b) / 2 - 0.1 * min(a, b), 0) / a
        return min(max(offset, -limit), limit)
    }
}
