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

/// Placeholder for the actual video stream view.
/// Will contain MetalRenderer + input handling.
struct StreamView: View {
    let host: FluxHost

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text("Connected to \(host.name)")
                .foregroundStyle(.white)
        }
    }
}
