// ExternalDisplayScene.swift — the monitor's scene and what it shows.
//
// A plugged-in monitor gets FastPort's own content instead of a mirror
// of the iPad by presenting a window in the app's non-interactive
// external-display scene. No Info.plist scene manifest is needed.
//
// Under the SwiftUI app lifecycle the external-display session is not
// reliably routed through the app delegate's configurationForConnecting
// (observed on the iPadOS 26 Simulator: the scene connects, but neither
// the config hook nor a custom delegateClass is consulted). So the
// window is attached from UIScene lifecycle notifications, which fire
// whichever delegate UIKit/SwiftUI installed; the config hook in
// FastPortAppDelegate is kept for runtimes that do consult it.
//
// Content: full-screen, aspect-fit video of the monitor session (black
// letterbox) with a software cursor while the iPad is its trackpad, or
// a minimal idle screen when nothing is streaming — turned by the
// user's monitor rotation setting.

import SwiftUI
import UIKit

/// Attaches / detaches FastPort's window on external-display scenes and
/// reports their lifecycle to ExternalDisplayController.
@MainActor
final class ExternalDisplaySceneMonitor {
    static let shared = ExternalDisplaySceneMonitor()

    /// Windows we own, keyed by scene.
    private var windows: [ObjectIdentifier: UIWindow] = [:]
    /// Keeps each window sized to its scene (the monitor's mode can
    /// change after connect — seen as 720×480 → 1920×1080).
    private var geometryObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var observers: [NSObjectProtocol] = []

    /// Start observing. Call once from application(_:didFinishLaunching…).
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (UIWindowScene) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let scene = note.object as? UIWindowScene,
                      scene.session.role == .windowExternalDisplayNonInteractive else { return }
                MainActor.assumeIsolated { handler(scene) }
            })
        }
        observe(UIScene.willConnectNotification) { [weak self] in self?.attach($0) }
        observe(UIScene.didDisconnectNotification) { [weak self] in self?.detach($0) }
        observe(UIScene.willEnterForegroundNotification) { _ in
            ExternalDisplayController.shared.monitorSceneForegroundChanged(true)
        }
        observe(UIScene.didEnterBackgroundNotification) { _ in
            // Backgrounded app: drop the monitor stream (the network
            // would be suspended anyway); it restarts on return.
            ExternalDisplayController.shared.monitorSceneForegroundChanged(false)
        }
        // A scene that connected before we started observing.
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes
        where scene.session.role == .windowExternalDisplayNonInteractive {
            attach(scene)
        }
    }

    private func attach(_ scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        guard windows[key] == nil else { return }
        // Monitors connect in a conservative default mode (720×480 on
        // the Simulator even when 1080p is offered). Take the screen's
        // preferred mode, else the largest; the geometry observer below
        // resizes the window when the switch lands.
        let screen = scene.screen
        if let best = screen.preferredMode
            ?? screen.availableModes.max(by: { $0.size.width * $0.size.height < $1.size.width * $1.size.height }),
           screen.currentMode != best {
            screen.currentMode = best
        }
        let host = UIHostingController(rootView: ExternalDisplayView(controller: .shared))
        host.view.backgroundColor = .black
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.frame = scene.coordinateSpace.bounds
        window.isHidden = false
        windows[key] = window
        geometryObservers[key] = scene.observe(\.effectiveGeometry, options: [.new]) { [weak window] scene, _ in
            DispatchQueue.main.async {
                window?.frame = scene.coordinateSpace.bounds
            }
        }
        ExternalDisplayController.shared.monitorSceneDidConnect(
            foreground: scene.activationState != .background
        )
    }

    private func detach(_ scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        geometryObservers.removeValue(forKey: key)?.invalidate()
        guard let window = windows.removeValue(forKey: key) else { return }
        window.isHidden = true
        if windows.isEmpty {
            ExternalDisplayController.shared.monitorSceneDidDisconnect()
        }
    }
}

/// Delegate class handed out for external-display sessions when the
/// config hook is consulted. Lifecycle work lives in
/// ExternalDisplaySceneMonitor (notifications fire either way); this
/// only needs to be a window-scene delegate.
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
}


/// Root view of the monitor's window.
struct ExternalDisplayView: View {
    @ObservedObject var controller: ExternalDisplayController

    private var session: StreamSession { controller.monitorSession }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            rotated {
                if session.state == .connected {
                    MetalVideoView(session: session)
                    cursorOverlay
                } else {
                    idleScreen
                }
            }
        }
        .statusBarHidden()
    }

    /// Lays content out in the rotated frame (width/height swapped on a
    /// quarter turn) and turns it to fit the monitor. Input needs no
    /// change: the picture reads upright on a monitor mounted that way.
    private func rotated<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let rotation = controller.monitorRotation
        let content = content()
        return GeometryReader { geo in
            let size = rotation.isQuarterTurn
                ? CGSize(width: geo.size.height, height: geo.size.width)
                : geo.size
            ZStack { content }
                .frame(width: size.width, height: size.height)
                .rotationEffect(.degrees(rotation.degrees))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .ignoresSafeArea()
    }

    /// Software cursor at the trackpad's authoritative position, mapped
    /// from canvas pixels into the aspect-fitted video rect.
    private var cursorOverlay: some View {
        GeometryReader { geo in
            if controller.monitorShowsCursor,
               let cursor = controller.monitorCursor,
               session.canvasSize.width > 0, session.canvasSize.height > 0 {
                let canvas = session.canvasSize
                let scale = min(geo.size.width / canvas.width, geo.size.height / canvas.height)
                let originX = (geo.size.width - canvas.width * scale) / 2
                let originY = (geo.size.height - canvas.height * scale) / 2
                CursorCrosshair()
                    .frame(width: 24, height: 24)
                    .position(x: originX + cursor.x * scale, y: originY + cursor.y * scale)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var idleScreen: some View {
        VStack(spacing: 10) {
            Text("FastPort")
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            Text(idleMessage)
                .font(.system(.title3, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    private var idleMessage: String {
        switch controller.status {
        case .idle: return "Waiting for stream"
        case .connecting: return "Connecting…"
        case .streaming: return "Starting stream…"
        case .failed: return "Reconnecting…"
        case .unsupported:
            return "This host doesn't support a second stream yet.\nUpdate FastPort Host on the Mac to use this display."
        case .viewerLimit:
            return "The host has reached its viewer limit.\nDisconnect another viewer, then retry from the iPad."
        }
    }
}
