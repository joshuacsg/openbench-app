// HostDaemon.swift — manages the flux-host stream subprocess.
//
// Bundles the `flux-host` binary in the app's Resources and spawns it
// as a child process. The menu bar UI controls lifecycle; status is
// read from the subprocess's stdout.

import Foundation
import Combine

@MainActor
public final class HostDaemon: ObservableObject {
    @Published public var isRunning = false
    @Published public var viewerCount = 0
    @Published public var lastError: String?

    private var process: Process?
    private var outputPipe: Pipe?

    public init() {}

    public func start() {
        guard !isRunning else { return }

        // Look for the flux-host binary bundled in Resources, or fall
        // back to a well-known path for development.
        let binary = Bundle.main.path(forResource: "flux-host", ofType: nil)
            ?? "/usr/local/bin/flux-host"

        guard FileManager.default.fileExists(atPath: binary) else {
            lastError = "flux-host binary not found at \(binary)"
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = [
            "stream",
            "--pixel-bind", "0.0.0.0:9000",
            "--pen-bind", "0.0.0.0:9001",
            "--advertise",
            "--fps", "60",
            "--bitrate-kbps", "10000",
            "--keyframe-interval", "60",
        ]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRunning = false
            }
        }

        do {
            try proc.run()
            process = proc
            outputPipe = pipe
            isRunning = true
            lastError = nil
        } catch {
            lastError = "Failed to start: \(error.localizedDescription)"
        }
    }

    public func stop() {
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        process = nil
        outputPipe = nil
        isRunning = false
    }
}
