# Handoff: OpenBench Host — macOS Menu Bar App

> Turn the `flux-host stream` CLI into a native macOS menu bar app that
> lives in `openbench-app/Host/`. The XcodeGen target already exists in
> `project.yml` as "OpenBench Host" with `LSUIElement: true`.

## Goal

A macOS `.app` bundle that:
1. Shows a menu bar icon (SF Symbol `display` or similar).
2. Starts/stops the streaming pipeline on demand.
3. Shows live status: FPS, bitrate, connected client count.
4. Advertises on Bonjour automatically so iPad clients discover it.
5. Handles macOS permissions (Screen Recording, Accessibility) with
   prompts when missing.

The Host directory is currently empty — everything needs to be built.

---

## Architecture

```
openbench-app/
  Host/
    OpenBenchHostApp.swift    ← @main, MenuBarExtra scene
    HostManager.swift         ← ObservableObject, owns the Rust FFI lifecycle
    PermissionChecker.swift   ← Screen Recording + Accessibility checks
    SettingsView.swift        ← Optional: bitrate, FPS, display picker

flux/
  crates/
    flux-host-ffi/            ← NEW crate: C ABI wrapper around stream pipeline
      Cargo.toml
      src/lib.rs
      include/flux_host.h     ← C header for Swift bridging
```

### Data flow

```
SwiftUI MenuBarExtra  →  HostManager  →  FFI (flux_host_start)
                                              ↓
                                        tokio runtime on bg thread
                                              ↓
                                    DualServer::bind (QUIC pixel + pen)
                                    DiscoveryAdvertiser::advertise (Bonjour)
                                    encode_capture_loop (scap → cidre HEVC)
                                    stream_pixel_to_client (fragment → send)
                                    control_recv (HidInjector)
```

---

## Step 1: Create `flux-host-ffi` crate

**Location:** `flux/crates/flux-host-ffi/`

This crate wraps the existing `run_stream` logic from
`flux-host/src/main.rs:1393` into a C-callable API.

### Cargo.toml

```toml
[package]
name = "flux-host-ffi"
version = "0.0.1"
edition = "2021"

[lib]
crate-type = ["staticlib"]

[dependencies]
flux-transport = { path = "../flux-transport" }
flux-protocol  = { path = "../flux-protocol" }
flux-capture   = { path = "../flux-capture" }
flux-codec     = { path = "../flux-codec" }
flux-input     = { path = "../flux-input" }
tokio = { version = "1", features = ["full"] }
quinn = "0.11"
bytes = "1"
anyhow = "1"
serde_json = "1"
tracing = "0.1"
tracing-subscriber = "0.3"
```

### C ABI (`src/lib.rs`)

```rust
use std::ffi::CStr;
use std::os::raw::c_char;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

/// Opaque handle returned to Swift. Drop to stop.
pub struct FluxHostHandle {
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
    // Live stats readable from Swift:
    pub frames_sent: Arc<AtomicU64>,
    pub bytes_sent: Arc<AtomicU64>,
}

#[repr(C)]
pub struct FluxHostConfig {
    pub pixel_port: u16,
    pub pen_port: u16,
    pub fps: u32,
    pub bitrate_kbps: u32,
    pub keyframe_interval: u32,
    pub max_payload: u32,
    pub advertise: bool,
}

/// Start the streaming host. Returns an opaque handle.
/// Call `flux_host_stop` to tear down.
#[no_mangle]
pub extern "C" fn flux_host_start(config: FluxHostConfig) -> *mut FluxHostHandle {
    // Build a tokio runtime on a dedicated OS thread.
    // Inside it, run the equivalent of run_stream().
    // Store the stop flag so flux_host_stop can signal shutdown.
    todo!("see implementation notes below")
}

/// Read current FPS (frames in the last reporting interval).
#[no_mangle]
pub extern "C" fn flux_host_frames_sent(handle: *const FluxHostHandle) -> u64 {
    unsafe { (*handle).frames_sent.load(Ordering::Relaxed) }
}

/// Read total bytes sent.
#[no_mangle]
pub extern "C" fn flux_host_bytes_sent(handle: *const FluxHostHandle) -> u64 {
    unsafe { (*handle).bytes_sent.load(Ordering::Relaxed) }
}

/// Stop the host and free the handle.
#[no_mangle]
pub extern "C" fn flux_host_stop(handle: *mut FluxHostHandle) {
    if handle.is_null() { return; }
    let h = unsafe { Box::from_raw(handle) };
    h.stop.store(true, Ordering::SeqCst);
    // The tokio runtime will see the stop flag and shut down.
    if let Some(thread) = h.thread {
        let _ = thread.join();
    }
}
```

### Implementation notes for `flux_host_start`

The body should be a near-copy of `run_stream` from
`flux-host/src/main.rs:1393-1581`. Key adaptations:

1. Create a `tokio::runtime::Runtime` (multi-thread, 4 workers).
2. Move the `DualServer::bind`, `DiscoveryAdvertiser::advertise`,
   pen accept loop, pixel accept loop, and stats reporter into
   `rt.block_on(async { ... })` on the spawned thread.
3. Check `stop.load(Ordering::Relaxed)` in the stats loop and the
   accept loops so `flux_host_stop` causes a clean shutdown.
4. The `encode_capture_loop` and `stream_pixel_to_client` functions
   can be extracted from `flux-host/src/main.rs` verbatim — they're
   already standalone functions (lines 1584-1855).

**Do NOT rewrite the pipeline.** Extract the existing functions and
call them from the FFI entry point.

### C header (`include/flux_host.h`)

```c
#pragma once
#include <stdint.h>
#include <stdbool.h>

typedef struct FluxHostHandle FluxHostHandle;

typedef struct {
    uint16_t pixel_port;
    uint16_t pen_port;
    uint32_t fps;
    uint32_t bitrate_kbps;
    uint32_t keyframe_interval;
    uint32_t max_payload;
    bool     advertise;
} FluxHostConfig;

FluxHostHandle* flux_host_start(FluxHostConfig config);
uint64_t        flux_host_frames_sent(const FluxHostHandle* handle);
uint64_t        flux_host_bytes_sent(const FluxHostHandle* handle);
void            flux_host_stop(FluxHostHandle* handle);
```

---

## Step 2: Build the static library

```bash
cd flux
cargo build --release -p flux-host-ffi

# Output: target/release/libflux_host_ffi.a
```

### Create XCFramework (or link directly)

For a single-platform (macOS arm64) build, direct linking is fine:

```bash
# In project.yml, add to OpenBench Host settings:
#   OTHER_LDFLAGS: -lflux_host_ffi -L$(PROJECT_DIR)/../flux/target/release
#   LIBRARY_SEARCH_PATHS: $(PROJECT_DIR)/../flux/target/release
#   SWIFT_OBJC_BRIDGING_HEADER: Host/FluxHost-Bridging-Header.h
```

Or wrap in an XCFramework for cleaner integration:

```bash
xcodebuild -create-xcframework \
  -library target/release/libflux_host_ffi.a \
  -headers crates/flux-host-ffi/include \
  -output FluxHostFFI.xcframework
```

---

## Step 3: Swift source files

### `Host/FluxHost-Bridging-Header.h`

```c
#include "flux_host.h"
```

### `Host/OpenBenchHostApp.swift`

```swift
import SwiftUI

@main
struct OpenBenchHostApp: App {
    @StateObject private var hostManager = HostManager()

    var body: some Scene {
        MenuBarExtra("OpenBench Host", systemImage: hostManager.isRunning ? "display" : "display.trianglebadge.exclamationmark") {
            VStack(alignment: .leading, spacing: 8) {
                if hostManager.isRunning {
                    Text("Streaming")
                        .font(.headline)
                    Text("\(hostManager.currentFps) fps  ·  \(hostManager.bitrateMbps, specifier: "%.1f") Mbps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Idle")
                        .font(.headline)
                }

                Divider()

                if !hostManager.hasScreenRecordingPermission {
                    Button("Grant Screen Recording Permission") {
                        hostManager.requestScreenRecording()
                    }
                }

                Toggle("Stream", isOn: $hostManager.isRunning)
                    .disabled(!hostManager.hasScreenRecordingPermission)
                    .toggleStyle(.switch)

                Divider()

                Button("Quit") {
                    hostManager.stop()
                    NSApp.terminate(nil)
                }
            }
            .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
```

### `Host/HostManager.swift`

```swift
import Foundation
import CoreGraphics

@MainActor
final class HostManager: ObservableObject {
    @Published var isRunning = false {
        didSet {
            if isRunning { start() } else { stop() }
        }
    }
    @Published var currentFps: Int = 0
    @Published var bitrateMbps: Double = 0

    @Published var hasScreenRecordingPermission = false

    private var handle: OpaquePointer? // FluxHostHandle*
    private var statsTimer: Timer?

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
        // CGPreflightScreenCaptureAccess returns true if the app
        // already has screen recording permission.
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecording() {
        // This opens System Settings → Privacy → Screen Recording.
        CGRequestScreenCaptureAccess()
        // Re-check after a delay (user has to grant manually).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.checkPermissions()
        }
    }

    func start() {
        guard handle == nil else { return }
        let config = FluxHostConfig(
            pixel_port: pixelPort,
            pen_port: penPort,
            fps: fps,
            bitrate_kbps: bitrateKbps,
            keyframe_interval: keyframeInterval,
            max_payload: maxPayload,
            advertise: true
        )
        handle = OpaquePointer(flux_host_start(config))
        startStatsPolling()
    }

    func stop() {
        statsTimer?.invalidate()
        statsTimer = nil
        guard let h = handle else { return }
        flux_host_stop(OpaquePointer(h))
        handle = nil
        currentFps = 0
        bitrateMbps = 0
    }

    private func startStatsPolling() {
        var lastFrames: UInt64 = 0
        var lastBytes: UInt64 = 0
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let h = self.handle else { return }
            let frames = flux_host_frames_sent(UnsafePointer(h))
            let bytes = flux_host_bytes_sent(UnsafePointer(h))
            let dFrames = frames - lastFrames
            let dBytes = bytes - lastBytes
            Task { @MainActor in
                self.currentFps = Int(dFrames)
                self.bitrateMbps = Double(dBytes) * 8.0 / 1_000_000.0
            }
            lastFrames = frames
            lastBytes = bytes
        }
    }
}
```

### `Host/PermissionChecker.swift`

```swift
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
```

---

## Step 4: Update `project.yml`

Add linker flags and bridging header to the OpenBench Host target:

```yaml
OpenBench Host:
    type: application
    platform: macOS
    sources:
      - Host
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: com.openbench.host
      GENERATE_INFOPLIST_FILE: YES
      MARKETING_VERSION: "1.0.0"
      CURRENT_PROJECT_VERSION: "1"
      INFOPLIST_KEY_CFBundleDisplayName: "OpenBench Host"
      INFOPLIST_KEY_LSUIElement: true
      INFOPLIST_KEY_NSLocalNetworkUsageDescription: "OpenBench Host needs local network access to advertise and serve connections."
      CODE_SIGN_STYLE: Automatic
      SWIFT_OBJC_BRIDGING_HEADER: Host/FluxHost-Bridging-Header.h
      OTHER_LDFLAGS:
        - -lflux_host_ffi
        - -lc++            # Rust's std links to libc++
        - -framework Security
        - -framework CoreGraphics
        - -framework ScreenCaptureKit
      LIBRARY_SEARCH_PATHS:
        - $(PROJECT_DIR)/../flux/target/release
```

---

## Step 5: Info.plist keys

These are already partially in `project.yml` via `INFOPLIST_KEY_*` but
you may need to add:

| Key | Value |
|-----|-------|
| `NSScreenCaptureUsageDescription` | "OpenBench Host captures your screen to stream to connected viewers." |
| `NSAccessibilityUsageDescription` | "OpenBench Host needs Accessibility to inject mouse and keyboard input from connected viewers." |
| `LSUIElement` | `true` (already set — hides from Dock) |
| `NSLocalNetworkUsageDescription` | (already set) |
| `NSBonjourServices` | `["_flux._udp."]` |

---

## Key decisions / constraints

1. **Don't rewrite the pipeline.** Extract `run_stream`,
   `stream_pixel_to_client`, and `encode_capture_loop` from
   `flux-host/src/main.rs` into shared functions that both the CLI
   and the FFI crate can call. Ideally move them into a
   `flux-host-core` library crate.

2. **One client at a time.** The current `encoder_active` AtomicBool
   pattern (line 1504) already enforces this — keep it.

3. **Tokio runtime lifetime.** Create the runtime in `flux_host_start`
   on a dedicated thread. The thread parks in `rt.block_on()`. When
   `flux_host_stop` sets the stop flag, the runtime shuts down and
   the thread joins.

4. **Stats callback vs polling.** The simplest approach is atomic
   counters (already used in `run_stream`). Swift polls them every
   second via Timer. No callback FFI complexity needed.

5. **Accessibility permission.** `HidInjector::new()` will fail
   silently if the app doesn't have Accessibility. Show a prompt
   on first launch via `AXIsProcessTrustedWithOptions`.

6. **Auto-start on login.** Optional future enhancement via
   `SMAppService.mainApp.register()` (macOS 13+).

---

## Testing checklist

- [ ] `cargo build --release -p flux-host-ffi` succeeds
- [ ] `xcodegen` regenerates the Xcode project with Host target
- [ ] OpenBench Host builds and shows a menu bar icon
- [ ] Toggling "Stream" starts the capture pipeline
- [ ] FPS and bitrate update in the menu bar popover
- [ ] iPad viewer discovers the host via Bonjour and connects
- [ ] Mouse/keyboard input from the viewer works (Accessibility granted)
- [ ] Toggling "Stream" off stops cleanly (no zombie threads)
- [ ] Quitting the app stops the pipeline and removes the menu bar icon
- [ ] Screen Recording permission prompt appears on first launch

---

## Reference files

| What | Where |
|------|-------|
| Streaming pipeline | `flux/crates/flux-host/src/main.rs:1393-1855` |
| Bonjour advertiser | `flux/crates/flux-transport/src/discovery.rs` |
| HID injector | `flux/crates/flux-input/src/hid.rs` |
| Stylus injector | `flux/crates/flux-input/src/host.rs` |
| Capture + encode | `flux/crates/flux-capture/`, `flux/crates/flux-codec/` |
| XcodeGen spec | `openbench-app/project.yml` (OpenBench Host target) |
| Existing FFI pattern | `flux/crates/flux-core-ffi/` (pen client FFI) |
