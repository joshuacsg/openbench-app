// ContentView.swift — Main viewer UI (SwiftUI, cross-platform).

import SwiftUI

struct ContentView: View {
    @StateObject private var browser = ServiceBrowser()
    @State private var selectedHost: FluxHost?
    @State private var isConnected = false

    var body: some View {
        Group {
            if let host = selectedHost, isConnected {
                StreamView(host: host)
            } else {
                HostPickerView(
                    browser: browser,
                    onSelect: { host in
                        selectedHost = host
                        isConnected = true
                    }
                )
            }
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }
}

struct HostPickerView: View {
    @ObservedObject var browser: ServiceBrowser
    var onSelect: (FluxHost) -> Void

    @State private var showManualConnect = false
    @State private var manualHost = ""
    @State private var manualPixelPort = "9000"
    @State private var manualPenPort = "9001"

    var body: some View {
        NavigationStack {
            List {
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
            .navigationTitle("OpenBench")
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

/// Video stream view — connects to the host, decodes HEVC, renders
/// decoded frames via Metal, and captures input.
struct StreamView: View {
    let host: FluxHost
    @StateObject private var session = StreamSession()
    @StateObject private var inputManager = InputManager()
    @StateObject private var clipboardManager = ClipboardManager()
    @Environment(\.dismiss) private var dismiss

    /// Currently selected display ID (nil = Unified / host decides).
    @State private var selectedDisplayID: UInt32? = nil

    /// Local cursor position in view coordinates (for software cursor overlay).
    @State private var cursorPosition: CGPoint? = nil

    /// Soft keyboard visibility toggle (iOS only).
    @State private var showKeyboard = false

    /// Paste modal visibility.
    @State private var showPasteModal = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MetalVideoView(session: session)
                .ignoresSafeArea()

            // Input capture overlay — transparent, sits above the video
            // layer so it receives all touch / keyboard events.
#if canImport(UIKit)
            InputCaptureViewRepresentable(
                inputManager: inputManager,
                canvasSize: session.canvasSize,
                showKeyboard: showKeyboard,
                onPointerMoved: { pt in cursorPosition = pt }  // nil hides cursor
            )
            .ignoresSafeArea()
#elseif canImport(AppKit)
            MacInputCaptureViewRepresentable(
                inputManager: inputManager,
                canvasSize: session.canvasSize
            )
            .ignoresSafeArea()
#endif

#if canImport(UIKit)
            // Software cursor for trackpad/mouse — rendered locally for
            // zero-latency feedback since macOS hides the cursor from
            // screen capture.
            if let pos = cursorPosition {
                CursorCrosshair()
                    .frame(width: 20, height: 20)
                    .position(x: pos.x, y: pos.y)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }
#endif

            // Status overlay
            VStack {
                HStack(spacing: 8) {
                    statusPill

                    // Display picker — only visible once the host reports displays.
                    if !session.availableDisplays.isEmpty {
                        DisplayPickerView(
                            displays: session.availableDisplays,
                            selectedDisplayID: $selectedDisplayID
                        ) { displayID in
                            inputManager.setActiveDisplay(displayID)
                        }
                    }

                    Spacer()

#if canImport(UIKit)
                    // Keyboard toggle
                    Button {
                        showKeyboard.toggle()
                    } label: {
                        Image(systemName: "keyboard")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(showKeyboard ? .blue : .white.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())

                    // Paste to host
                    Button {
                        showPasteModal = true
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
#endif

                    Button {
                        session.disconnect()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.7))
                }
                .padding()
                Spacer()
            }
        }
        .onAppear {
            session.connect(endpoint: host.endpoint, hostName: host.name)

            // Wire the InputManager's send callback to the session.
            inputManager.sendControl = { [weak session] message in
                session?.sendControl(message)
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
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var statusColor: Color {
        switch session.state {
        case .connected: .green
        case .connecting: .yellow
        case .disconnected: .gray
        case .failed: .red
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
    var onPointerMoved: ((CGPoint?) -> Void)?

    func makeUIView(context: Context) -> InputCaptureView {
        let view = InputCaptureView()
        view.inputManager = inputManager
        view.canvasSize = canvasSize
        view.showKeyboard = showKeyboard
        view.onPointerMoved = onPointerMoved
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: InputCaptureView, context: Context) {
        view.inputManager = inputManager
        view.canvasSize = canvasSize
        view.showKeyboard = showKeyboard
        view.onPointerMoved = onPointerMoved
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
