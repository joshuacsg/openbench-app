// HostApp.swift — macOS menu bar host app.
//
// Runs the flux streaming server as a subprocess and exposes its
// status via a SwiftUI MenuBarExtra. macOS 13+ required.

import SwiftUI

@main
struct HostApp: App {
    @StateObject private var daemon = HostDaemon()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 8) {
                if daemon.isRunning {
                    Label("Streaming", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                } else {
                    Label("Stopped", systemImage: "stop.circle")
                        .foregroundStyle(.secondary)
                }

                Divider()

                if daemon.isRunning {
                    Button("Stop Host") { daemon.stop() }
                } else {
                    Button("Start Host") { daemon.start() }
                }

                Divider()

                Button("Quit OpenBench Host") {
                    daemon.stop()
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(8)
        } label: {
            Image(systemName: daemon.isRunning
                ? "rectangle.inset.filled.and.person.filled"
                : "rectangle.dashed.and.person.filled")
        }
        .menuBarExtraStyle(.window)
    }
}
