# Handoff: Stream Resolution & Bandwidth Optimizations

## Problem

The app currently streams **full native display resolution** over QUIC datagrams with a **fixed 10 Mbps HEVC bitrate**, regardless of network conditions, content type, or whether the client can even display that resolution. There are several optimization opportunities.

## Current Architecture

The streaming pipeline is:

```
Host capture → HEVC encode (flux-host CLI) → fragment into ~1100B datagrams → QUIC UDP
→ reassemble fragments → HEVC hardware decode (VTDecompressionSession) → Metal blit → CAMetalLayer
```

### Key Files

| File | Role |
|------|------|
| `Host/HostManager.swift` | Spawns `flux-host` subprocess with encoding params (lines 27-32, 65-74) |
| `Shared/StreamSession.swift` | QUIC client, datagram receive loop, control messages, ping/pong RTT |
| `Shared/FrameReassembler.swift` | Reassembles fragmented datagrams into complete HEVC access units |
| `Shared/VideoDecoder.swift` | VTDecompressionSession HEVC decode (Annex-B → CVPixelBuffer) |
| `Shared/MetalRenderer.swift` | Blits decoded CVPixelBuffer to CAMetalLayer via display link |

### Current Hardcoded Settings (`Host/HostManager.swift:27-32`)

```swift
private let pixelPort: UInt16 = 9000
private let penPort: UInt16 = 9001
private let fps: UInt32 = 60
private let bitrateKbps: UInt32 = 10_000   // 10 Mbps, always
private let keyframeInterval: UInt32 = 60
private let maxPayload: UInt32 = 1100       // bytes per datagram fragment
```

These are passed as CLI args to `flux-host stream` (lines 65-74):

```swift
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
```

### What the Client Already Handles

- **Arbitrary frame sizes**: `MetalRenderer.swift:95-98` dynamically updates `drawableSize` when frame resolution changes, so the client will render whatever resolution the host sends.
- **Canvas size inference**: `StreamSession.swift:122-127` infers canvas size from the first decoded frame if no Welcome message is received.
- **RTT measurement**: Ping/pong every 2 seconds (`StreamSession.swift:154-166`), RTT published as `rttMs`.
- **Frame loss tolerance**: `FrameReassembler.swift:82-86` evicts stale incomplete frames after 32 frame IDs.

### Wire Protocol Details

- **Datagram types**: `0x01` = video fragment, `0x02` = control JSON
- **Header**: 19 bytes — type(1) + sequence(4) + timestamp_us(8) + flags(2) + payload_len(4)
- **Sequence field**: high 16 bits = frame_id, low 16 bits = fragment_idx
- **Flags**: `0x01` = KEYFRAME, `0x10` = LAST_FRAGMENT
- **Control messages**: Bidirectional JSON over datagrams. Existing types: Welcome, ClipboardSync, Ping/Pong, MouseMove, KeyEvent, SetActiveDisplay, etc.

## Optimization Opportunities

### 1. Adaptive Bitrate (highest impact, moderate complexity)

**What**: Scale `bitrateKbps` based on network conditions instead of fixed 10 Mbps.

**How**: The client already measures RTT via ping/pong (`StreamSession.rttMs`). You could also track packet loss rate from `FrameReassembler` (incomplete frames that get evicted = lost fragments). Send a control message back to the host with a suggested bitrate, and have `flux-host` honor it.

**Approach**:
- Add a new control message type (e.g., `BitrateHint { bitrate_kbps: UInt32 }`) to `ControlMessage`
- Periodically compute a target bitrate from RTT + loss rate
- Send it via `sendControl()` — the host's `flux-host` binary would need to support this too
- Alternatively, if `flux-host` can't be modified, expose bitrate as a user-facing setting in SettingsView

**Note**: `flux-host` is an external Rust binary. Check if it supports runtime bitrate changes. If not, this optimization would require either modifying flux-host or restarting the subprocess with new args.

### 2. Resolution Scaling (highest bandwidth savings)

**What**: Downscale before encoding — e.g., stream 1080p for a 4K display when the client is on a constrained network or the client display is smaller than the host display.

**How**: This would be a `flux-host` CLI flag like `--scale 0.5` or `--max-width 1920`. The client already handles arbitrary resolutions (MetalRenderer resizes dynamically).

**Trade-off**: Reduces bandwidth ~4x (4K→1080p) but loses pixel-level sharpness for text. Could be adaptive — full res on LAN, downscaled on slower links.

### 3. Dynamic FPS (easy, meaningful savings)

**What**: Drop from 60 to 30 FPS when screen content is mostly static (text editing, reading).

**How**: `flux-host` could detect low frame-to-frame delta and skip captures. Or the client could send a `FpsHint` control message. The host already accepts `--fps` as a CLI arg.

### 4. Content-Adaptive Encoding

**What**: Lower bitrate for static/text content, higher for video playback or fast motion.

**How**: HEVC encoders support variable bitrate (VBR) modes. If `flux-host` uses constant bitrate (CBR) today, switching to VBR with a max cap would automatically use less bandwidth for simple frames.

### 5. Larger Datagram Payloads (small but free win)

**What**: Increase `maxPayload` from 1100 to ~1400 bytes.

**Why**: 1100 is very conservative. Standard Ethernet MTU is 1500; after QUIC/UDP/IP headers (~60-70 bytes), ~1400 bytes of payload is safe on most networks. This reduces the number of datagrams per frame (fewer headers = less overhead).

**How**: Change `maxPayload` in `HostManager.swift:32` from `1100` to `1350` or `1400`. Test on WiFi to verify no fragmentation issues.

### 6. Skip Duplicate Frames (easy, saves bandwidth on idle screens)

**What**: Don't send a frame if it's identical to the previous one.

**How**: This is a `flux-host` encoder optimization — compare capture buffers and skip encoding when the screen hasn't changed. The client naturally handles gaps (display link just re-presents the last frame).

## Suggested Implementation Order

1. **Larger datagram payload** — one-line change, no risk, immediate ~20% header overhead reduction
2. **Expose settings in SettingsView** — make fps/bitrate/maxPayload user-configurable instead of hardcoded (the comment on line 26 already anticipates this)
3. **Adaptive bitrate** — requires understanding if `flux-host` supports runtime config changes
4. **Resolution scaling** — requires `flux-host` support for capture scaling

## Important Constraints

- `flux-host` is an **external Rust binary** (not in this repo). The Swift app spawns it as a subprocess. Any encoder-side optimizations (adaptive bitrate, resolution scaling, frame skipping) require changes to that binary or its CLI interface.
- The Swift-side optimizations you can make independently are: exposing settings in UI, sending hint control messages, increasing `maxPayload`, and implementing client-side quality metrics (loss rate, jitter).
- The QUIC transport is **unreliable datagrams** (no retransmit). Lost fragments mean lost frames. This is by design for low latency, but it means bandwidth pressure directly translates to visual quality degradation.
- The client render path is already well-optimized (hardware decode, Metal blit, display-synced presentation). Optimization gains are primarily on the **encode and transport** side.
