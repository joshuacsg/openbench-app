// ContentView.swift — Main viewer UI (SwiftUI, cross-platform).

import SwiftUI
#if canImport(UIKit)
import UniformTypeIdentifiers
#endif

struct ContentView: View {
    @StateObject private var browser = ServiceBrowser()
    @State private var selectedHost: FluxHost?
    @State private var isConnected = false

    var body: some View {
        Group {
            if let host = selectedHost, isConnected {
                StreamView(host: host, onDisconnect: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isConnected = false
                        selectedHost = nil
                    }
                })
                    .transition(.opacity)
            } else {
                HostPickerView(
                    browser: browser,
                    onSelect: { host in
                        selectedHost = host
                        withAnimation(.easeInOut(duration: 0.25)) {
                            isConnected = true
                        }
                    }
                )
                .transition(.opacity)
            }
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }
}

struct HostPickerView: View {
    @ObservedObject var browser: ServiceBrowser
    @ObservedObject var saved = SavedHostsStore.shared
    var onSelect: (FluxHost) -> Void

    @State private var showManualConnect = false
    @State private var manualHost = ""
    @State private var manualPixelPort = "9000"
    @State private var manualPenPort = "9001"

    var body: some View {
        NavigationStack {
            List {
                // Saved hosts (reachable from anywhere — incl. Tailscale,
                // where Bonjour can't browse). Health-checked via the
                // host's unicast discovery responder.
                if !saved.hosts.isEmpty {
                    Section("Saved") {
                        ForEach(saved.hosts) { host in
                            Button {
                                onSelect(FluxHost(
                                    id: host.id,
                                    name: host.name.isEmpty ? host.host : host.name,
                                    pixelPort: host.pixelPort,
                                    penPort: host.penPort,
                                    version: "saved",
                                    certSHA256: "",
                                    endpoint: .hostPort(
                                        host: .init(host.host),
                                        port: .init(integerLiteral: host.pixelPort)
                                    )
                                ))
                            } label: {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(saved.online[host.id] == true
                                              ? Color.green
                                              : (saved.online[host.id] == false ? .red : .gray))
                                        .frame(width: 9, height: 9)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(host.name.isEmpty ? host.host : host.name)
                                            .font(.headline)
                                        Text("\(host.host)  ·  pixel:\(host.pixelPort) pen:\(host.penPort)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    saved.remove(host)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                // Discovered hosts via Bonjour
                if !browser.hosts.isEmpty {
                    Section("Discovered") {
                        ForEach(browser.hosts) { host in
                            Button {
                                onSelect(host)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(host.name)
                                        .font(.headline)
                                    Text("pixel:\(host.pixelPort) pen:\(host.penPort) v\(host.version)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }

                // Manual connect section
                Section("Connect by IP") {
                    TextField("Host (IP or hostname)", text: $manualHost)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        #endif
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        TextField("Pixel port", text: $manualPixelPort)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .textFieldStyle(.roundedBorder)
                        TextField("Pen port", text: $manualPenPort)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .textFieldStyle(.roundedBorder)
                    }
                    Button("Connect") {
                        guard !manualHost.isEmpty,
                              let pp = UInt16(manualPixelPort),
                              let penP = UInt16(manualPenPort) else { return }
                        let host = FluxHost(
                            id: manualHost,
                            name: manualHost,
                            pixelPort: pp,
                            penPort: penP,
                            version: "manual",
                            certSHA256: "",
                            endpoint: .hostPort(host: .init(manualHost), port: .init(integerLiteral: pp))
                        )
                        onSelect(host)
                    }
                    .disabled(manualHost.isEmpty)
                }
            }
            .navigationTitle("FastPort")
            .onAppear { saved.refresh() }
            .refreshable { saved.refresh() }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        browser.stop()
                        browser.start()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh host list")
                }
            }
            .overlay {
                if browser.hosts.isEmpty {
                    // Only show the empty state if the manual section
                    // is scrolled out of view (i.e. the list is truly
                    // empty). Since we always have the manual section,
                    // don't show the overlay.
                }
            }
        }
    }
}

// MARK: - Glass button style

/// Button style matching the web viewer's liquid glass design.
/// Scales down on press with a spring animation.
struct GlassButtonStyle: ButtonStyle {
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isActive
                    ? AnyShapeStyle(Color.accentColor.opacity(0.85))
                    : AnyShapeStyle(.ultraThinMaterial)
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(.white.opacity(isActive ? 0.3 : 0.12), lineWidth: 0.5)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Video stream view — connects to the host, decodes HEVC, renders
/// decoded frames via Metal, and captures input.
struct StreamView: View {
    let host: FluxHost
    var onDisconnect: (() -> Void)?
    @StateObject private var session = StreamSession()
    @StateObject private var inputManager = InputManager()
    @StateObject private var clipboardManager = ClipboardManager()

    /// Currently selected display ID (nil = Unified / host decides).
    @State private var selectedDisplayID: UInt32? = nil
    /// One-shot per connection: pick the first display instead of the
    /// unified all-displays composite once the host reports its list.
    @State private var didAutoSelectDisplay = false

    /// Local cursor position in view coordinates (for software cursor overlay).
    @State private var cursorPosition: CGPoint? = nil

    /// Soft keyboard visibility toggle (iOS only).
    @State private var showKeyboard = false

    /// Input mode: false = touchscreen (finger is the cursor),
    /// true = trackpad (relative cursor, tap-to-click). Persisted.
    @AppStorage("input.trackpadMode") private var trackpadMode = false

    /// Paste modal visibility.
    @State private var showPasteModal = false

    /// Media-paste (image/file) staging tray + flow state.
#if canImport(UIKit)
    @State private var pendingPasteItems: [PastePreviewItem] = []
#endif
    @State private var showPasteTooLarge = false
    @State private var showPasteCellularConfirm = false

    /// Viewport zoom/pan state.
    @State private var viewportScale: CGFloat = 1.0
    @State private var viewportOffset: CGPoint = .zero

    /// Minimap visibility.
    @State private var showMinimap = false

    /// Display sidebar visibility.
    @State private var showDisplaySidebar = false

    /// Refresh sidebar thumbnails every 3 s while it's open (the host
    /// rate-limits sweeps to one per 2 s).
    private let thumbnailRefreshTimer =
        Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()

            // Video + input capture share the same padded frame so
            // coordinate mapping is accurate.
            ZStack {
                MetalVideoView(session: session)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 4)
                    .scaleEffect(viewportScale)
                    .offset(x: viewportOffset.x, y: viewportOffset.y)

#if canImport(UIKit)
                InputCaptureViewRepresentable(
                    inputManager: inputManager,
                    canvasSize: session.canvasSize,
                    showKeyboard: showKeyboard,
                    trackpadMode: trackpadMode,
                    viewportScale: viewportScale,
                    viewportOffset: viewportOffset,
                    onPointerMoved: { pt in cursorPosition = pt },
                    onViewportChanged: { scale, offset in
                        viewportScale = scale
                        viewportOffset = offset
                    }
                )
#elseif canImport(AppKit)
                MacInputCaptureViewRepresentable(
                    inputManager: inputManager,
                    canvasSize: session.canvasSize
                )
#endif
#if canImport(UIKit)
                // Software cursor for trackpad/mouse
                if let pos = cursorPosition {
                    CursorCrosshair()
                        .frame(width: 20, height: 20)
                        .position(x: pos.x, y: pos.y)
                        .allowsHitTesting(false)
                }
#endif
            }
            .padding(.horizontal, 8)
            .padding(.top, 52)
            .padding(.bottom, 8)
        }
        // Status bar + minimap as an overlay ON TOP of the ZStack,
        // so they receive touches above the UIView input capture.
        .overlay(alignment: .top) {
            HStack(spacing: 8) {
                if !session.availableDisplays.isEmpty {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            showDisplaySidebar.toggle()
                        }
                        if showDisplaySidebar {
                            session.sendControl(.requestDisplayThumbnails)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sidebar.leading")
                                .font(.caption)
                            Text("Displays")
                                .font(.caption)
                        }
                        .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(GlassButtonStyle(isActive: showDisplaySidebar))
                }

                StreamSettingsView { fps, bitrateKbps, maxDimension in
                    session.sendControl(.setStreamSettings(
                        fps: fps,
                        bitrateKbps: bitrateKbps,
                        maxDimension: maxDimension
                    ))
                }

                statusPill

                Spacer()

#if canImport(UIKit)
                Button {
                    inputManager.tapHostAction("SpaceLeft")
                } label: {
                    Image(systemName: "rectangle.lefthalf.inset.filled.arrow.left")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(GlassButtonStyle())

                Button {
                    inputManager.tapHostAction("SpaceRight")
                } label: {
                    Image(systemName: "rectangle.righthalf.inset.filled.arrow.right")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(GlassButtonStyle())

                Button {
                    inputManager.tapHostAction("MissionControl")
                } label: {
                    Image(systemName: "rectangle.3.group")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(GlassButtonStyle())

                Button {
                    inputManager.tapHostAction("Launchpad")
                } label: {
                    Image(systemName: "square.grid.3x3")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(GlassButtonStyle())

                Button {
                    trackpadMode.toggle()
                } label: {
                    Image(systemName: trackpadMode ? "cursorarrow.motionlines" : "hand.tap")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(GlassButtonStyle(isActive: trackpadMode))

                Button {
                    showKeyboard.toggle()
                } label: {
                    Image(systemName: "keyboard")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(GlassButtonStyle(isActive: showKeyboard))

                Button {
                    handlePasteToHost()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(GlassButtonStyle())

                Button {
                    showMinimap.toggle()
                    session.thumbnailEnabled = showMinimap
                } label: {
                    Image(systemName: "map")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(GlassButtonStyle(isActive: showMinimap))
#endif

                Button {
                    session.disconnect()
                    onDisconnect?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(GlassButtonStyle())
            }
            .padding()
            // No contentShape here: the HStack spans the full width
            // (Spacer), and a Rectangle shape would swallow taps in
            // the empty strip between controls — right where the Mac
            // menu bar renders. Buttons hit-test on their own.
            .onReceive(session.$availableDisplays) { displays in
                // Default to the first display (zero-copy single-display
                // path on the host) instead of the unified composite.
                guard !didAutoSelectDisplay, selectedDisplayID == nil,
                      let first = displays.first else { return }
                didAutoSelectDisplay = true
                selectedDisplayID = first.id
                session.resetDecodePipeline()
                inputManager.setActiveDisplay(first.id)
            }
        }
#if canImport(UIKit)
        .overlay {
            if showMinimap {
                GeometryReader { geo in
                    MinimapView(
                        thumbnail: session.thumbnail,
                        viewportScale: viewportScale,
                        viewportOffset: viewportOffset,
                        viewBounds: geo.size,
                        onPanNormalized: { nx, ny in
                            // Convert normalized center (0-1) back to viewportOffset.
                            let rawX = (0.5 - nx) * geo.size.width * viewportScale
                            let rawY = (0.5 - ny) * geo.size.height * viewportScale
                            // Clamp so the canvas edge can't go past the view edge.
                            let maxX = geo.size.width * (viewportScale - 1) / 2
                            let maxY = geo.size.height * (viewportScale - 1) / 2
                            viewportOffset = CGPoint(
                                x: max(-maxX, min(maxX, rawX)),
                                y: max(-maxY, min(maxY, rawY))
                            )
                        },
                        onZoomChanged: { newScale in
                            viewportScale = newScale
                            if newScale <= 1.05 {
                                viewportOffset = .zero
                            }
                        },
                        isVisible: $showMinimap
                    )
                }
                .allowsHitTesting(true)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showMinimap)
#endif
        .overlay(alignment: .leading) {
            if showDisplaySidebar {
                ZStack(alignment: .leading) {
                    // Scrim: pauses input to the Mac while picking a
                    // display; tap anywhere outside to dismiss.
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { closeDisplaySidebar() }
                        .transition(.opacity)

                    DisplaySidebarView(
                        displays: session.availableDisplays,
                        thumbnails: session.displayThumbnails,
                        selectedDisplayID: selectedDisplayID,
                        onSelect: { displayID in
                            selectedDisplayID = displayID
                            session.resetDecodePipeline()
                            inputManager.setActiveDisplay(displayID)
                            closeDisplaySidebar()
                        },
                        onClose: { closeDisplaySidebar() }
                    )
                    .padding(.leading, 10)
                    .padding(.vertical, 52)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
        }
        .onReceive(thumbnailRefreshTimer) { _ in
            if showDisplaySidebar {
                session.sendControl(.requestDisplayThumbnails)
            }
        }
        .onAppear {
            session.connect(endpoint: host.endpoint, hostName: host.name, penPort: host.penPort)

            // Wire the InputManager's send callback to the session.
            inputManager.sendControl = { [weak session] message in
                session?.sendControl(message)
            }

            // Apple Pencil → dedicated pen flow (pressure + tilt at
            // 240 Hz, isolated from pixel traffic).
            inputManager.sendStylus = { [weak session] sample in
                session?.sendStylusSample(sample)
            }

            // Remember successfully connected hosts (by resolved IP —
            // stable on Tailscale) so they appear in the Saved section
            // with live reachability, where Bonjour can't browse.
            let hostName = host.name
            let penPort = host.penPort
            session.onResolvedEndpoint = { ip, pixelPort in
                SavedHostsStore.shared.add(
                    name: hostName,
                    host: ip,
                    pixelPort: pixelPort,
                    penPort: penPort
                )
            }

            // Local clipboard changes → send to host.
            clipboardManager.onClipboardChanged = { [weak inputManager] text in
                inputManager?.syncClipboard(text)
            }

            // Incoming ClipboardSync from host → write to local clipboard.
            session.onClipboardSync = { [weak clipboardManager] text in
                clipboardManager?.write(text)
            }
        }
        .onDisappear {
            inputManager.sendControl = nil
            inputManager.sendStylus = nil
            session.onResolvedEndpoint = nil
            clipboardManager.onClipboardChanged = nil
            session.onClipboardSync = nil
            session.disconnect()
        }
        // Show TrustPromptView whenever the TLS verify block produces a new
        // or changed certificate that requires user attention.
        .sheet(item: $session.trustPrompt) { prompt in
            TrustPromptView(prompt: prompt)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showPasteModal) {
            pasteModalContent
                .presentationDetents([.medium])
        }
#if canImport(UIKit)
        .alert("Too large to paste", isPresented: $showPasteTooLarge) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This item is over 50 MB, the limit for pasting to the Mac.")
        }
        .confirmationDialog("Send over cellular?", isPresented: $showPasteCellularConfirm, titleVisibility: .visible) {
            Button("Send anyway") { dispatchPendingPasteItems() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You're on a metered connection — this may use significant data.")
        }
        .overlay(alignment: .bottom) {
            if !pendingPasteItems.isEmpty {
                PastePreviewTray(
                    items: $pendingPasteItems,
                    onSend: { sendPendingPasteItems() },
                    onRemove: { item in pendingPasteItems.removeAll { $0.id == item.id } }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: pendingPasteItems.count)
#endif
        // Opt out of SwiftUI keyboard avoidance: the soft keyboard
        // overlays the stream instead of squeezing the video into the
        // space above it.
        .ignoresSafeArea(.keyboard)
    }

#if canImport(UIKit)
    /// Inspect the iPad clipboard and STAGE it in the preview tray:
    /// images and files become removable chips ready to send to the Mac;
    /// plain text falls back to the type/paste modal.
    private func handlePasteToHost() {
        let pb = UIPasteboard.general

        // 1. Image (screenshot, copied photo, image from the web).
        if pb.hasImages, let image = pb.image, let png = image.pngData() {
            stagePaste(
                ClipboardBlobData(kind: .image, uti: "public.png", filename: "", data: png),
                thumbnail: image, name: "Image", badge: "PNG"
            )
            return
        }

        // 2. A file / arbitrary data item (Files app, documents, video).
        if let (data, uti, name) = firstFileItem(pb) {
            let badge = (UTType(uti)?.preferredFilenameExtension ?? "file").uppercased()
            stagePaste(
                ClipboardBlobData(kind: .file, uti: uti, filename: name, data: data),
                thumbnail: UIImage(data: data), name: name, badge: badge
            )
            return
        }

        // 3. Plain text → existing modal.
        showPasteModal = true
    }

    /// Pick the richest non-text data representation off the first
    /// pasteboard item.
    private func firstFileItem(_ pb: UIPasteboard) -> (Data, String, String)? {
        guard let item = pb.items.first else { return nil }
        let textTypes: Set<String> = [
            "public.utf8-plain-text", "public.text", "public.plain-text", "public.url",
        ]
        for (uti, value) in item {
            guard !textTypes.contains(uti), let data = value as? Data, !data.isEmpty else { continue }
            let ext = UTType(uti)?.preferredFilenameExtension ?? "bin"
            return (data, uti, "pasted.\(ext)")
        }
        return nil
    }

    /// Add an item to the staging tray (or reject if over the size cap).
    private func stagePaste(_ blob: ClipboardBlobData, thumbnail: UIImage?, name: String, badge: String) {
        guard blob.data.count <= ClipboardBlobData.maxBytes else {
            showPasteTooLarge = true
            return
        }
        pendingPasteItems.append(PastePreviewItem(
            blob: blob, thumbnail: thumbnail, displayName: name, typeBadge: badge
        ))
    }

    /// Send the whole tray, with a one-time cellular confirmation.
    private func sendPendingPasteItems() {
        guard !pendingPasteItems.isEmpty else { return }
        if session.isExpensivePath {
            showPasteCellularConfirm = true
            return
        }
        dispatchPendingPasteItems()
    }

    private func dispatchPendingPasteItems() {
        for idx in pendingPasteItems.indices { pendingPasteItems[idx].isSending = true }
        for item in pendingPasteItems where item.isSending {
            session.sendClipboardBlob(item.blob) { success in
                if success {
                    pendingPasteItems.removeAll { $0.id == item.id }
                } else if let i = pendingPasteItems.firstIndex(where: { $0.id == item.id }) {
                    pendingPasteItems[i].isSending = false // keep for retry
                }
            }
        }
    }
#endif

    private func closeDisplaySidebar() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            showDisplaySidebar = false
        }
    }

    @ViewBuilder
    private var pasteModalContent: some View {
#if canImport(UIKit)
        PasteModalView { text in
            inputManager.textInput(text)
        }
#else
        EmptyView()
#endif
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            // Animated status dot with glow.
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.6), radius: 4)
            Text(statusText)
                .font(.system(.caption, design: .rounded, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    private var statusColor: Color {
        switch session.state {
        case .connected:
            // Color-code by RTT quality.
            if let rtt = session.rttMs {
                if rtt < 30 { return .green }
                if rtt < 80 { return .yellow }
                return .orange
            }
            return .green
        case .connecting: return .yellow
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch session.state {
        case .connected:
            let fps = Int(session.stats.currentFps)
            let rtt = session.rttMs.map { " · \($0)ms" } ?? ""
            return "\(fps) fps\(rtt)"
        case .connecting: return "Connecting…"
        case .disconnected: return "Disconnected"
        case .failed: return "Reconnecting…"
        }
    }
}

#if canImport(UIKit)
import UIKit

// MARK: - Software cursor shape

/// A crosshair cursor centered on the pointer position.
struct CursorCrosshair: View {
    var body: some View {
        Canvas { ctx, size in
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            let arm: CGFloat = size.width / 2 - 2
            let gap: CGFloat = 1
            var stroke = Path()
            // Top
            stroke.move(to: CGPoint(x: mid.x, y: mid.y - arm))
            stroke.addLine(to: CGPoint(x: mid.x, y: mid.y - gap))
            // Bottom
            stroke.move(to: CGPoint(x: mid.x, y: mid.y + gap))
            stroke.addLine(to: CGPoint(x: mid.x, y: mid.y + arm))
            // Left
            stroke.move(to: CGPoint(x: mid.x - arm, y: mid.y))
            stroke.addLine(to: CGPoint(x: mid.x - gap, y: mid.y))
            // Right
            stroke.move(to: CGPoint(x: mid.x + gap, y: mid.y))
            stroke.addLine(to: CGPoint(x: mid.x + arm, y: mid.y))

            // Black outline for contrast on any background.
            ctx.stroke(stroke, with: .color(.black), lineWidth: 2.5)
            // White inner line.
            ctx.stroke(stroke, with: .color(.white), lineWidth: 1)
        }
    }
}

// MARK: - iOS input capture representable

/// UIViewRepresentable that wraps InputCaptureView and connects it to
/// the shared InputManager. Lays transparently on top of MetalVideoView.
struct InputCaptureViewRepresentable: UIViewRepresentable {
    let inputManager: InputManager
    let canvasSize: CGSize
    var showKeyboard: Bool = false
    var trackpadMode: Bool = false
    var viewportScale: CGFloat = 1.0
    var viewportOffset: CGPoint = .zero
    var onPointerMoved: ((CGPoint?) -> Void)?
    var onViewportChanged: ((CGFloat, CGPoint) -> Void)?

    func makeUIView(context: Context) -> InputCaptureView {
        let view = InputCaptureView()
        view.inputManager = inputManager
        view.canvasSize = canvasSize
        view.showKeyboard = showKeyboard
        view.trackpadMode = trackpadMode
        view.onPointerMoved = onPointerMoved
        view.onViewportChanged = onViewportChanged
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: InputCaptureView, context: Context) {
        view.inputManager = inputManager
        view.canvasSize = canvasSize
        view.showKeyboard = showKeyboard
        view.trackpadMode = trackpadMode
        view.onPointerMoved = onPointerMoved
        view.onViewportChanged = onViewportChanged
        // Sync viewport from minimap slider → InputCaptureView.
        if abs(view.viewportScale - viewportScale) > 0.01
            || abs(view.viewportOffset.x - viewportOffset.x) > 1
            || abs(view.viewportOffset.y - viewportOffset.y) > 1 {
            view.setViewport(scale: viewportScale, offset: viewportOffset)
        }
    }
}

/// UIViewRepresentable that hosts the MetalRenderer's CAMetalLayer.
struct MetalVideoView: UIViewRepresentable {
    @ObservedObject var session: StreamSession

    func makeUIView(context: Context) -> MetalHostView {
        let view = MetalHostView()
        session.onDecodedFrame = { [weak view] pb, _ in
            view?.renderer?.enqueue(pb)
        }
        return view
    }

    func updateUIView(_ view: MetalHostView, context: Context) {}

    class MetalHostView: UIView {
        var renderer: MetalRenderer?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            guard let r = MetalRenderer() else { return }
            renderer = r
            r.metalLayer.frame = bounds
            layer.addSublayer(r.metalLayer)
            r.startDisplayLink()
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            renderer?.metalLayer.frame = bounds
        }

        deinit {
            renderer?.stopDisplayLink()
        }
    }
}
#elseif canImport(AppKit)
import AppKit

// MARK: - macOS input capture representable

/// NSViewRepresentable that wraps MacInputCaptureView and connects it to
/// the shared InputManager. Lays transparently on top of MetalVideoView.
struct MacInputCaptureViewRepresentable: NSViewRepresentable {
    let inputManager: InputManager
    let canvasSize: CGSize

    func makeNSView(context: Context) -> MacInputCaptureView {
        let view = MacInputCaptureView()
        view.inputManager = inputManager
        view.canvasSize = canvasSize
        // Become first responder so keyboard events are routed here.
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: MacInputCaptureView, context: Context) {
        view.inputManager = inputManager
        view.canvasSize = canvasSize
    }
}

/// NSViewRepresentable that hosts the MetalRenderer's CAMetalLayer.
struct MetalVideoView: NSViewRepresentable {
    @ObservedObject var session: StreamSession

    func makeNSView(context: Context) -> MetalHostView {
        let view = MetalHostView()
        session.onDecodedFrame = { [weak view] pb, _ in
            view?.renderer?.enqueue(pb)
            DispatchQueue.main.async {
                view?.renderer?.presentIfNeeded()
            }
        }
        return view
    }

    func updateNSView(_ view: MetalHostView, context: Context) {}

    class MetalHostView: NSView {
        var renderer: MetalRenderer?

        override init(frame: CGRect) {
            super.init(frame: frame)
            wantsLayer = true
            guard let r = MetalRenderer() else { return }
            renderer = r
            r.metalLayer.frame = bounds
            layer?.addSublayer(r.metalLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            renderer?.metalLayer.frame = bounds
        }
    }
}
#endif
