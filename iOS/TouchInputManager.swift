// TouchInputManager.swift — iOS/iPadOS input capture.
//
// Translates UIKit touch, pencil, and keyboard events into InputManager
// calls. Attached to the MetalVideoView via gesture recognizers.
//
// Input mapping:
//   * Single finger drag → MouseMove (absolute coords)
//   * Single finger tap → MouseButton left click
//   * Trackpad hover → MouseMove (no click)
//   * Trackpad click / drag → MouseButton left + MouseMove
//   * Trackpad two-finger scroll → MouseScroll
//   * Two-finger tap → right click (MouseButton 1)
//   * Two-finger pinch → zoom (handled by viewport, not forwarded)
//   * Apple Pencil → StylusSampleData (pressure, tilt, phase)
//   * Hardware keyboard → keyDown/keyUp via UIKey
//   * Software keyboard → textInput via UITextInput protocol

import UIKit

/// A transparent overlay view that captures all touch and keyboard
/// input and forwards it to an InputManager. Sits on top of the
/// Metal video view.
public final class InputCaptureView: UIView, UIKeyInput, UIPointerInteractionDelegate {

    public weak var inputManager: InputManager?

    /// The video canvas dimensions (from the host's Welcome layout).
    /// Used to map UIKit points → canvas pixel coordinates.
    public var canvasSize: CGSize = .zero

    // Track active pencil stroke for stroke_id assignment.
    private var currentStrokeId: UInt64 = 0
    private var sampleSeq: UInt32 = 0

    // Track whether the left mouse button is held (for trackpad click-drag).
    private var pointerButtonDown = false

    // Two-finger direct touch scroll tracking.
    private var directScrollActive = false
    private var directScrollLastMidpoint: CGPoint?

    /// Callback invoked with the current pointer position in view
    /// coordinates whenever the trackpad/mouse moves. Used by the
    /// cursor overlay to render a local software cursor.
    /// Pass nil to hide the cursor (e.g. when direct touch begins).
    public var onPointerMoved: ((CGPoint?) -> Void)?

    /// When set to true, becomes first responder to show the soft
    /// keyboard. When false, resigns to hide it.
    public var showKeyboard: Bool = false {
        didSet {
            guard showKeyboard != oldValue else { return }
            if showKeyboard {
                becomeFirstResponder()
            } else {
                resignFirstResponder()
            }
        }
    }

    // MARK: - Setup

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true

        // Hide the system pointer when hovering over this view.
        addInteraction(UIPointerInteraction(delegate: self))

        // Trackpad scroll via pan gesture (two-finger scroll).
        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        scrollPan.allowedScrollTypesMask = .all
        scrollPan.minimumNumberOfTouches = 0
        scrollPan.maximumNumberOfTouches = 0 // only indirect (trackpad) scrolls
        addGestureRecognizer(scrollPan)

        // Right-click via two-finger tap (standard iPadOS secondary click).
        let secondaryTap = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryTap(_:)))
        secondaryTap.numberOfTouchesRequired = 2
        addGestureRecognizer(secondaryTap)

        // Hover gesture for pointer movement without click.
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Make this view the first responder so it receives key events.
    public override var canBecomeFirstResponder: Bool { true }

    // MARK: - Touch → Mouse

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }

        if touch.type == .pencil {
            handlePencilBegan(touch)
            return
        }

        // Count all active direct (finger) touches on this view.
        let directTouches = event?.touches(for: self)?.filter { $0.type == .direct } ?? []

        if directTouches.count >= 2 {
            // Two-finger direct touch → scroll mode. Cancel any pending click.
            if !directScrollActive {
                inputManager?.mouseButton(0, pressed: false)
                directScrollActive = true
            }
            directScrollLastMidpoint = midpoint(of: directTouches)
            onPointerMoved?(nil)
            return
        }

        // Single finger or trackpad click → left click.
        let viewPt = touch.location(in: self)
        let pos = mapToCanvas(viewPt)
        inputManager?.mouseMove(x: Int32(pos.x), y: Int32(pos.y))
        inputManager?.mouseButton(0, pressed: true)
        if touch.type == .indirectPointer {
            pointerButtonDown = true
            onPointerMoved?(viewPt)
        } else {
            onPointerMoved?(nil)
        }
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }

        if touch.type == .pencil {
            handlePencilMoved(touch, event: event)
            return
        }

        let directTouches = event?.touches(for: self)?.filter { $0.type == .direct } ?? []

        // Two-finger direct touch → scroll via midpoint delta.
        if directScrollActive, directTouches.count >= 2 {
            let mid = midpoint(of: directTouches)
            if let last = directScrollLastMidpoint {
                let dx = mid.x - last.x
                let dy = mid.y - last.y
                inputManager?.scroll(dx: Double(dx) * 0.5, dy: Double(dy) * 0.5)
            }
            directScrollLastMidpoint = mid
            return
        }

        let viewPt = touch.location(in: self)
        let pos = mapToCanvas(viewPt)
        inputManager?.mouseMove(x: Int32(pos.x), y: Int32(pos.y))
        if touch.type == .indirectPointer { onPointerMoved?(viewPt) }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }

        if touch.type == .pencil {
            handlePencilEnded(touch)
            return
        }

        // Check remaining active direct touches.
        let remaining = event?.touches(for: self)?
            .filter { $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled } ?? []

        if directScrollActive {
            if remaining.count < 2 {
                directScrollActive = false
                directScrollLastMidpoint = nil
            }
            return
        }

        let viewPt = touch.location(in: self)
        let pos = mapToCanvas(viewPt)
        inputManager?.mouseMove(x: Int32(pos.x), y: Int32(pos.y))
        inputManager?.mouseButton(0, pressed: false)
        if touch.type == .indirectPointer { pointerButtonDown = false }
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        inputManager?.mouseButton(0, pressed: false)
        pointerButtonDown = false
        directScrollActive = false
        directScrollLastMidpoint = nil
    }

    /// Midpoint of a set of touches in view coordinates.
    private func midpoint(of touches: [UITouch]) -> CGPoint {
        var x: CGFloat = 0, y: CGFloat = 0
        for t in touches {
            let pt = t.location(in: self)
            x += pt.x; y += pt.y
        }
        let n = CGFloat(touches.count)
        return CGPoint(x: x / n, y: y / n)
    }

    // MARK: - Trackpad / mouse pointer

    /// Hide the system pointer when it hovers over this view so the
    /// remote desktop cursor is the only one visible.
    public func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        return UIPointerStyle.hidden()
    }

    /// Trackpad hover (pointer movement without click).
    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard gesture.state == .changed || gesture.state == .began else { return }
        let viewPt = gesture.location(in: self)
        let pos = mapToCanvas(viewPt)
        inputManager?.mouseMove(x: Int32(pos.x), y: Int32(pos.y))
        onPointerMoved?(viewPt)
    }

    /// Two-finger trackpad scroll → MouseScroll.
    @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        // Reset so we get deltas, not cumulative offset.
        gesture.setTranslation(.zero, in: self)
        inputManager?.scroll(dx: Double(translation.x) * 0.5, dy: Double(translation.y) * 0.5)
    }

    /// Two-finger tap → right click.
    @objc private func handleSecondaryTap(_ gesture: UITapGestureRecognizer) {
        let pos = mapToCanvas(gesture.location(in: self))
        inputManager?.mouseMove(x: Int32(pos.x), y: Int32(pos.y))
        inputManager?.mouseButton(1, pressed: true)  // right down
        inputManager?.mouseButton(1, pressed: false)  // right up
    }

    // MARK: - Apple Pencil → Stylus samples

    private func handlePencilBegan(_ touch: UITouch) {
        currentStrokeId += 1
        sampleSeq = 0
        sendStylusSample(touch, phase: 1) // Begin
    }

    private func handlePencilMoved(_ touch: UITouch, event: UIEvent?) {
        // Coalesced touches give us the full 240 Hz stream.
        if let coalesced = event?.coalescedTouches(for: touch) {
            for t in coalesced {
                sendStylusSample(t, phase: 2) // Move
            }
        } else {
            sendStylusSample(touch, phase: 2)
        }

        // Predicted touches for local rendering (not sent to host
        // for injection — the host filters predicted=true).
        if let predicted = event?.predictedTouches(for: touch) {
            for t in predicted {
                sendStylusSample(t, phase: 2, predicted: true)
            }
        }
    }

    private func handlePencilEnded(_ touch: UITouch) {
        sendStylusSample(touch, phase: 3) // End
    }

    private func sendStylusSample(_ touch: UITouch, phase: UInt8, predicted: Bool = false) {
        let pos = mapToCanvas(touch.preciseLocation(in: self))
        let sample = StylusSampleData(
            strokeId: currentStrokeId,
            seq: sampleSeq,
            phase: phase,
            x: Float(pos.x),
            y: Float(pos.y),
            pressure: Float(touch.force / max(touch.maximumPossibleForce, 0.001)),
            tiltX: Float(touch.altitudeAngle),
            tiltY: Float(touch.azimuthAngle(in: self)),
            predicted: predicted,
            timestampUs: UInt64(touch.timestamp * 1_000_000)
        )
        sampleSeq += 1
        inputManager?.sendStylus?(sample)
    }

    // MARK: - Hardware keyboard (via UIKeyInput)

    public var hasText: Bool { true }

    public func insertText(_ text: String) {
        // Single character from hardware keyboard → TextInput
        inputManager?.textInput(text)
    }

    public func deleteBackward() {
        inputManager?.keyDown("Backspace")
        inputManager?.keyUp("Backspace")
    }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let key = press.key {
                let name = uiKeyToName(key)
                if let name = name {
                    inputManager?.keyDown(name)
                }
            }
        }
        // Don't call super — we consume the events.
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let key = press.key {
                let name = uiKeyToName(key)
                if let name = name {
                    inputManager?.keyUp(name)
                }
            }
        }
    }

    // MARK: - Coordinate mapping

    /// Map UIKit view-local point → canvas pixel coordinate.
    /// Assumes the Metal layer fills the view with aspect-fit.
    private func mapToCanvas(_ point: CGPoint) -> CGPoint {
        guard canvasSize.width > 0, canvasSize.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return point
        }
        let viewAspect = bounds.width / bounds.height
        let canvasAspect = canvasSize.width / canvasSize.height

        let scale: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
        if canvasAspect > viewAspect {
            // Canvas wider than view → pillar-boxed (bars top/bottom)
            scale = bounds.width / canvasSize.width
            offsetX = 0
            offsetY = (bounds.height - canvasSize.height * scale) / 2
        } else {
            // Canvas taller → letter-boxed (bars left/right)
            scale = bounds.height / canvasSize.height
            offsetX = (bounds.width - canvasSize.width * scale) / 2
            offsetY = 0
        }
        return CGPoint(
            x: (point.x - offsetX) / scale,
            y: (point.y - offsetY) / scale
        )
    }

    // MARK: - UIKey → key name

    private func uiKeyToName(_ key: UIKey) -> String? {
        switch key.keyCode {
        case .keyboardReturnOrEnter: return "Enter"
        case .keyboardTab: return "Tab"
        case .keyboardDeleteOrBackspace: return "Backspace"
        case .keyboardDeleteForward: return "Delete"
        case .keyboardEscape: return "Escape"
        case .keyboardLeftArrow: return "ArrowLeft"
        case .keyboardRightArrow: return "ArrowRight"
        case .keyboardUpArrow: return "ArrowUp"
        case .keyboardDownArrow: return "ArrowDown"
        case .keyboardHome: return "Home"
        case .keyboardEnd: return "End"
        case .keyboardPageUp: return "PageUp"
        case .keyboardPageDown: return "PageDown"
        case .keyboardLeftShift, .keyboardRightShift: return "Shift"
        case .keyboardLeftControl, .keyboardRightControl: return "Control"
        case .keyboardLeftAlt, .keyboardRightAlt: return "Alt"
        case .keyboardLeftGUI, .keyboardRightGUI: return "Meta"
        case .keyboardF1: return "F1"
        case .keyboardF2: return "F2"
        case .keyboardF3: return "F3"
        case .keyboardF4: return "F4"
        case .keyboardF5: return "F5"
        case .keyboardF6: return "F6"
        case .keyboardF7: return "F7"
        case .keyboardF8: return "F8"
        case .keyboardF9: return "F9"
        case .keyboardF10: return "F10"
        case .keyboardF11: return "F11"
        case .keyboardF12: return "F12"
        case .keyboardSpacebar: return " "
        default:
            // For printable characters, use the character string.
            let chars = key.charactersIgnoringModifiers
            if chars.count == 1 { return chars }
            return nil
        }
    }
}
