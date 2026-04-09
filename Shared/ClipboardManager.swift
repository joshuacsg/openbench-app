// ClipboardManager.swift — Monitors and writes the system clipboard,
// bridging UIPasteboard / NSPasteboard to the flux ControlMessage protocol.
//
// On iOS there is no clipboard-change notification, so we poll every 500 ms.
// On macOS we poll NSPasteboard.changeCount on the same cadence.
//
// Loop-suppression: text that arrived from the host is stored in `lastSeen`
// so that the outgoing poll callback doesn't echo it back.

import Foundation
import Combine

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public final class ClipboardManager: ObservableObject {
    /// Called whenever the local clipboard changes with text the host
    /// should receive.  Not called for changes made via `write(_:)`.
    public var onClipboardChanged: ((String) -> Void)?

    /// The most-recently written text (from the host).  Used to suppress
    /// re-sending that text back to the host on the next poll tick.
    @Published public private(set) var lastSeen: String = ""

    private var timer: AnyCancellable?

#if canImport(AppKit)
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
#endif

    public init() {
        // On macOS, poll NSPasteboard for changes. On iOS, polling
        // UIPasteboard triggers the system paste-permission dialog on
        // every read (iOS 16+), so we skip polling entirely. iOS
        // clipboard sync is handled on-demand via paste shortcut only.
#if canImport(AppKit)
        startPolling()
#endif
    }

    deinit {
        timer?.cancel()
    }

    // MARK: - Public API

    /// Write text to the system clipboard.  Updates `lastSeen` so the next
    /// poll tick does not echo the value back to the host.
    public func write(_ text: String) {
        lastSeen = text
#if canImport(UIKit)
        UIPasteboard.general.string = text
#elseif canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount
#endif
    }

    // MARK: - Polling

    private func startPolling() {
        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.poll()
            }
    }

    private func poll() {
#if canImport(AppKit)
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard let text = pb.string(forType: .string), !text.isEmpty else { return }
        guard text != lastSeen else { return }
        onClipboardChanged?(text)
#endif
    }
}
