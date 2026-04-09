# OpenBench App

Native cross-platform viewers and host app for [OpenBench](https://github.com/joshuacsg/openbench), built on the [flux](https://github.com/joshuacsg/flux) streaming engine.

## Targets

| Target | Platform | What it does |
|---|---|---|
| **OpenBench Viewer** | iOS / iPadOS | Remote desktop viewer with Apple Pencil, touch, and hardware keyboard support |
| **OpenBench Viewer** | macOS | Remote desktop viewer with trackpad and keyboard |
| **OpenBench Host** | macOS | Menu bar app that runs the flux streaming server (capture → HEVC encode → QUIC) |

## Architecture

```
┌─────────────────┐     QUIC (pixel datagrams)    ┌──────────────────────┐
│  OpenBench Host │ ─────────────────────────────→ │  OpenBench Viewer    │
│  (macOS menu    │     QUIC (pen datagrams)       │  (iOS / iPadOS /     │
│   bar app)      │ ←───────────────────────────── │   macOS)             │
│                 │     Bonjour (_flux._udp.)       │                      │
│  flux-host      │ ←──── NWBrowser discovery ──── │  VTDecompression     │
│  stream subprocess                               │  + CAMetalLayer      │
└─────────────────┘                                └──────────────────────┘
```

All transport, encoding, and protocol logic lives in the **flux** engine repo. This repo contains only:
- SwiftUI views and platform-specific input handling
- VTDecompressionSession HEVC decoder (native, no FFI)
- RFC-0008 frame reassembler (Swift port of flux-protocol)
- NWBrowser Bonjour service discovery
- Menu bar host daemon wrapper

## Prerequisites

```bash
# Install Rust iOS targets
rustup target add aarch64-apple-ios aarch64-apple-ios-sim

# Build FluxCore.xcframework from the sibling flux repo
./Scripts/build-xcframework.sh
```

## Build

Open `OpenBench.xcodeproj` in Xcode. Select the target (Viewer iOS / Viewer macOS / Host macOS) and build.

## Repo layout

```
Shared/          SwiftUI views + networking shared across all Apple targets
iOS/             iOS/iPadOS-specific (touch, Pencil, soft keyboard)
macOS/           macOS viewer-specific (keyboard, trackpad)
Host/            macOS menu bar host app (subprocess management)
Scripts/         Build scripts (xcframework, etc.)
Android/         Future: Kotlin + JNI
Linux/           Future: Rust/GTK or Flutter
```

## License

MIT
