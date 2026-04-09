// HostApp.swift — macOS menu bar host app.
//
// Runs the flux-host CLI as a subprocess and exposes status via a
// SwiftUI MenuBarExtra. macOS 14+ required.

import SwiftUI

@main
struct HostApp: App {
    @StateObject private var hostManager = HostManager()

    var body: some Scene {
        MenuBarExtra(
            "OpenBench Host",
            systemImage: hostManager.isRunning
                ? "display"
                : "display.trianglebadge.exclamationmark"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if hostManager.isRunning {
                    Text("Streaming")
                        .font(.headline)
                    if hostManager.currentFps > 0 {
                        Text("\(hostManager.currentFps) fps  ·  \(hostManager.bitrateMbps, specifier: "%.1f") Mbps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(hostManager.statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Idle")
                        .font(.headline)
                    if hostManager.statusMessage != "Idle" {
                        Text(hostManager.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                if !hostManager.hasScreenRecordingPermission {
                    Button("Grant Screen Recording Permission") {
                        hostManager.requestScreenRecording()
                    }
                }

                if !PermissionChecker.accessibility {
                    Button("Grant Accessibility Permission") {
                        PermissionChecker.requestAccessibility()
                    }
                }

                Toggle("Stream", isOn: $hostManager.isRunning)
                    .disabled(!hostManager.hasScreenRecordingPermission)
                    .toggleStyle(.switch)

                Divider()

                Button("Quit OpenBench Host") {
                    hostManager.stop()
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(8)
        }
        .menuBarExtraStyle(.window)
    }
}
