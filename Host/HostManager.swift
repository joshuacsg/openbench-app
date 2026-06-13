// HostManager.swift — manages the flux-host subprocess lifecycle.
//
// Spawns the flux-host CLI binary as a child process with the `stream`
// command and `--advertise` flag. Parses stdout/stderr for live stats.

import Foundation
import CoreGraphics

@MainActor
final class HostManager: ObservableObject {
    @Published var isRunning = false {
        didSet {
            guard isRunning != oldValue else { return }
            if isRunning { start() } else { stop() }
        }
    }
    @Published var currentFps: Int = 0
    @Published var bitrateMbps: Double = 0
    @Published var statusMessage: String = "Idle"

    /// Ports the flux-host subprocess actually bound, parsed from its
    /// "pixel listen" / "pen listen" log lines (authoritative even if
    /// the requested port was taken or 0 = ephemeral).
    @Published var livePixelPort: UInt16?
    @Published var livePenPort: UInt16?
    /// The Mac's LAN IP (en0 preferred), for manual connects from the
    /// viewer when Bonjour discovery doesn't reach it.
    @Published var localIP: String?

    @Published var hasScreenRecordingPermission = false

    private var process: Process?
    private var outputPipe: Pipe?

    // MARK: - Quality / performance settings (persisted)

    /// Frame rate the host captures and encodes at.
    @Published var fps: UInt32 {
        didSet { persistAndRestart(fps, key: Self.fpsKey, old: oldValue) }
    }
    /// Encoder target bitrate. The host's AIMD controller treats this
    /// as the ceiling and adapts downward under congestion.
    @Published var bitrateKbps: UInt32 {
        didSet { persistAndRestart(bitrateKbps, key: Self.bitrateKey, old: oldValue) }
    }
    /// Cap on the longest edge of single-display streams, GPU-scaled by
    /// ScreenCaptureKit on the host. 0 = native resolution.
    @Published var maxDimension: UInt32 {
        didSet { persistAndRestart(maxDimension, key: Self.maxDimensionKey, old: oldValue) }
    }

    /// Debug latency HUD: when on, the spawned flux-stream subprocess
    /// gets FLUX_FRAME_TIMING=1 in its environment, so it emits a
    /// per-frame FrameTiming control message and the viewer HUD can show
    /// where the host spends its milliseconds (capture → encode → send).
    /// Off in production so we aren't emitting an extra control datagram
    /// per frame. Toggling it restarts the subprocess (env is fixed at
    /// launch).
    @Published var frameTimingEnabled: Bool {
        didSet {
            guard frameTimingEnabled != oldValue else { return }
            UserDefaults.standard.set(frameTimingEnabled, forKey: Self.frameTimingKey)
            restartDebounced()
        }
    }

    private static let fpsKey = "host.fps"
    private static let bitrateKey = "host.bitrateKbps"
    private static let maxDimensionKey = "host.maxDimension"
    private static let frameTimingKey = "host.frameTiming"

    // Fixed plumbing (not user-facing).
    private let pixelPort: UInt16 = 9000
    private let penPort: UInt16 = 9001
    private let keyframeInterval: UInt32 = 60
    // Upper cap only — flux-host derives the effective fragment payload
    // live from the path MTU (~1395 on typical paths). 1100 would cap it
    // and cost ~20% more packets.
    private let maxPayload: UInt32 = 1400

    /// flux-host stdout/stderr is mirrored here so the engine log (AIMD /
    /// pd / FEC / resolution-step lines) is readable on disk, not just in
    /// Xcode's console. Truncated on each stream start.
    static let logFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/flux-host.log")

    init() {
        let defaults = UserDefaults.standard
        let stored = { (key: String, fallback: UInt32) -> UInt32 in
            let v = defaults.integer(forKey: key)
            return v > 0 || defaults.object(forKey: key) != nil ? UInt32(max(0, v)) : fallback
        }
        // Lightweight defaults matching the viewer's: 1080p / 30 fps /
        // 5 Mbps. Viewers override per-session via SetStreamSettings.
        fps = stored(Self.fpsKey, 30)
        bitrateKbps = stored(Self.bitrateKey, 5_000)
        maxDimension = stored(Self.maxDimensionKey, 1920)
        // Off by default (production); key absent ⇒ false.
        frameTimingEnabled = defaults.bool(forKey: Self.frameTimingKey)
        checkPermissions()

        // `open "FastPort Host.app" --args --autostart` starts the
        // stream immediately on launch — lets a script / SSH session
        // bring the host up without touching the menu bar. Only fires
        // on fresh launches (macOS doesn't deliver --args to an
        // already-running instance).
        if ProcessInfo.processInfo.arguments.contains("--autostart") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.isRunning else { return }
                guard self.hasScreenRecordingPermission else {
                    self.statusMessage = "Autostart blocked: no screen recording permission"
                    return
                }
                self.isRunning = true
            }
        }
    }

    /// Persist a changed setting and restart the stream (debounced) so
    /// it takes effect — encoder/capture parameters are fixed at
    /// subprocess launch.
    private func persistAndRestart<T: Equatable>(_ value: T, key: String, old: T) {
        guard value != old else { return }
        UserDefaults.standard.set(value as? UInt32 ?? 0, forKey: key)
        restartDebounced()
    }

    private var restartWork: DispatchWorkItem?

    private func restartDebounced() {
        guard isRunning else { return }
        statusMessage = "Applying settings…"
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.stopSubprocess()
            // Give the old process a beat to release the UDP ports.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.isRunning else { return }
                self.start()
            }
        }
        restartWork = work
        // Debounce so dragging through picker options restarts once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func checkPermissions() {
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.checkPermissions()
        }
    }

    // MARK: - Subprocess management

    func start() {
        guard process == nil else { return }
        intentionalStop = false

        // Start a fresh on-disk engine log for this run (readable outside
        // Xcode's console); best-effort, and print where it landed.
        try? "".write(to: Self.logFileURL, atomically: false, encoding: .utf8)
        print("[HostManager] engine log → \(Self.logFileURL.path)")

        // Locate the flux-host binary. Check common locations.
        let binary = findFluxHostBinary()
        guard let binary else {
            statusMessage = "flux-host binary not found"
            isRunning = false
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.currentDirectoryURL = FileManager.default.temporaryDirectory
        var args = [
            "stream",
            "--pixel-bind", "0.0.0.0:\(pixelPort)",
            "--pen-bind", "0.0.0.0:\(penPort)",
            "--advertise",
            "--fps", "\(fps)",
            "--bitrate-kbps", "\(bitrateKbps)",
            "--keyframe-interval", "\(keyframeInterval)",
            "--max-payload", "\(maxPayload)",
        ]
        if maxDimension > 0 {
            args += ["--max-dimension", "\(maxDimension)"]
        }
        // Start on the main display (zero-copy single-display path)
        // instead of the unified composite — viewers default to the
        // first display anyway, and this avoids a restart at connect.
        args += ["--display-id", "\(CGMainDisplayID())"]
        proc.arguments = args

        // Inherit the launcher's environment, then opt into the host's
        // per-frame FrameTiming control messages when the debug HUD is
        // on. flux-stream reads FLUX_FRAME_TIMING once at startup (mere
        // presence enables it), so this is fixed for the subprocess'
        // lifetime — toggling frameTimingEnabled restarts it.
        if frameTimingEnabled {
            var env = ProcessInfo.processInfo.environment
            env["FLUX_FRAME_TIMING"] = "1"
            proc.environment = env
        }

        // Merge stdout+stderr so we can parse stats lines.
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        outputPipe = pipe

        // Read output asynchronously and parse stats.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.parseOutput(text)
            }
        }

        proc.terminationHandler = { [weak self] proc in
            print("[HostManager] process exited with status \(proc.terminationStatus)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A newer subprocess already replaced this one
                // (settings restart) — nothing to clean up.
                if let current = self.process, current !== proc { return }
                self.process = nil
                self.outputPipe = nil
                self.currentFps = 0
                self.bitrateMbps = 0
                self.livePixelPort = nil
                self.livePenPort = nil
                if self.isRunning && !self.intentionalStop {
                    self.isRunning = false
                    self.statusMessage = "Stopped (exit \(proc.terminationStatus))"
                }
            }
        }

        do {
            print("[HostManager] launching: \(binary)")
            print("[HostManager] args: \(proc.arguments ?? [])")
            try proc.run()
            process = proc
            statusMessage = "Starting…"
            localIP = Self.localIPv4Address()
        } catch {
            print("[HostManager] launch failed: \(error)")
            statusMessage = "Failed: \(error.localizedDescription)"
            isRunning = false
        }
    }

    func stop() {
        restartWork?.cancel()
        stopSubprocess()
        currentFps = 0
        bitrateMbps = 0
        livePixelPort = nil
        livePenPort = nil
        statusMessage = "Idle"
    }

    /// True while we are killing the subprocess on purpose (full stop
    /// or settings restart) so the termination handler doesn't flip
    /// `isRunning` off.
    private var intentionalStop = false

    private func stopSubprocess() {
        intentionalStop = true
        guard let proc = process, proc.isRunning else {
            process = nil
            return
        }
        proc.terminate()
        // Give it a moment, then force kill if needed.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if proc.isRunning { proc.interrupt() }
        }
        process = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
    }

    // MARK: - Output parsing

    /// Parse flux-host log lines for stats and status updates.
    /// Append raw engine output to the on-disk log (best-effort, so a
    /// log-write failure never affects streaming).
    static func appendToLog(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: logFileURL)
        }
    }

    private func parseOutput(_ text: String) {
        print("[flux-host] \(text)")
        Self.appendToLog(text)
        for line in text.components(separatedBy: .newlines) {
            if line.contains("stream stats") {
                if let fpsMatch = line.range(of: #"fps=(\d+)"#, options: .regularExpression) {
                    let fpsStr = line[fpsMatch].dropFirst(4)
                    currentFps = Int(fpsStr) ?? 0
                }
                if let mbpsMatch = line.range(of: #"mbps=([0-9.]+)"#, options: .regularExpression) {
                    let mbpsStr = line[mbpsMatch].dropFirst(5)
                    bitrateMbps = Double(mbpsStr) ?? 0
                }
            } else if line.contains("pixel client connected") {
                statusMessage = "Client connected"
            } else if line.contains("pixel listen") {
                statusMessage = "Listening"
                livePixelPort = Self.parsePort(from: line)
            } else if line.contains("pen") && line.contains("listen") {
                livePenPort = Self.parsePort(from: line)
            } else if line.contains("bonjour") || line.contains("advertising") {
                statusMessage = "Advertising"
            } else if line.contains("pixel send_datagram failed") {
                statusMessage = "Client disconnected"
                currentFps = 0
                bitrateMbps = 0
            }
        }
    }

    /// Extract the port from a flux-host listen line, e.g.
    /// `  pixel listen   : 0.0.0.0:9000`.
    private static func parsePort(from line: String) -> UInt16? {
        guard let match = line.range(of: #":(\d+)\s*$"#, options: .regularExpression) else {
            return nil
        }
        return UInt16(line[match].dropFirst().trimmingCharacters(in: .whitespaces))
    }

    /// The Mac's primary LAN IPv4 address (en0 preferred, otherwise the
    /// first non-loopback IPv4 interface).
    private static func localIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                sa, socklen_t(sa.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let address = String(cString: host)
            let name = String(cString: ifa.ifa_name)
            if name == "en0" { return address }
            if fallback == nil { fallback = address }
        }
        return fallback
    }

    // MARK: - Binary discovery

    private func findFluxHostBinary() -> String? {
        let candidates = [
            // Alongside the app bundle
            Bundle.main.bundlePath + "/../flux-host",
            // In the flux repo (development)
            NSHomeDirectory() + "/Documents/GitHub/flux/target/release/flux-host",
            NSHomeDirectory() + "/Documents/GitHub/flux/target/debug/flux-host",
            // In PATH
            "/usr/local/bin/flux-host",
            "/opt/homebrew/bin/flux-host",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}
