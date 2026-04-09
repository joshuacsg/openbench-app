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
/// decoded frames via Metal.
struct StreamView: View {
    let host: FluxHost
    @StateObject private var session = StreamSession()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MetalVideoView(session: session)
                .ignoresSafeArea()

            // Status overlay
            VStack {
                HStack {
                    statusPill
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
        }
        .onDisappear {
            session.disconnect()
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
