// ExternalDisplayControls.swift — iPad-side UI for a connected monitor.
//
//   * ExternalDisplayMenu: top-bar menu (next to the stream settings
//     gear) to pick the host display the monitor shows and the iPad's
//     mode (Trackpad / Second screen). Only shown while a monitor is
//     attached.
//   * ExternalTrackpadSurface: replaces the iPad's video in Trackpad
//     mode — a full-screen relative trackpad whose input lands on the
//     monitor session.

import SwiftUI

struct ExternalDisplayMenu: View {
    @ObservedObject var controller: ExternalDisplayController

    var body: some View {
        Menu {
            Section {
                Text(statusLine)
                if controller.isParked || isFailed {
                    Button {
                        controller.retry()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                }
            }

            if !controller.pickerDisplays.isEmpty && !controller.isParked {
                Section("Monitor shows") {
                    ForEach(controller.pickerDisplays) { display in
                        Button {
                            controller.selectMonitorDisplay(display.id)
                        } label: {
                            HStack {
                                Text(label(display))
                                if controller.monitorDisplayID == display.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            Section("iPad") {
                ForEach(ExternalDisplayController.IPadMode.allCases) { mode in
                    Button {
                        controller.iPadMode = mode
                    } label: {
                        HStack {
                            Text(mode.label)
                            if controller.iPadMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "display")
                    .font(.caption)
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.white.opacity(0.85))
        }
        .menuStyle(.borderlessButton)
    }

    private var isFailed: Bool {
        if case .failed = controller.status { return true }
        return false
    }

    private var statusLine: String {
        switch controller.status {
        case .idle: return "External display · idle"
        case .connecting: return "External display · connecting…"
        case .streaming:
            let fps = Int(controller.monitorSession.stats.currentFps)
            return "External display · \(fps) fps"
        case .failed: return "External display · reconnecting…"
        case .unsupported: return "Host doesn't support a second stream yet"
        case .viewerLimit: return "Host viewer limit reached"
        }
    }

    private var statusColor: Color {
        switch controller.status {
        case .streaming: return .green
        case .connecting, .failed: return .yellow
        case .unsupported, .viewerLimit: return .red
        case .idle: return .gray
        }
    }

    private func label(_ display: DisplayInfo) -> String {
        let base = display.name.isEmpty ? "\(display.width)×\(display.height)" : display.name
        return controller.iPadDisplayID == display.id ? "\(base) (iPad)" : base
    }
}

/// Full-screen trackpad driving the monitor's display.
struct ExternalTrackpadSurface: View {
    @ObservedObject var controller: ExternalDisplayController
    let inputManager: InputManager
    var showKeyboard: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                )

            VStack(spacing: 8) {
                Image(systemName: "rectangle.and.hand.point.up.left")
                    .font(.system(size: 34, weight: .light))
                Text("Trackpad")
                    .font(.system(.headline, design: .rounded))
                Text(hint)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.35))
            .allowsHitTesting(false)

            InputCaptureViewRepresentable(
                inputManager: inputManager,
                canvasSize: controller.monitorSession.canvasSize,
                showKeyboard: showKeyboard,
                trackpadMode: true,
                constrainTrackpadToCanvas: true,
                onCanvasPointerMoved: { pt in
                    // Keep the cursor up during two-finger scrolls (the
                    // capture view reports nil there).
                    if let pt { controller.monitorCursor = pt }
                }
            )
        }
    }

    private var hint: String {
        switch controller.status {
        case .streaming:
            return "Controlling the external display · tap to click, two fingers to scroll or right-click"
        case .failed:
            return "External display reconnecting…"
        default:
            return "Connecting to the external display…"
        }
    }
}
