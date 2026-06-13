// HostApp.swift — macOS menu bar host app.
//
// Runs the flux-host CLI as a subprocess and exposes status via a
// SwiftUI MenuBarExtra. macOS 14+ required.

import SwiftUI

/// Quality / performance settings section shown in the menu window.
struct HostSettingsView: View {
    @ObservedObject var hostManager: HostManager

    private static let resolutionOptions: [(label: String, value: UInt32)] = [
        ("Native", 0),
        ("4K (3840)", 3840),
        ("2.5K (2560)", 2560),
        ("1080p-class (1920)", 1920),
    ]
    private static let fpsOptions: [UInt32] = [30, 60, 120]
    private static let bitrateOptions: [(label: String, kbps: UInt32)] = [
        ("5 Mbps", 5_000),
        ("10 Mbps", 10_000),
        ("20 Mbps", 20_000),
        ("30 Mbps", 30_000),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quality & Performance")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Resolution", selection: $hostManager.maxDimension) {
                ForEach(Self.resolutionOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }

            Picker("Frame rate", selection: $hostManager.fps) {
                ForEach(Self.fpsOptions, id: \.self) { fps in
                    Text("\(fps) fps").tag(fps)
                }
            }

            Picker("Max bitrate", selection: $hostManager.bitrateKbps) {
                ForEach(Self.bitrateOptions, id: \.kbps) { option in
                    Text(option.label).tag(option.kbps)
                }
            }

            Text("Resolution caps the longest edge (GPU-scaled). Bitrate adapts down automatically under congestion. Changes restart the stream.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .pickerStyle(.menu)
        .controlSize(.small)
    }
}

@main
struct HostApp: App {
    @StateObject private var hostManager = HostManager()
    @AppStorage("host.showSettings") private var showSettings = false

    var body: some Scene {
        MenuBarExtra(
            "FastPort Host",
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
                    if let pixel = hostManager.livePixelPort {
                        let host = hostManager.localIP ?? "0.0.0.0"
                        let pen = hostManager.livePenPort.map { "  ·  pen \($0)" } ?? ""
                        Text("\(host):\(String(pixel))\(pen)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
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

                Button {
                    withAnimation { showSettings.toggle() }
                } label: {
                    HStack {
                        Image(systemName: "gearshape")
                        Text("Settings")
                        Spacer()
                        Image(systemName: showSettings ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if showSettings {
                    HostSettingsView(hostManager: hostManager)
                }

                Divider()

                Button("Quit FastPort Host") {
                    hostManager.stop()
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(8)
        }
        .menuBarExtraStyle(.window)
    }
}
