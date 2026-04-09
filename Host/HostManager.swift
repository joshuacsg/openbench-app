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

    @Published var hasScreenRecordingPermission = false

    private var process: Process?
    private var outputPipe: Pipe?

    // Configurable (future: SettingsView)
    private let pixelPort: UInt16 = 9000
    private let penPort: UInt16 = 9001
    private let fps: UInt32 = 60
    private let bitrateKbps: UInt32 = 10_000
    private let keyframeInterval: UInt32 = 60
    private let maxPayload: UInt32 = 1100

    init() {
        checkPermissions()
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
        proc.arguments = [
            "stream",
            "--pixel-bind", "0.0.0.0:\(pixelPort)",
            "--pen-bind", "0.0.0.0:\(penPort)",
            "--advertise",
            "--fps", "\(fps)",
            "--bitrate-kbps", "\(bitrateKbps)",
            "--keyframe-interval", "\(keyframeInterval)",
            "--max-payload", "\(maxPayload)",
        ]

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
                self.process = nil
                self.outputPipe = nil
                self.currentFps = 0
                self.bitrateMbps = 0
                if self.isRunning {
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
        } catch {
            print("[HostManager] launch failed: \(error)")
            statusMessage = "Failed: \(error.localizedDescription)"
            isRunning = false
        }
    }

    func stop() {
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
        currentFps = 0
        bitrateMbps = 0
        statusMessage = "Idle"
    }

    // MARK: - Output parsing

    /// Parse flux-host log lines for stats and status updates.
    private func parseOutput(_ text: String) {
        print("[flux-host] \(text)")
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
            } else if line.contains("bonjour") || line.contains("advertising") {
                statusMessage = "Advertising"
            } else if line.contains("pixel send_datagram failed") {
                statusMessage = "Client disconnected"
                currentFps = 0
                bitrateMbps = 0
            }
        }
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
