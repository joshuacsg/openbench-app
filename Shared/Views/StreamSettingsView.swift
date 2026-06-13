// StreamSettingsView.swift — viewer-side stream quality controls.
//
// A gear Menu in the StreamView top bar that sends SetStreamSettings
// to the host. Bitrate applies live (it moves the host's adaptive-
// bitrate ceiling); resolution and frame rate restart the host's
// capture pipeline, which interrupts the stream for ~0.5 s.
//
// Selections persist (@AppStorage) and are re-applied automatically on
// connect once the user has customized anything, so "my iPad prefers
// 2.5K @ 60" survives app restarts and host switches.

import SwiftUI

public struct StreamSettingsView: View {
    /// Sends a SetStreamSettings control message to the host.
    public var onApply: (_ fps: UInt32, _ bitrateKbps: UInt32, _ maxDimension: UInt32) -> Void

    // Lightweight defaults: 1080p / 30 fps / 5 Mbps favors latency and
    // battery; users can dial quality up from the gear menu. The viewer
    // is authoritative — these are applied to the host on every connect.
    @AppStorage("stream.maxDimension") private var maxDimension: Int = 1920
    @AppStorage("stream.fps") private var fps: Int = 30
    @AppStorage("stream.bitrateKbps") private var bitrateKbps: Int = 5_000

    public init(
        onApply: @escaping (_ fps: UInt32, _ bitrateKbps: UInt32, _ maxDimension: UInt32) -> Void
    ) {
        self.onApply = onApply
    }

    private static let resolutionOptions: [(label: String, value: Int)] = [
        ("1080p-class (1920)", 1920),
        ("2.5K (2560)", 2560),
        ("4K (3840)", 3840),
        ("Native", 0),
    ]
    private static let fpsOptions = [30, 60, 120]
    private static let bitrateOptions: [(label: String, kbps: Int)] = [
        ("5 Mbps", 5_000),
        ("10 Mbps", 10_000),
        ("20 Mbps", 20_000),
        ("30 Mbps", 30_000),
    ]

    public var body: some View {
        Menu {
            Section("Resolution") {
                ForEach(Self.resolutionOptions, id: \.value) { option in
                    Button {
                        maxDimension = option.value
                        apply()
                    } label: {
                        HStack {
                            Text(option.label)
                            if maxDimension == option.value {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Section("Frame rate") {
                ForEach(Self.fpsOptions, id: \.self) { option in
                    Button {
                        fps = option
                        apply()
                    } label: {
                        HStack {
                            Text("\(option) fps")
                            if fps == option {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Section("Max bitrate") {
                ForEach(Self.bitrateOptions, id: \.kbps) { option in
                    Button {
                        bitrateKbps = option.kbps
                        apply()
                    } label: {
                        HStack {
                            Text(option.label)
                            if bitrateKbps == option.kbps {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(.white.opacity(0.85))
        }
        .menuStyle(.borderlessButton)
        // No auto-assert on connect: the host is the source of truth for
        // the active settings, which the viewer adopts from the Welcome
        // (two-way settings). Picking an option here still applies it.
    }

    private func apply() {
        onApply(UInt32(fps), UInt32(bitrateKbps), UInt32(maxDimension))
    }
}
