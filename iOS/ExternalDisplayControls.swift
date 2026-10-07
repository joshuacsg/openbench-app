// ExternalDisplayControls.swift — iPad-side UI for a connected monitor.
//
//   * ExternalDisplayMenu: top-bar menu (next to the stream settings
//     gear) to pick the host display the monitor shows, its rotation,
//     and the iPad's mode (Trackpad, or one of the host's displays). Only shown while a
//     monitor is attached.
//   * ExternalTrackpadSurface: replaces the iPad's video in Trackpad
//     mode — a full-screen relative trackpad whose input lands on the
//     monitor session. It shrinks above the docked soft keyboard and
//     grows back when the keyboard floats or hides.

import SwiftUI
import UIKit

/// Top-bar menu for the monitor. Equatable over a value snapshot so the
/// controller's per-tick republishes (it forwards the monitor session's
/// ~2 Hz stats) don't rebuild the open menu — that made its list flicker
/// and drop taps, as the stream settings menu did. Live fps is in the
/// status pill instead.
struct ExternalDisplayMenu: View, Equatable {
    /// What the menu shows; only a change here redraws it.
    struct Snapshot: Equatable {
        var status: ExternalDisplayController.MonitorStatus
        var isParked: Bool
        var pickerDisplays: [DisplayInfo]
        var monitorDisplayID: UInt32?
        var iPadDisplayID: UInt32?
        var iPadMode: ExternalDisplayController.IPadMode
        var rotation: ExternalDisplayController.MonitorRotation

        @MainActor init(_ controller: ExternalDisplayController) {
            status = controller.status
            isParked = controller.isParked
            pickerDisplays = controller.pickerDisplays
            monitorDisplayID = controller.monitorDisplayID
            iPadDisplayID = controller.iPadDisplayID
            iPadMode = controller.iPadMode
            rotation = controller.monitorRotation
        }
    }

    /// Unobserved: used only for actions.
    let controller: ExternalDisplayController
    let state: Snapshot
    /// Points the iPad's own stream at a host display (StreamView owns
    /// that selection).
    let onSelectIPadDisplay: (UInt32) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.state == rhs.state }

    var body: some View {
        Menu {
            Section {
                Text(statusLine)
                if state.isParked || isFailed {
                    Button {
                        controller.retry()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                }
            }

            if !state.pickerDisplays.isEmpty && !state.isParked {
                Section("Monitor shows") {
                    ForEach(state.pickerDisplays) { display in
                        Button {
                            controller.selectMonitorDisplay(display.id)
                        } label: {
                            HStack {
                                Text(label(display))
                                if state.monitorDisplayID == display.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            Section {
                Menu {
                    ForEach(ExternalDisplayController.MonitorRotation.allCases) { rotation in
                        Button {
                            controller.monitorRotation = rotation
                        } label: {
                            HStack {
                                Text(rotation.label)
                                if state.rotation == rotation {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Rotate monitor · \(state.rotation.label)", systemImage: "rotate.right")
                }
            }

            Section("iPad shows") {
                Button {
                    controller.iPadMode = .trackpad
                } label: {
                    HStack {
                        Text(ExternalDisplayController.IPadMode.trackpad.label)
                        if state.iPadMode == .trackpad {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                ForEach(state.pickerDisplays) { display in
                    Button {
                        onSelectIPadDisplay(display.id)
                        controller.iPadMode = .secondScreen
                    } label: {
                        HStack {
                            Text(iPadLabel(display))
                            if state.iPadMode == .secondScreen && state.iPadDisplayID == display.id {
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
        if case .failed = state.status { return true }
        return false
    }

    private var statusLine: String {
        switch state.status {
        case .idle: return "External display · idle"
        case .connecting: return "External display · connecting…"
        case .streaming: return "External display · streaming"
        case .failed: return "External display · reconnecting…"
        case .unsupported: return "Host doesn't support a second stream yet"
        case .viewerLimit: return "Host viewer limit reached"
        }
    }

    private var statusColor: Color {
        switch state.status {
        case .streaming: return .green
        case .connecting, .failed: return .yellow
        case .unsupported, .viewerLimit: return .red
        case .idle: return .gray
        }
    }

    private func label(_ display: DisplayInfo) -> String {
        let base = display.name.isEmpty ? "\(display.width)×\(display.height)" : display.name
        return state.iPadDisplayID == display.id ? "\(base) (iPad)" : base
    }

    private func iPadLabel(_ display: DisplayInfo) -> String {
        let base = display.name.isEmpty ? "\(display.width)×\(display.height)" : display.name
        return state.monitorDisplayID == display.id ? "\(base) (monitor)" : base
    }
}

/// Full-screen trackpad driving the monitor's display.
struct ExternalTrackpadSurface: View {
    @ObservedObject var controller: ExternalDisplayController
    let inputManager: InputManager
    var showKeyboard: Bool

    @StateObject private var keyboard = DockedKeyboardTracker()

    var body: some View {
        GeometryReader { geo in
            surface
                .frame(height: surfaceHeight(in: geo.frame(in: .global)))
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// Full height, or the space above the docked keyboard (and its key
    /// bar) with a small gap. StreamView opts out of SwiftUI keyboard
    /// avoidance, so this is measured from the keyboard frame directly.
    private func surfaceHeight(in frame: CGRect) -> CGFloat {
        guard let top = keyboard.dockedTop, top < frame.maxY else {
            return frame.height
        }
        return max(120, top - frame.minY - 8)
    }

    private var surface: some View {
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
                trackpadGestures: controller.monitorSession.trackpadGestures,
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

/// Top edge of the docked software keyboard, in the app window's
/// coordinates (SwiftUI's `.global` space); nil while the keyboard is
/// hidden, floating or undocked. Changes animate with the keyboard.
@MainActor
final class DockedKeyboardTracker: ObservableObject {
    @Published private(set) var dockedTop: CGFloat?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.update(from: note, hiding: false) }
        })
        observers.append(center.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.update(from: note, hiding: true) }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func update(from note: Notification, hiding: Bool) {
        let top = hiding ? nil : Self.dockedTop(note)
        guard top != dockedTop else { return }
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
        // Docking/undocking can report a zero duration; animate anyway.
        withAnimation(.easeInOut(duration: duration > 0 ? duration : 0.3)) {
            dockedTop = top
        }
    }

    private static func dockedTop(_ note: Notification) -> CGFloat? {
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let window = appWindow else { return nil }
        let screen = window.screen.bounds
        // A docked keyboard (or a hardware keyboard's key bar) spans the
        // screen width and sits on its bottom edge; a floating keyboard
        // is a narrow panel anywhere on screen, and an undocked/hidden
        // one ends off-screen.
        guard end.width >= screen.width - 1,
              end.minY < screen.maxY,
              end.maxY >= screen.maxY - 1 else { return nil }
        return window.convert(end, from: window.screen.coordinateSpace).minY
    }

    /// The iPad's own app window (not the external monitor's).
    private static var appWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
            .sorted { ($0.activationState == .foregroundActive ? 0 : 1) < ($1.activationState == .foregroundActive ? 0 : 1) }
            .lazy
            .compactMap { $0.keyWindow ?? $0.windows.first }
            .first
    }
}
