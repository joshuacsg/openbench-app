// KeyboardInputManager.swift — macOS keyboard + trackpad input capture.
//
// Translates NSEvent keyboard and mouse events into InputManager
// calls. Attached to the Metal video NSView via event monitoring.

#if os(macOS)
import AppKit

/// An NSView overlay that captures keyboard and mouse events and
/// forwards them to an InputManager.
public final class MacInputCaptureView: NSView {

    public weak var inputManager: InputManager?
    public var canvasSize: CGSize = .zero

    public override var acceptsFirstResponder: Bool { true }

    // MARK: - Mouse

    public override func mouseMoved(with event: NSEvent) {
        let pos = mapToCanvas(convert(event.locationInWindow, from: nil))
        inputManager?.mouseMove(x: Int32(pos.x), y: Int32(pos.y))
    }

    public override func mouseDragged(with event: NSEvent) {
        let pos = mapToCanvas(convert(event.locationInWindow, from: nil))
        inputManager?.mouseMove(x: Int32(pos.x), y: Int32(pos.y))
    }

    public override func mouseDown(with event: NSEvent) {
        let pos = mapToCanvas(convert(event.locationInWindow, from: nil))
        inputManager?.mouseMove(x: Int32(pos.x), y: Int32(pos.y))
        inputManager?.mouseButton(0, pressed: true)
    }

    public override func mouseUp(with event: NSEvent) {
        inputManager?.mouseButton(0, pressed: false)
    }

    public override func rightMouseDown(with event: NSEvent) {
        inputManager?.mouseButton(1, pressed: true)
    }

    public override func rightMouseUp(with event: NSEvent) {
        inputManager?.mouseButton(1, pressed: false)
    }

    public override func scrollWheel(with event: NSEvent) {
        inputManager?.scroll(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
    }

    // MARK: - Keyboard

    public override func keyDown(with event: NSEvent) {
        if let name = nsKeyToName(event) {
            inputManager?.keyDown(name)
        } else if let chars = event.characters, !chars.isEmpty {
            inputManager?.textInput(chars)
        }
    }

    public override func keyUp(with event: NSEvent) {
        if let name = nsKeyToName(event) {
            inputManager?.keyUp(name)
        }
    }

    public override func flagsChanged(with event: NSEvent) {
        // Track modifier key press/release. NSEvent.modifierFlags
        // tells us the current state; we diff against previous.
        let flags = event.modifierFlags
        sendModifier("Shift", isPressed: flags.contains(.shift))
        sendModifier("Control", isPressed: flags.contains(.control))
        sendModifier("Alt", isPressed: flags.contains(.option))
        sendModifier("Meta", isPressed: flags.contains(.command))
    }

    private var activeModifiers: Set<String> = []
    private func sendModifier(_ name: String, isPressed: Bool) {
        if isPressed && !activeModifiers.contains(name) {
            activeModifiers.insert(name)
            inputManager?.keyDown(name)
        } else if !isPressed && activeModifiers.contains(name) {
            activeModifiers.remove(name)
            inputManager?.keyUp(name)
        }
    }

    // MARK: - Coordinate mapping

    private func mapToCanvas(_ point: CGPoint) -> CGPoint {
        guard canvasSize.width > 0, canvasSize.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return point
        }
        // NSView coordinates are flipped (origin bottom-left).
        let flipped = CGPoint(x: point.x, y: bounds.height - point.y)

        let viewAspect = bounds.width / bounds.height
        let canvasAspect = canvasSize.width / canvasSize.height
        let scale: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
        if canvasAspect > viewAspect {
            scale = bounds.width / canvasSize.width
            offsetX = 0
            offsetY = (bounds.height - canvasSize.height * scale) / 2
        } else {
            scale = bounds.height / canvasSize.height
            offsetX = (bounds.width - canvasSize.width * scale) / 2
            offsetY = 0
        }
        return CGPoint(
            x: (flipped.x - offsetX) / scale,
            y: (flipped.y - offsetY) / scale
        )
    }

    // MARK: - NSEvent → key name

    private func nsKeyToName(_ event: NSEvent) -> String? {
        switch event.keyCode {
        case 36: return "Enter"
        case 48: return "Tab"
        case 51: return "Backspace"
        case 53: return "Escape"
        case 117: return "Delete"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "PageUp"
        case 121: return "PageDown"
        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 49: return " " // spacebar
        default:
            // For single-character printable keys, return nil
            // so the caller uses event.characters → textInput instead.
            return nil
        }
    }
}
#endif
