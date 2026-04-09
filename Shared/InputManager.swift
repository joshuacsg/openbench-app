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

    public func mouseButton(_ button: UInt8, pressed: Bool) {
        sendControl?(.mouseButton(button: button, pressed: pressed))
    }

    public func scroll(dx: Double, dy: Double) {
        sendControl?(.mouseScroll(dx: dx, dy: dy))
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
}
