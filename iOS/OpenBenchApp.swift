// OpenBenchApp.swift — iOS/iPadOS entry point.

import SwiftUI
import UIKit

@main
struct OpenBenchApp: App {
    @UIApplicationDelegateAdaptor(FastPortAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Claims external monitors: starts ExternalDisplaySceneMonitor, and
/// hands a connecting non-interactive external-display session
/// ExternalDisplaySceneDelegate when UIKit asks. Every other role keeps
/// SwiftUI's default configuration.
final class FastPortAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Attaches our window to external-display scenes via UIScene
        // notifications (see ExternalDisplayScene.swift for why).
        ExternalDisplaySceneMonitor.shared.start()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            let config = UISceneConfiguration(name: "External Display", sessionRole: connectingSceneSession.role)
            config.delegateClass = ExternalDisplaySceneDelegate.self
            return config
        }
        // A fresh config with no delegateClass lets SwiftUI install its
        // own scene delegate. (Returning `connectingSceneSession
        // .configuration` hands SwiftUI its own delegate class back, and
        // it then wraps itself → infinite responds(to:) recursion.)
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }
}
