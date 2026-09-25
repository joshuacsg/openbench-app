// ExternalDisplayScene.swift — the monitor's scene and what it shows.
//
// FastPortAppDelegate (OpenBenchApp.swift) hands connecting sessions
// with the non-interactive external-display role to this delegate, so
// a plugged-in monitor gets FastPort's own content instead of a mirror
// of the iPad. No Info.plist scene manifest is needed.
//
// Content: full-screen, aspect-fit video of the monitor session (black
// letterbox) with a software cursor while the iPad is its trackpad, or
// a minimal idle screen when nothing is streaming.

import SwiftUI
import UIKit

final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let host = UIHostingController(rootView: ExternalDisplayView(controller: .shared))
        host.view.backgroundColor = .black
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = host
        window.isHidden = false
        self.window = window
        ExternalDisplayController.shared.monitorSceneDidConnect(
            foreground: windowScene.activationState != .background
        )
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        ExternalDisplayController.shared.monitorSceneDidDisconnect()
        window = nil
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        ExternalDisplayController.shared.monitorSceneForegroundChanged(true)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Backgrounded app: drop the monitor stream (the network would
        // be suspended anyway); it restarts on return.
        ExternalDisplayController.shared.monitorSceneForegroundChanged(false)
    }
}

/// Root view of the monitor's window.
struct ExternalDisplayView: View {
    @ObservedObject var controller: ExternalDisplayController

    private var session: StreamSession { controller.monitorSession }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if session.state == .connected {
                MetalVideoView(session: session)
                    .ignoresSafeArea()
                cursorOverlay
            } else {
                idleScreen
            }
        }
        .statusBarHidden()
    }

    /// Software cursor at the trackpad's authoritative position, mapped
    /// from canvas pixels into the aspect-fitted video rect.
    private var cursorOverlay: some View {
        GeometryReader { geo in
            if controller.inputTargetsMonitor,
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
        }
    }
}
