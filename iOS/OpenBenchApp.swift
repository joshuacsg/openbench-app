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

/// Claims external monitors: a connecting non-interactive external-
/// display session gets ExternalDisplaySceneDelegate (our own content)
/// instead of the system mirror. Every other role keeps SwiftUI's
/// default configuration.
final class FastPortAppDelegate: NSObject, UIApplicationDelegate {
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
        return connectingSceneSession.configuration
    }
}
