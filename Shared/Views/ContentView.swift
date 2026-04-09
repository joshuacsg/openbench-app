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

    var body: some View {
        NavigationStack {
            List(browser.hosts) { host in
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
            .navigationTitle("OpenBench")
            .overlay {
                if browser.hosts.isEmpty {
                    ContentUnavailableView(
                        "Looking for hosts…",
                        systemImage: "network",
                        description: Text("Make sure a flux host is running with --advertise on the same network.")
                    )
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
                canvasSize: session.canvasSize
            )
            .ignoresSafeArea()
#elseif canImport(AppKit)
            MacInputCaptureViewRepresentable(
                inputManager: inputManager,
                canvasSize: session.canvasSize
            )
            .ignoresSafeArea()
#endif

            // Status overlay
            VStack {
                HStack {
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
            session.connect(host: host.name, port: host.pixelPort)

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
        case .connected: "Connected · \(Int(session.stats.currentFps)) fps"
        case .connecting: "Connecting…"
        case .disconnected: "Disconnected"
        case .failed(let msg): "Error: \(msg)"
        }
    }
}

#if canImport(UIKit)
import UIKit

// MARK: - iOS input capture representable

/// UIViewRepresentable that wraps InputCaptureView and connects it to
/// the shared InputManager. Lays transparently on top of MetalVideoView.
struct InputCaptureViewRepresentable: UIViewRepresentable {
    let inputManager: InputManager
    let canvasSize: CGSize

    func makeUIView(context: Context) -> InputCaptureView {
        let view = InputCaptureView()
        view.inputManager = inputManager
        view.canvasSize = canvasSize
        view.backgroundColor = .clear
        // Become first responder so hardware keyboard events are received.
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: InputCaptureView, context: Context) {
        view.inputManager = inputManager
        view.canvasSize = canvasSize
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
