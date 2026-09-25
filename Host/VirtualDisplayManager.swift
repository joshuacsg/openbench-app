// VirtualDisplayManager.swift — persisted settings + lifecycle for the
// FastPort virtual display.
//
// Independent of streaming: the display exists whenever it is enabled.
// Any create / destroy / resize fires `onDisplayChanged` so HostManager
// can restart flux-host (which may enumerate displays only at launch).

import Foundation
import CoreGraphics
import AppKit

@MainActor
final class VirtualDisplayManager: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            reconcile()
        }
    }
    @Published var preset: VirtualDisplayPreset {
        didSet {
            guard preset != oldValue else { return }
            UserDefaults.standard.set(preset.rawValue, forKey: Self.presetKey)
            reconcile()
        }
    }
    @Published var hiDPI: Bool {
        didSet {
            guard hiDPI != oldValue else { return }
            UserDefaults.standard.set(hiDPI, forKey: Self.hiDPIKey)
            reconcile()
        }
    }

    /// The live display, if one exists.
    @Published private(set) var display: VirtualDisplay?
    /// Last error / notice (unsupported, creation failed, terminated).
    @Published private(set) var statusMessage: String?

    let isSupported = VirtualDisplay.isSupported

    /// Called after the display was created, destroyed or recreated.
    var onDisplayChanged: (() -> Void)?

    private static let enabledKey = "host.virtualDisplay.enabled"
    private static let presetKey = "host.virtualDisplay.preset"
    private static let hiDPIKey = "host.virtualDisplay.hiDPI"

    init() {
        let defaults = UserDefaults.standard
        preset = defaults.string(forKey: Self.presetKey)
            .flatMap(VirtualDisplayPreset.init(rawValue:)) ?? .p1080
        hiDPI = defaults.bool(forKey: Self.hiDPIKey)
        // `--virtual-display` enables it for this launch only (not
        // persisted) — for scripted testing, like `--autostart`.
        isEnabled = defaults.bool(forKey: Self.enabledKey)
            || ProcessInfo.processInfo.arguments.contains("--virtual-display")

        if !isSupported {
            statusMessage = VirtualDisplayError.unsupported.errorDescription
        }
        reconcile()

        // Remove the display on quit, whatever path the quit takes.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.destroy() }
        }
    }

    var config: VirtualDisplayConfig {
        VirtualDisplayConfig(preset: preset, hiDPI: hiDPI)
    }

    /// Human-readable summary of the live display, e.g.
    /// "ID 5 · 1920×1080 pt · 3840×2160 px · 60 Hz".
    var summary: String? {
        guard let display else { return nil }
        guard let mode = display.currentMode else { return "ID \(display.displayID)" }
        var text = "ID \(display.displayID) · \(Int(mode.points.width))×\(Int(mode.points.height)) pt"
        if mode.pixels != mode.points {
            text += " · \(Int(mode.pixels.width))×\(Int(mode.pixels.height)) px"
        }
        return text + " · \(Int(mode.refreshRate.rounded())) Hz"
    }

    /// Bring the live display in line with the settings.
    private func reconcile() {
        guard isEnabled else {
            destroy()
            return
        }
        guard isSupported else {
            statusMessage = VirtualDisplayError.unsupported.errorDescription
            return
        }
        if let display, display.config == config { return }

        // Resolution / HiDPI changes need a fresh descriptor (maxPixels
        // is fixed at creation), so recreate rather than re-apply.
        let hadDisplay = display != nil
        display = nil
        do {
            let created = try VirtualDisplay(config: config) { [weak self] id in
                self?.handleTermination(of: id)
            }
            display = created
            statusMessage = nil
            print("[VirtualDisplay] created id=\(created.displayID) \(config.preset.rawValue) hiDPI=\(config.hiDPI)")
            // Mode selection may settle a moment later; refresh the
            // published summary once it has.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.objectWillChange.send()
            }
            onDisplayChanged?()
        } catch {
            print("[VirtualDisplay] create failed: \(error)")
            statusMessage = error.localizedDescription
            if hadDisplay { onDisplayChanged?() }
        }
    }

    /// Remove the display (no-op if none).
    func destroy() {
        guard let display else { return }
        print("[VirtualDisplay] destroying id=\(display.displayID)")
        self.display = nil
        onDisplayChanged?()
    }

    private func handleTermination(of id: CGDirectDisplayID) {
        // Ignore the callback for a display we already released.
        guard display?.displayID == id else { return }
        print("[VirtualDisplay] terminated by the system")
        display = nil
        statusMessage = "Virtual display was removed by the system"
        onDisplayChanged?()
    }
}
