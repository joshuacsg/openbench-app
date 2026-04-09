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

#if canImport(UIKit)
    private var lastChangeCount: Int = UIPasteboard.general.changeCount
#elseif canImport(AppKit)
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
#endif

    public init() {
        startPolling()
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
        // Update our tracked change count so the write itself doesn't fire
        // the callback on the next tick.
        lastChangeCount = UIPasteboard.general.changeCount
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
#if canImport(UIKit)
        let pb = UIPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard let text = pb.string, !text.isEmpty else { return }
#elseif canImport(AppKit)
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard let text = pb.string(forType: .string), !text.isEmpty else { return }
#else
        return
#endif
        // Suppress echo of text that just arrived from the host.
        guard text != lastSeen else { return }
        onClipboardChanged?(text)
    }
}
