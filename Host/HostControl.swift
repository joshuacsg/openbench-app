// HostControl.swift — `fastport-host://` URL commands, so scripts and
// agents can drive the running host without the menu bar:
//
//   open "fastport-host://stream/on"        (also stream/off, stream/toggle)
//   open "fastport-host://set?fps=60&bitrate=20000"
//   open "fastport-host://status"
//   open "fastport-host://quit"
//
// `set` keys: fps (1–240), bitrate (kbps, 500–200000), resolution
// (longest edge px, 0 = native, else 320–7680), latencyHUD (on/off),
// virtualDisplay (on/off), virtualDisplaySize (1920x1080, 1920x1200,
// 2560x1440, 3840x2160), hiDPI (on/off). Settings apply live through
// the same path as the menu (a debounced stream restart).
//
// A URL can't return anything, so each command appends one line to
// ~/Library/Logs/fastport-host-control.log: the command and either
// "ok …" with the resulting state or "error …". `status` just logs the
// state. Opening a URL launches the app if it isn't running.

import AppKit

@MainActor
enum HostControl {
    static let scheme = "fastport-host"

    static let logFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/fastport-host-control.log")

    static func handle(_ url: URL, host: HostManager) {
        guard url.scheme?.lowercased() == scheme else { return }
        let command = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" })
            .filter { !$0.isEmpty }
            .joined(separator: "/")
            .lowercased()
        let result: Result<String?, ControlError>
        switch command {
        case "stream/on": result = setStreaming(true, host: host)
        case "stream/off": result = setStreaming(false, host: host)
        case "stream/toggle": result = setStreaming(!host.isRunning, host: host)
        case "set": result = applySettings(url, host: host)
        case "status": result = .success(nil)
        case "quit":
            log(url, "ok quitting")
            host.stop()
            host.virtualDisplay.destroy()
            NSApplication.shared.terminate(nil)
            return
        default:
            result = .failure(.init("unknown command '\(command)' (stream/on, stream/off, stream/toggle, set, status, quit)"))
        }
        switch result {
        case .success(let note):
            log(url, "ok " + [note, state(host)].compactMap { $0 }.joined(separator: " · "))
        case .failure(let error):
            log(url, "error \(error.message) · \(state(host))")
        }
    }

    struct ControlError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private static func setStreaming(_ on: Bool, host: HostManager) -> Result<String?, ControlError> {
        if on {
            host.checkPermissions()
            guard host.hasScreenRecordingPermission else {
                return .failure(.init("no Screen Recording permission"))
            }
        }
        host.isRunning = on
        // Starting is asynchronous; the engine log shows it listening.
        return .success(on ? "starting" : nil)
    }

    /// Validate every key first, then apply all or nothing.
    private static func applySettings(_ url: URL, host: HostManager) -> Result<String?, ControlError> {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard !items.isEmpty else { return .failure(.init("set needs at least one key=value")) }
        var changes: [() -> Void] = []
        for item in items {
            let value = item.value ?? ""
            switch item.name {
            case "fps":
                guard let v = UInt32(value), (1...240).contains(v) else { return bad(item, "1–240") }
                changes.append { host.fps = v }
            case "bitrate":
                guard let v = UInt32(value), (500...200_000).contains(v) else { return bad(item, "500–200000 kbps") }
                changes.append { host.bitrateKbps = v }
            case "resolution":
                guard let v = UInt32(value), v == 0 || (320...7680).contains(v) else {
                    return bad(item, "0 (native) or 320–7680")
                }
                changes.append { host.maxDimension = v }
            case "latencyHUD":
                guard let v = flag(value) else { return bad(item, "on/off") }
                changes.append { host.frameTimingEnabled = v }
            case "virtualDisplay":
                guard let v = flag(value) else { return bad(item, "on/off") }
                guard !v || host.virtualDisplay.isSupported else {
                    return .failure(.init("virtual display unsupported on this Mac"))
                }
                changes.append { host.virtualDisplay.isEnabled = v }
            case "virtualDisplaySize":
                guard let v = VirtualDisplayPreset(rawValue: value) else {
                    return bad(item, VirtualDisplayPreset.allCases.map(\.rawValue).joined(separator: ", "))
                }
                changes.append { host.virtualDisplay.preset = v }
            case "hiDPI":
                guard let v = flag(value) else { return bad(item, "on/off") }
                changes.append { host.virtualDisplay.hiDPI = v }
            default:
                return .failure(.init("unknown key '\(item.name)' (fps, bitrate, resolution, latencyHUD, virtualDisplay, virtualDisplaySize, hiDPI)"))
            }
        }
        changes.forEach { $0() }
        return .success(host.isRunning ? "applying (stream restarts)" : nil)
    }

    private static func bad(_ item: URLQueryItem, _ expected: String) -> Result<String?, ControlError> {
        .failure(.init("bad \(item.name)='\(item.value ?? "")' (expected \(expected))"))
    }

    private static func flag(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "on", "1", "true", "yes": return true
        case "off", "0", "false", "no": return false
        default: return nil
        }
    }

    private static func state(_ host: HostManager) -> String {
        let vd = host.virtualDisplay
        return [
            "streaming=\(host.isRunning ? "on" : "off")",
            "status=\"\(host.statusMessage)\"",
            "fps=\(host.fps)",
            "bitrate=\(host.bitrateKbps)",
            "resolution=\(host.maxDimension)",
            "latencyHUD=\(host.frameTimingEnabled ? "on" : "off")",
            "virtualDisplay=\(vd.isEnabled ? "on" : "off")",
            "virtualDisplaySize=\(vd.preset.rawValue)",
            "hiDPI=\(vd.hiDPI ? "on" : "off")",
        ].joined(separator: " ")
    }

    private static func log(_ url: URL, _ outcome: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(url.absoluteString) → \(outcome)\n"
        print("[HostControl] \(line)", terminator: "")
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: logFileURL)
        }
    }
}

/// Receives `fastport-host://` URLs (the SwiftUI MenuBarExtra scene has
/// no window to take them).
final class HostAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            HostControl.handle(url, host: .shared)
        }
    }
}
