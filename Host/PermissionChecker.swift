// PermissionChecker.swift — macOS permission helpers.

import CoreGraphics
import ApplicationServices

struct PermissionChecker {
    /// Screen Recording: returns true if already granted.
    static var screenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Accessibility: needed for HidInjector (mouse/keyboard injection).
    static var accessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant Accessibility if not already trusted.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
