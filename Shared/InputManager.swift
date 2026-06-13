// InputManager.swift — Unified input capture and forwarding.
//
// Captures touch, trackpad, keyboard, and Apple Pencil events and
// translates them into flux protocol messages that the host understands.
//
// Two send paths:
//   1. HID input (mouse, keyboard, scroll, text, clipboard, paste
//      shortcut) → JSON-encoded ControlMessage over a QUIC stream
//      (or WebSocket fallback). These reuse the same message types
//      the web viewer sends.
//   2. Stylus input (Apple Pencil with pressure + tilt) → binary
//      FluxStylusSample over QUIC datagram via flux-core-ffi's
//      flux_dual_client_send_pen. 240 Hz from CADisplayLink.
//
// Platform-specific gesture recognizers live in iOS/ and macOS/
// directories; this file contains the shared protocol + send logic.

import Foundation
import Combine

// MARK: - Protocol message types (matching flux-protocol / ob-protocol)

/// JSON-serializable control messages matching the Rust ControlMessage
/// enum's externally-tagged serde form: `{"VariantName": { fields }}`.
/// Sent over the control QUIC stream.
public enum ControlMessage {
    case mouseMove(x: Int32, y: Int32, absolute: Bool)
    case mouseButton(button: UInt8, pressed: Bool)
    case mouseScroll(dx: Double, dy: Double)
    case keyEvent(key: String, modifiers: UInt16, pressed: Bool)
    case textInput(text: String)
    case clipboardSync(text: String)
    case executePasteShortcut
    case setActiveDisplay(displayId: UInt32?)
    case ping(nonce: UInt64)
    case pong(nonce: UInt64)
    /// Ask the host to encode the next frame as a keyframe (loss
    /// recovery — sent when the reassembler discards an incomplete
    /// frame). The host rate-limits compliance.
    case requestKeyframe
    /// Periodic receiver-side quality report; feeds the host's AIMD
    /// bitrate controller.
    case qualityFeedback(rttMs: UInt32, lossPct: Float, bandwidthKbps: UInt32)
    /// Viewer-driven stream quality settings. nil fields are left
    /// unchanged on the host. Bitrate applies live; fps/maxDimension
    /// restart the host capture pipeline (brief interruption).
    /// maxDimension 0 = native resolution.
    case setStreamSettings(fps: UInt32?, bitrateKbps: UInt32?, maxDimension: UInt32?)
    /// Ask the host to capture a small JPEG snapshot of every display
    /// and send them back as DisplayThumbnailChunk messages (populates
    /// the display sidebar). The host rate-limits compliance.
    case requestDisplayThumbnails
    /// Host → viewer per-frame timing breakdown (host-monotonic µs),
    /// emitted by flux-stream only when env FLUX_FRAME_TIMING is set.
    /// `captureUs` matches the frame's capture timestamp_us (the same
    /// value carried in the video packet header / ReassembledFrame), so
    /// the viewer can correlate a displayed frame back to where the host
    /// spent its time: PD = encodeDoneUs - captureUs, host queue =
    /// sentUs - encodeDoneUs.
    case frameTiming(frameId: UInt64, captureUs: UInt64, encodeDoneUs: UInt64, sentUs: UInt64)

    /// Encode to the serde externally-tagged JSON form.
    public func toJSON() -> Data? {
        let dict: [String: Any]
        switch self {
        case .mouseMove(let x, let y, let abs):
            dict = ["MouseMove": ["x": x, "y": y, "absolute": abs]]
        case .mouseButton(let button, let pressed):
            dict = ["MouseButton": ["button": button, "pressed": pressed]]
        case .mouseScroll(let dx, let dy):
            dict = ["MouseScroll": ["dx": dx, "dy": dy]]
        case .keyEvent(let key, let mods, let pressed):
            dict = ["KeyEvent": ["key": key, "modifiers": mods, "pressed": pressed]]
        case .textInput(let text):
            dict = ["TextInput": ["text": text]]
        case .clipboardSync(let text):
            dict = ["ClipboardSync": ["content": ["Text": text]]]
        case .executePasteShortcut:
            // Unit variant in serde = bare string
            return "\"ExecutePasteShortcut\"".data(using: .utf8)
        case .setActiveDisplay(let id):
            if let id = id {
                dict = ["SetActiveDisplay": ["display_id": id]]
            } else {
                dict = ["SetActiveDisplay": ["display_id": NSNull()]]
            }
        case .ping(let nonce):
            dict = ["Ping": ["nonce": nonce]]
        case .pong(let nonce):
            dict = ["Pong": ["nonce": nonce]]
        case .requestKeyframe:
            // Unit variant in serde = bare string
            return "\"RequestKeyframe\"".data(using: .utf8)
        case .requestDisplayThumbnails:
            // Unit variant in serde = bare string
            return "\"RequestDisplayThumbnails\"".data(using: .utf8)
        case .qualityFeedback(let rttMs, let lossPct, let bandwidthKbps):
            dict = ["QualityFeedback": [
                "rtt_ms": rttMs,
                "loss_pct": lossPct,
                "bandwidth_kbps": bandwidthKbps,
            ]]
        case .setStreamSettings(let fps, let bitrateKbps, let maxDimension):
            var fields: [String: Any] = [:]
            if let fps { fields["fps"] = fps }
            if let bitrateKbps { fields["bitrate_kbps"] = bitrateKbps }
            if let maxDimension { fields["max_dimension"] = maxDimension }
            dict = ["SetStreamSettings": fields]
        case .frameTiming(let frameId, let captureUs, let encodeDoneUs, let sentUs):
            // Host → viewer only; the viewer never sends this, but the
            // switch must stay exhaustive. Encode the symmetric form.
            dict = ["FrameTiming": [
                "frame_id": frameId,
                "capture_us": captureUs,
                "encode_done_us": encodeDoneUs,
                "sent_us": sentUs,
            ]]
        }
        return try? JSONSerialization.data(withJSONObject: dict)
    }

    /// Parse a serde externally-tagged JSON message.
    public static func fromJSON(_ data: Data) -> ControlMessage? {
        // Unit variant check
        if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           str == "\"ExecutePasteShortcut\"" {
            return .executePasteShortcut
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let (key, value) = obj.first else { return nil }
        guard let fields = value as? [String: Any] else { return nil }

        switch key {
        case "Ping":
            guard let nonce = fields["nonce"] as? UInt64 else { return nil }
            return .ping(nonce: nonce)
        case "Pong":
            guard let nonce = fields["nonce"] as? UInt64 else { return nil }
            return .pong(nonce: nonce)
        case "Welcome":
            // Handled separately by StreamSession
            return nil
        case "ClipboardSync":
            if let content = fields["content"] as? [String: Any],
               let text = content["Text"] as? String {
                return .clipboardSync(text: text)
            }
            return nil
        case "FrameTiming":
            // Host → viewer timing breakdown. JSONSerialization decodes
            // these as NSNumber; `as? UInt64` succeeds for integral
            // values in range (microsecond timestamps need the full u64).
            guard let frameId      = fields["frame_id"]       as? UInt64,
                  let captureUs    = fields["capture_us"]     as? UInt64,
                  let encodeDoneUs = fields["encode_done_us"] as? UInt64,
                  let sentUs       = fields["sent_us"]        as? UInt64 else { return nil }
            return .frameTiming(frameId: frameId, captureUs: captureUs,
                                encodeDoneUs: encodeDoneUs, sentUs: sentUs)
        default:
            return nil
        }
    }
}

// MARK: - Input manager

/// Manages input capture state and sends messages to the host.
/// Platform-specific subclasses (iOS TouchInputManager, macOS
/// KeyboardInputManager) call these methods.
public final class InputManager: ObservableObject {
    /// Callback to send a control message to the host.
    public var sendControl: ((ControlMessage) -> Void)?

    /// Callback to send a stylus sample via flux-core-ffi.
    /// Set by the StreamSession when the pen connection is available.
    public var sendStylus: ((StylusSampleData) -> Void)?

    @Published public var isKeyboardActive = false

    public init() {}

    // MARK: - Mouse / trackpad

    public func mouseMove(x: Int32, y: Int32) {
        sendControl?(.mouseMove(x: x, y: y, absolute: true))
    }

    /// Buttons we believe are currently held on the host.
    private var buttonsDown = Set<UInt8>()

    public func mouseButton(_ button: UInt8, pressed: Bool) {
        if pressed {
            // Self-heal a lost release: if we think this button is
            // still down (our previous release datagram may have been
            // lost — control rides unreliable QUIC datagrams), release
            // it before pressing again so the host can't get stuck in
            // drag mode.
            if buttonsDown.contains(button) {
                sendControl?(.mouseButton(button: button, pressed: false))
            }
            buttonsDown.insert(button)
            sendControl?(.mouseButton(button: button, pressed: true))
        } else {
            buttonsDown.remove(button)
            // Releases are idempotent on the host (releasing a released
            // button is a no-op), so send redundantly — a single lost
            // release datagram is exactly the "window sticks to the
            // cursor" bug.
            sendControl?(.mouseButton(button: button, pressed: false))
            for delay in [0.05, 0.15] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    // Skip if the button was pressed again in the
                    // meantime — a late redundant release would end the
                    // user's new drag.
                    guard let self, !self.buttonsDown.contains(button) else { return }
                    self.sendControl?(.mouseButton(button: button, pressed: false))
                }
            }
        }
    }

    public func scroll(dx: Double, dy: Double) {
        sendControl?(.mouseScroll(dx: dx, dy: dy))
    }

    /// One-shot named host action (Mission Control, Launchpad,
    /// AppSwitch). Rides the KeyEvent message; the host triggers on
    /// press and ignores the release.
    public func tapHostAction(_ name: String) {
        sendControl?(.keyEvent(key: name, modifiers: 0, pressed: true))
        sendControl?(.keyEvent(key: name, modifiers: 0, pressed: false))
    }

    // MARK: - Keyboard

    public func keyDown(_ key: String) {
        sendControl?(.keyEvent(key: key, modifiers: 0, pressed: true))
    }

    public func keyUp(_ key: String) {
        sendControl?(.keyEvent(key: key, modifiers: 0, pressed: false))
    }

    public func textInput(_ text: String) {
        sendControl?(.textInput(text: text))
    }

    // MARK: - Clipboard

    public func syncClipboard(_ text: String) {
        sendControl?(.clipboardSync(text: text))
    }

    public func pasteShortcut() {
        sendControl?(.executePasteShortcut)
    }

    // MARK: - Display switching

    public func setActiveDisplay(_ displayId: UInt32?) {
        sendControl?(.setActiveDisplay(displayId: displayId))
    }
}

// MARK: - Stylus sample data

/// Platform-agnostic stylus sample, mapped to FluxStylusSample
/// when sent via the C ABI.
public struct StylusSampleData {
    public var strokeId: UInt64
    public var seq: UInt32
    public var phase: UInt8    // 1=Begin, 2=Move, 3=End, 4=Cancel
    public var x: Float
    public var y: Float
    public var pressure: Float
    public var tiltX: Float
    public var tiltY: Float
    public var predicted: Bool
    public var timestampUs: UInt64

    /// Encode to flux-protocol's StylusSample wire format (bincode
    /// fixed-shape, little-endian, 45 bytes). Verified byte-for-byte
    /// against the Rust encoder. Note the phase rides as a u32
    /// bincode *variant index* (Begin=0 … Cancel=3), not the 1-based
    /// enum value used in this struct.
    public func encodeWire() -> Data {
        var d = Data(capacity: 45)
        func le<T: FixedWidthInteger>(_ v: T) {
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        func f32(_ v: Float) { le(v.bitPattern) }
        le(strokeId)
        le(seq)
        le(UInt32(max(1, phase)) - 1)
        f32(x); f32(y); f32(pressure); f32(tiltX); f32(tiltY)
        d.append(predicted ? 1 : 0)
        le(timestampUs)
        return d
    }
}
