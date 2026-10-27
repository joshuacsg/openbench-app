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
    public var canvasSize: CGSize = .zero {
        didSet {
            // A constrained surface centers its cursor inside the fitted
            // canvas; redo that once the canvas size is first known.
            guard constrainTrackpadToCanvas, oldValue == .zero, canvasSize != .zero else { return }
            trackpadCursorPlacedInBounds = false
            setNeedsLayout()
        }
    }

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

    /// Same events as `onPointerMoved`, but in canvas pixel coordinates.
    /// The external-monitor trackpad uses this to draw the cursor on a
    /// different screen than the one being touched.
    public var onCanvasPointerMoved: ((CGPoint?) -> Void)?

    /// Trackpad mode only: keep the tracked cursor inside the
    /// aspect-fitted canvas rect instead of the whole view. Set when
    /// this view is a bare trackpad surface (no video under it), where
    /// the letterbox area would map off the host display.
    public var constrainTrackpadToCanvas = false

    /// Second-screen link: another host display, arranged beside this
    /// view's canvas, that the trackpad cursor can travel onto (the
    /// external monitor while the iPad shows its own display). Both rects
    /// share one arrangement space; see DisplayArrangement.
    public struct TrackpadLink: Equatable {
        public var localRect: CGRect
        public var remoteRect: CGRect
        public var remoteCanvasSize: CGSize

        public init(localRect: CGRect, remoteRect: CGRect, remoteCanvasSize: CGSize) {
            self.localRect = localRect
            self.remoteRect = remoteRect
            self.remoteCanvasSize = remoteCanvasSize
        }
    }

    public var trackpadLink: TrackpadLink? {
        didSet {
            guard trackpadLink != oldValue, linkedCursor != nil else { return }
            // The link changed under a cursor on the linked display.
            returnFromLinkedDisplay()
        }
    }

    /// The cursor moved onto (true) or back off (false) the linked
    /// display. Called before any input meant for it is sent, so the
    /// owner can re-route the InputManager.
    public var onLinkedDisplayActive: ((Bool) -> Void)?
    /// Cursor on the linked display in its canvas pixels; nil = left it.
    public var onLinkedCursorMoved: ((CGPoint?) -> Void)?
    /// Cursor position in arrangement space while it is on the linked
    /// display; nil while it is on this view's canvas.
    private var linkedCursor: CGPoint?

    // MARK: - Viewport zoom/pan state

    /// Current zoom scale (1.0 = fit to view).
    public private(set) var viewportScale: CGFloat = 1.0
    /// Current pan offset in view coordinates.
    public private(set) var viewportOffset: CGPoint = .zero

    /// Callback when viewport transform changes (scale, offset).
    public var onViewportChanged: ((CGFloat, CGPoint) -> Void)?

    /// Set viewport from external source (e.g. minimap slider).
    public func setViewport(scale: CGFloat, offset: CGPoint) {
        viewportScale = scale
        viewportOffset = offset
        clampOffset()
    }

    // Pinch tracking
    private var pinchStartScale: CGFloat = 1.0
    private var pinchAnchorInView: CGPoint = .zero
    private var pinchStartOffset: CGPoint = .zero

    // Pan tracking (single-finger when zoomed)
    private var panStartOffset: CGPoint = .zero

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

    /// Input mode. `false` = touchscreen (the finger IS the cursor —
    /// absolute positioning). `true` = trackpad: the whole surface
    /// drives a relative cursor like a laptop trackpad — move, tap to
    /// click, tap-and-a-half to drag, two-finger scroll, two-finger
    /// right-click. The tracked cursor is authoritative; the host
    /// receives absolute moves to it so the two never drift.
    public var trackpadMode: Bool = false {
        didSet {
            guard trackpadMode != oldValue else { return }
            resetTrackpadGestures(sendCancellation: trackpadGestures && oldValue)
            if !trackpadMode { returnFromLinkedDisplay() }
            if trackpadMode {
                if !trackpadCursorInitialized {
                    trackpadCursor = CGPoint(x: bounds.midX, y: bounds.midY)
                    trackpadCursorInitialized = true
                }
                reportPointer(trackpadCursor)
            } else {
                reportPointer(nil)
            }
        }
    }

    public var trackpadGestures = false {
        didSet {
            guard trackpadGestures != oldValue else { return }
            if !trackpadGestures { inputManager?.cancelPendingTrackpadControls() }
            resetTrackpadGestures(sendCancellation: false)
        }
    }

    private var gestureClassifier = TrackpadGestureClassifier()
    private var multiFingerSequence = false
    private var secondaryTapRecognizer: UITapGestureRecognizer?
    private var rightClickWork: DispatchWorkItem?
    private var indirectScrollActive = false

    private var usesTrackpadGestures: Bool { trackpadMode && trackpadGestures }

    private func resetTrackpadGestures(sendCancellation: Bool) {
        if sendCancellation {
            emitTrackpadActions(gestureClassifier.cancel(at: ProcessInfo.processInfo.systemUptime, size: bounds.size))
            if indirectScrollActive { inputManager?.trackpadScroll(dx: 0, dy: 0, phase: .cancelled) }
        }
        rightClickWork?.cancel()
        rightClickWork = nil
        gestureClassifier = TrackpadGestureClassifier()
        multiFingerSequence = false
        indirectScrollActive = false
        secondaryTapRecognizer?.isEnabled = !usesTrackpadGestures
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
        secondaryTapRecognizer = secondaryTap

        // Hover gesture for pointer movement without click.
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)

        // Pinch-to-zoom and double-tap-to-zoom disabled — they clash
        // with cursor/scroll controls. Zoom will be driven from the
        // minimap (Phase 3) instead.
    }

    required init?(coder: NSCoder) { fatalError() }

    // Make this view the first responder so it receives key events.
    public override var canBecomeFirstResponder: Bool { true }

    // Tap-vs-drag disambiguation: suppress mouse moves until the touch
    // travels past this slop radius, so a tap with natural finger
    // jitter lands as a clean click instead of a 2-pixel drag (which
    // macOS happily interprets as window-move/text-select).
    private static let dragSlop: CGFloat = 8
    private var touchDownViewPoint: CGPoint?
    private var dragStarted = false

    // Trackpad mode state. The cursor lives where we last left it (not
    // under the finger); finger deltas move it, and we send the host an
    // absolute move to the tracked position.
    private var trackpadCursor: CGPoint = .zero
    private var trackpadCursorInitialized = false
    private var trackpadCursorPlacedInBounds = false
    private var trackpadLastPoint: CGPoint?
    private var trackpadGestureOrigin: CGPoint?
    private var trackpadTouchMoved = false
    private var trackpadDragging = false
    private var dragLockArmed = false
    private var lastTapEndTime: TimeInterval = 0
    private static let trackpadSensitivity: CGFloat = 1.6
    private static let trackpadTapSlop: CGFloat = 6
    private static let tapAndAHalfWindow: TimeInterval = 0.35

    // MARK: - Touch → Mouse

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }

        if touch.type == .pencil {
            // Pencil input lands where it touches, on this display.
            returnFromLinkedDisplay()
            handlePencilBegan(touch)
            return
        }

        if handleTrackpadGestures(touches, event: event) { return }

        // Count all active direct (finger) touches on this view.
        let directTouches = event?.touches(for: self)?.filter { $0.type == .direct } ?? []

        if directTouches.count >= 2 {
            // Two-finger direct touch → scroll mode. Cancel any pending click.
            if !directScrollActive {
                inputManager?.mouseButton(0, pressed: false)
                directScrollActive = true
            }
            directScrollLastMidpoint = midpoint(of: directTouches)
            reportPointer(nil)
            return
        }

        // Trackpad mode: relative cursor, click decided on touch-up.
        if trackpadMode, touch.type == .direct {
            trackpadTouchBegan(touch)
            return
        }
        // Absolute input (touchscreen, mouse) lands on this display.
        returnFromLinkedDisplay()

        // Single finger or trackpad click → left click.
        let viewPt = touch.location(in: self)
        let pos = mapToCanvas(viewPt)
        touchDownViewPoint = viewPt
        dragStarted = false
        inputManager?.mouseMove(x: Int32(pos.x), y: Int32(pos.y))
        inputManager?.mouseButton(0, pressed: true)
        if touch.type == .indirectPointer {
            pointerButtonDown = true
            reportPointer(viewPt)
        } else {
            reportPointer(nil)
        }
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }

        if touch.type == .pencil {
            handlePencilMoved(touch, event: event)
            return
        }

        if handleTrackpadGestures(touches, event: event) { return }

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

        if trackpadMode, touch.type == .direct {
            trackpadTouchMovedHandler(touch)
            return
        }

        let viewPt = touch.location(in: self)
        if !dragStarted {
            guard let start = touchDownViewPoint,
                  hypot(viewPt.x - start.x, viewPt.y - start.y) >= Self.dragSlop else {
                return // still within tap jitter — hold position
            }
            dragStarted = true
        }
        let pos = mapToCanvas(viewPt)
        inputManager?.mouseMove(x: Int32(pos.x), y: Int32(pos.y))
        if touch.type == .indirectPointer { reportPointer(viewPt) }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }

        if touch.type == .pencil {
            handlePencilEnded(touch)
            return
        }

        if handleTrackpadGestures(touches, event: event) { return }

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

        if trackpadMode, touch.type == .direct {
            trackpadTouchEnded(touch)
            return
        }

        if dragStarted {
            let viewPt = touch.location(in: self)
            let pos = mapToCanvas(viewPt)
            inputManager?.mouseMove(x: Int32(pos.x), y: Int32(pos.y))
        }
        touchDownViewPoint = nil
        dragStarted = false
        inputManager?.mouseButton(0, pressed: false)
        if touch.type == .indirectPointer { pointerButtonDown = false }
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if usesTrackpadGestures, touches.contains(where: { $0.type == .direct }) {
            emitTrackpadActions(gestureClassifier.cancel(at: touches.first?.timestamp ?? 0, size: bounds.size))
            rightClickWork?.cancel()
            // UIKit cancels the sequence; never turn a remaining finger
            // into a new single-finger tap or resume a previous drag.
            multiFingerSequence = event?.touches(for: self)?.contains(where: {
                $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled
            }) ?? false
            trackpadDragging = false
            dragLockArmed = false
            trackpadLastPoint = nil
            lastTapEndTime = 0
        }
        inputManager?.mouseButton(0, pressed: false)
        pointerButtonDown = false
        directScrollActive = false
        directScrollLastMidpoint = nil
    }

    // MARK: - Trackpad mode (relative cursor)

    /// Returns true while a multi-finger sequence owns the touch stream,
    /// including its last remaining finger (which must not move/click).
    private func handleTrackpadGestures(_ touches: Set<UITouch>, event: UIEvent?) -> Bool {
        guard usesTrackpadGestures else { return false }
        guard touches.contains(where: { $0.type == .direct }) else {
            return multiFingerSequence || indirectScrollActive
        }
        let all = event?.touches(for: self)?.filter { $0.type == .direct } ?? Array(touches)
        let active = all.filter { $0.phase != .ended && $0.phase != .cancelled }
        let lifted = touches.filter { $0.type == .direct && ($0.phase == .ended || $0.phase == .cancelled) }
        let time = touches.map(\.timestamp).max() ?? 0
        func snapshot(_ touch: UITouch) -> TrackpadGestureClassifier.Touch {
            .init(id: ObjectIdentifier(touch).hashValue, point: touch.location(in: self))
        }
        if (active.count >= 2 || indirectScrollActive) && !multiFingerSequence {
            multiFingerSequence = true
            inputManager?.mouseButton(0, pressed: false)
            trackpadDragging = false
            dragLockArmed = false
            trackpadLastPoint = nil
            trackpadGestureOrigin = nil
            lastTapEndTime = 0
        }
        emitTrackpadActions(gestureClassifier.update(active.map(snapshot), lifted: lifted.map(snapshot),
                                                     at: time, size: bounds.size))
        rightClickWork?.cancel()
        if let deadline = gestureClassifier.rightClickDeadline {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.usesTrackpadGestures else { return }
                self.emitTrackpadActions(self.gestureClassifier.flush(at: deadline))
            }
            rightClickWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - time), execute: work)
        }
        let handled = multiFingerSequence
        if active.isEmpty { multiFingerSequence = false }
        return handled
    }

    private func emitTrackpadActions(_ actions: [TrackpadGestureClassifier.Action]) {
        for action in actions {
            switch action {
            case .scroll(let phase, let dx, let dy, let vx, let vy):
                inputManager?.trackpadScroll(dx: dx, dy: dy, phase: phase, vx: vx, vy: vy)
            case .gesture(let kind, let phase, let delta, let velocity):
                inputManager?.trackpadGesture(kind, phase: phase, delta: delta, velocity: velocity)
            case .rightClick:
                inputManager?.mouseButton(1, pressed: true)
                inputManager?.mouseButton(1, pressed: false)
            case .lookUp:
                inputManager?.keyDown("d", modifiers: 10)
                inputManager?.keyUp("d", modifiers: 10)
            }
        }
    }

    private func trackpadTouchBegan(_ touch: UITouch) {
        if !trackpadCursorInitialized {
            trackpadCursor = CGPoint(x: bounds.midX, y: bounds.midY)
            trackpadCursorInitialized = true
        }
        let pt = touch.location(in: self)
        trackpadLastPoint = pt
        trackpadGestureOrigin = pt
        trackpadTouchMoved = false
        // Tap-and-a-half: a touch starting just after a tap becomes a
        // drag (button held while moving), like a Mac trackpad.
        dragLockArmed = (touch.timestamp - lastTapEndTime) < Self.tapAndAHalfWindow
        reportPointer(trackpadCursor)
    }

    private func trackpadTouchMovedHandler(_ touch: UITouch) {
        let pt = touch.location(in: self)
        guard let last = trackpadLastPoint else { trackpadLastPoint = pt; return }
        let dx = pt.x - last.x
        let dy = pt.y - last.y
        trackpadLastPoint = pt

        // Once the finger leaves a small slop radius it's a move (not a
        // tap). If a drag was armed, press the button now to start it.
        if !trackpadTouchMoved, let origin = trackpadGestureOrigin,
           hypot(pt.x - origin.x, pt.y - origin.y) >= Self.trackpadTapSlop {
            trackpadTouchMoved = true
            if dragLockArmed {
                trackpadDragging = true
                let pos = cursorCanvasPoint
                inputManager?.mouseMove(x: Int32(pos.x), y: Int32(pos.y))
                inputManager?.mouseButton(0, pressed: true)
            }
        }
        guard trackpadTouchMoved else { return }

        let step = CGPoint(x: dx * Self.trackpadSensitivity, y: dy * Self.trackpadSensitivity)
        if let link = trackpadLink, moveAcrossLink(step, link) { return }

        let range = trackpadCursorBounds
        trackpadCursor.x = min(max(trackpadCursor.x + dx * Self.trackpadSensitivity, range.minX), range.maxX)
        trackpadCursor.y = min(max(trackpadCursor.y + dy * Self.trackpadSensitivity, range.minY), range.maxY)
        let pos = mapToCanvas(trackpadCursor)
        inputManager?.mouseMove(x: Int32(pos.x), y: Int32(pos.y))
        reportPointer(trackpadCursor)
    }

    private func trackpadTouchEnded(_ touch: UITouch) {
        if trackpadDragging {
            inputManager?.mouseButton(0, pressed: false)
            trackpadDragging = false
        } else if !trackpadTouchMoved {
            // A tap → left click at the cursor's current position.
            let pos = cursorCanvasPoint
            inputManager?.mouseMove(x: Int32(pos.x), y: Int32(pos.y))
            inputManager?.mouseButton(0, pressed: true)
            inputManager?.mouseButton(0, pressed: false)
            lastTapEndTime = touch.timestamp
        }
        dragLockArmed = false
        trackpadLastPoint = nil
        trackpadGestureOrigin = nil
        trackpadTouchMoved = false
    }

    /// Fan a pointer position (view coordinates, nil = hide) out to the
    /// view-space and canvas-space observers.
    private func reportPointer(_ viewPoint: CGPoint?) {
        onPointerMoved?(viewPoint)
        onCanvasPointerMoved?(viewPoint.map(mapToCanvas))
    }

    /// The tracked cursor in the canvas pixels of whichever display it
    /// is on (input is routed to that display's session).
    private var cursorCanvasPoint: CGPoint {
        if let linkedCursor, let link = trackpadLink {
            return remoteCanvasPoint(linkedCursor, link)
        }
        return mapToCanvas(trackpadCursor)
    }

    /// Arrangement units per canvas pixel of this view's canvas.
    private func arrangementScale(_ link: TrackpadLink) -> CGFloat {
        canvasSize.width > 0 ? link.localRect.width / canvasSize.width : 1
    }

    private func remoteCanvasPoint(_ p: CGPoint, _ link: TrackpadLink) -> CGPoint {
        CGPoint(
            x: (p.x - link.remoteRect.minX) * link.remoteCanvasSize.width / link.remoteRect.width,
            y: (p.y - link.remoteRect.minY) * link.remoteCanvasSize.height / link.remoteRect.height
        )
    }

    /// Move the cursor by `step` (view points) across the link. Returns
    /// false when the move stays on this view's canvas, for the regular
    /// clamped path. A held button never crosses: the drag would be
    /// split across two host connections.
    private func moveAcrossLink(_ step: CGPoint, _ link: TrackpadLink) -> Bool {
        guard canvasSize.width > 0, canvasSize.height > 0,
              link.localRect.width > 0, link.remoteRect.width > 0, link.remoteRect.height > 0 else { return false }
        let scale = arrangementScale(link)

        if let current = linkedCursor {
            // Finger travel keeps the feel it has on this canvas.
            let perPoint = scale / max(viewToCanvasScale, 0.0001)
            var p = CGPoint(x: current.x + step.x * perPoint, y: current.y + step.y * perPoint)
            if !trackpadDragging, !link.remoteRect.contains(p), link.localRect.contains(p) {
                let canvasPt = CGPoint(x: (p.x - link.localRect.minX) / scale,
                                       y: (p.y - link.localRect.minY) / scale)
                let viewPt = mapFromCanvas(canvasPt)
                let range = trackpadCursorBounds
                trackpadCursor = CGPoint(x: min(max(viewPt.x, range.minX), range.maxX),
                                         y: min(max(viewPt.y, range.minY), range.maxY))
                returnFromLinkedDisplay()
                let pos = mapToCanvas(trackpadCursor)
                inputManager?.mouseMove(x: Int32(pos.x), y: Int32(pos.y))
                reportPointer(trackpadCursor)
                return true
            }
            let r = link.remoteRect
            p.x = min(max(p.x, r.minX), r.maxX - 0.01)
            p.y = min(max(p.y, r.minY), r.maxY - 0.01)
            linkedCursor = p
            sendLinkedCursor(link)
            return true
        }

        guard !trackpadDragging else { return false }
        let candidate = mapToCanvas(CGPoint(x: trackpadCursor.x + step.x, y: trackpadCursor.y + step.y))
        // Closed bounds: a cursor resting on the far edge (where the
        // clamp leaves it) must cross only by moving past it.
        let leftCanvas = candidate.x < 0 || candidate.y < 0
            || candidate.x > canvasSize.width || candidate.y > canvasSize.height
        let p = CGPoint(x: link.localRect.minX + candidate.x * scale,
                        y: link.localRect.minY + candidate.y * scale)
        guard leftCanvas, link.remoteRect.contains(p) else { return false }
        reportPointer(nil)
        linkedCursor = p
        onLinkedDisplayActive?(true)
        sendLinkedCursor(link)
        return true
    }

    private func sendLinkedCursor(_ link: TrackpadLink) {
        guard let linkedCursor else { return }
        let pos = remoteCanvasPoint(linkedCursor, link)
        inputManager?.mouseMove(x: Int32(pos.x), y: Int32(pos.y))
        onLinkedCursorMoved?(pos)
    }

    /// Bring the cursor (and input routing) back to this view's canvas.
    private func returnFromLinkedDisplay() {
        guard linkedCursor != nil else { return }
        linkedCursor = nil
        onLinkedCursorMoved?(nil)
        onLinkedDisplayActive?(false)
        if trackpadMode { reportPointer(trackpadCursor) }
    }

    /// Region the trackpad cursor may travel: the whole view, or the
    /// aspect-fitted canvas when `constrainTrackpadToCanvas` is set or a
    /// linked display is arranged beside it (so it crosses at the
    /// picture's edge, not the letterbox's).
    private var trackpadCursorBounds: CGRect {
        if trackpadLink != nil, canvasSize.width > 0, canvasSize.height > 0 {
            let a = mapFromCanvas(.zero)
            let b = mapFromCanvas(CGPoint(x: canvasSize.width, y: canvasSize.height))
            let canvas = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
            let visible = canvas.intersection(bounds)
            return visible.isNull ? bounds : visible
        }
        guard constrainTrackpadToCanvas,
              canvasSize.width > 0, canvasSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / canvasSize.width, bounds.height / canvasSize.height)
        let w = canvasSize.width * scale
        let h = canvasSize.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // A constrained surface is usually created with trackpad mode
        // already on, i.e. at zero bounds — which parked the cursor at
        // the origin. Center it once real bounds arrive.
        guard constrainTrackpadToCanvas, trackpadMode,
              !trackpadCursorPlacedInBounds, bounds.width > 0, bounds.height > 0 else { return }
        trackpadCursorPlacedInBounds = true
        let range = trackpadCursorBounds
        trackpadCursor = CGPoint(x: range.midX, y: range.midY)
        trackpadCursorInitialized = true
        reportPointer(trackpadCursor)
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
        guard !(usesTrackpadGestures && (multiFingerSequence || indirectScrollActive)),
              gesture.state == .changed || gesture.state == .began else { return }
        returnFromLinkedDisplay()
        let viewPt = gesture.location(in: self)
        let pos = mapToCanvas(viewPt)
        inputManager?.mouseMove(x: Int32(pos.x), y: Int32(pos.y))
        reportPointer(viewPt)
    }

    /// Two-finger trackpad scroll → MouseScroll.
    @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        // Reset so we get deltas, not cumulative offset.
        gesture.setTranslation(.zero, in: self)
        if usesTrackpadGestures {
            switch gesture.state {
            case .began, .changed:
                guard translation != .zero else { return }
                if !indirectScrollActive {
                    inputManager?.mouseButton(0, pressed: false)
                    pointerButtonDown = false
                }
                inputManager?.trackpadScroll(dx: Double(translation.x), dy: Double(translation.y),
                                             phase: indirectScrollActive ? .changed : .began)
                indirectScrollActive = true
            case .ended, .cancelled, .failed:
                guard indirectScrollActive else { return }
                let velocity = gesture.velocity(in: self)
                let phase: TrackpadPhase = gesture.state == .ended ? .ended : .cancelled
                inputManager?.trackpadScroll(dx: Double(translation.x), dy: Double(translation.y), phase: phase,
                                             vx: Double(velocity.x), vy: Double(velocity.y))
                indirectScrollActive = false
            default:
                break
            }
        } else {
            inputManager?.scroll(dx: Double(translation.x) * 0.5, dy: Double(translation.y) * 0.5)
        }
    }

    /// Two-finger tap → right click. In trackpad mode the click lands at
    /// the tracked cursor (not the fingers); in touchscreen mode it
    /// lands where the fingers tapped.
    @objc private func handleSecondaryTap(_ gesture: UITapGestureRecognizer) {
        guard !usesTrackpadGestures else { return }
        let pos = trackpadMode
            ? mapToCanvas(trackpadCursor)
            : mapToCanvas(gesture.location(in: self))
        inputManager?.mouseMove(x: Int32(pos.x), y: Int32(pos.y))
        inputManager?.mouseButton(1, pressed: true)  // right down
        inputManager?.mouseButton(1, pressed: false)  // right up
    }

    // MARK: - Viewport pinch-to-zoom / double-tap reset

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartScale = viewportScale
            pinchAnchorInView = gesture.location(in: self)
            pinchStartOffset = viewportOffset
        case .changed:
            let newScale = max(1.0, min(pinchStartScale * gesture.scale, 6.0))
            let ratio = newScale / pinchStartScale

            // Adjust offset so the pinch anchor stays stationary.
            let anchorOffsetX = pinchAnchorInView.x - bounds.midX
            let anchorOffsetY = pinchAnchorInView.y - bounds.midY
            viewportOffset = CGPoint(
                x: pinchStartOffset.x * ratio + anchorOffsetX * (1 - ratio),
                y: pinchStartOffset.y * ratio + anchorOffsetY * (1 - ratio)
            )
            viewportScale = newScale
            clampOffset()
            onViewportChanged?(viewportScale, viewportOffset)
        case .ended, .cancelled:
            // Snap to 1x if very close.
            if viewportScale < 1.05 {
                viewportScale = 1.0
                viewportOffset = .zero
                onViewportChanged?(viewportScale, viewportOffset)
            }
        default:
            break
        }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if viewportScale > 1.05 {
            // Reset to fit.
            viewportScale = 1.0
            viewportOffset = .zero
        } else {
            // Zoom to 2x centered on tap point.
            let tapPt = gesture.location(in: self)
            let newScale: CGFloat = 2.0
            let anchorX = tapPt.x - bounds.midX
            let anchorY = tapPt.y - bounds.midY
            viewportOffset = CGPoint(
                x: -anchorX * (newScale - 1),
                y: -anchorY * (newScale - 1)
            )
            viewportScale = newScale
            clampOffset()
        }
        onViewportChanged?(viewportScale, viewportOffset)
    }

    /// Clamp the offset so the canvas can't be panned out of the view.
    private func clampOffset() {
        guard viewportScale > 1.0 else {
            viewportOffset = .zero
            return
        }
        let maxOffsetX = bounds.width * (viewportScale - 1) / 2
        let maxOffsetY = bounds.height * (viewportScale - 1) / 2
        viewportOffset.x = max(-maxOffsetX, min(maxOffsetX, viewportOffset.x))
        viewportOffset.y = max(-maxOffsetY, min(maxOffsetY, viewportOffset.y))
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
            // Convert altitude/azimuth into the wire's normalized tilt
            // vector: magnitude = zenith / 90°, decomposed by azimuth.
            tiltX: cos(Float(touch.azimuthAngle(in: self)))
                * max(0, min(1, (Float.pi / 2 - Float(touch.altitudeAngle)) / (Float.pi / 2))),
            tiltY: sin(Float(touch.azimuthAngle(in: self)))
                * max(0, min(1, (Float.pi / 2 - Float(touch.altitudeAngle)) / (Float.pi / 2))),
            predicted: predicted,
            timestampUs: UInt64(touch.timestamp * 1_000_000)
        )
        sampleSeq += 1
        inputManager?.sendStylus?(sample)
    }

    // MARK: - Hardware keyboard chords (pressesBegan)
    //
    // Plain typing flows through UIKeyInput.insertText below; presses
    // handle what insertText can't see — modifier chords (⌘C, ⌃A…) and
    // non-text keys (arrows, Esc, F-keys). The host injects them as
    // CGEvents with real keycodes + flags.

    private func modifierBits(_ flags: UIKeyModifierFlags) -> UInt16 {
        var bits: UInt16 = 0
        if flags.contains(.shift) { bits |= 1 }
        if flags.contains(.control) { bits |= 2 }
        if flags.contains(.alternate) { bits |= 4 }
        if flags.contains(.command) { bits |= 8 }
        return bits
    }

    // MARK: - Hardware keyboard (via UIKeyInput)

    public var hasText: Bool { true }

    public func insertText(_ text: String) {
        // Return arrives as insertText("\n") from UIKeyInput — send it
        // as a real Enter keypress (the host's text path can't type
        // control characters; see flux-input TextInput handling).
        if text == "\n" || text == "\r" {
            inputManager?.keyDown("Enter")
            inputManager?.keyUp("Enter")
            return
        }
        inputManager?.textInput(text)
    }

    public func deleteBackward() {
        inputManager?.keyDown("Backspace")
        inputManager?.keyUp("Backspace")
    }

    // MARK: - Soft-keyboard key bar
    //
    // The on-screen keyboard has no arrows, Esc or Tab. This bar rides
    // on top of it (inputAccessoryView); arrows auto-repeat while held,
    // like a hardware key.

    private static let keyBarKeys: [(title: String, key: String, repeats: Bool)] = [
        ("esc", "Escape", false),
        ("tab", "Tab", false),
        ("←", "ArrowLeft", true),
        ("↓", "ArrowDown", true),
        ("↑", "ArrowUp", true),
        ("→", "ArrowRight", true),
    ]

    private var keyRepeatTimer: Timer?
    private lazy var keyBar: UIView = makeKeyBar()

    public override var inputAccessoryView: UIView? { keyBar }

    private func makeKeyBar() -> UIView {
        let bar = UIInputView(
            frame: CGRect(x: 0, y: 0, width: 0, height: 48),
            inputViewStyle: .keyboard
        )
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, entry) in Self.keyBarKeys.enumerated() {
            var config = UIButton.Configuration.gray()
            config.title = entry.title
            config.baseForegroundColor = .label
            let button = UIButton(configuration: config)
            button.tag = index
            button.addTarget(self, action: #selector(keyBarDown(_:)), for: .touchDown)
            button.addTarget(self, action: #selector(keyBarUp(_:)),
                             for: [.touchUpInside, .touchUpOutside, .touchCancel])
            stack.addArrangedSubview(button)
        }
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -6),
        ])
        return bar
    }

    @objc private func keyBarDown(_ sender: UIButton) {
        let entry = Self.keyBarKeys[sender.tag]
        tapKey(entry.key)
        keyRepeatTimer?.invalidate()
        guard entry.repeats else { return }
        // Hardware-like repeat: 0.4 s delay, then ~14 presses/s.
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self else { return }
            let repeating = Timer(timeInterval: 0.07, repeats: true) { [weak self] _ in
                self?.tapKey(entry.key)
            }
            RunLoop.main.add(repeating, forMode: .common)
            self.keyRepeatTimer = repeating
        }
        RunLoop.main.add(timer, forMode: .common)
        keyRepeatTimer = timer
    }

    @objc private func keyBarUp(_ sender: UIButton) {
        keyRepeatTimer?.invalidate()
        keyRepeatTimer = nil
    }

    private func tapKey(_ key: String) {
        inputManager?.keyDown(key)
        inputManager?.keyUp(key)
    }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let key = press.key, let name = uiKeyToName(key) {
                // Carry the chord modifiers (1=Shift 2=Ctrl 4=Alt
                // 8=Cmd) so the host stamps the right CGEventFlags —
                // ⌘C from a Magic Keyboard works end-to-end now.
                inputManager?.keyDown(name, modifiers: modifierBits(key.modifierFlags))
            }
        }
        // Don't call super — we consume the events.
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let key = press.key, let name = uiKeyToName(key) {
                inputManager?.keyUp(name, modifiers: modifierBits(key.modifierFlags))
            }
        }
    }

    // MARK: - Coordinate mapping

    /// Aspect-fit placement of the canvas in the unzoomed view.
    private var canvasFit: (scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat) {
        let viewAspect = bounds.width / bounds.height
        let canvasAspect = canvasSize.width / canvasSize.height
        if canvasAspect > viewAspect {
            let scale = bounds.width / canvasSize.width
            return (scale, 0, (bounds.height - canvasSize.height * scale) / 2)
        }
        let scale = bounds.height / canvasSize.height
        return (scale, (bounds.width - canvasSize.width * scale) / 2, 0)
    }

    /// View points per canvas pixel, including zoom.
    private var viewToCanvasScale: CGFloat {
        guard canvasSize.width > 0, canvasSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return 1 }
        return canvasFit.scale * viewportScale
    }

    /// Inverse of mapToCanvas.
    private func mapFromCanvas(_ point: CGPoint) -> CGPoint {
        guard canvasSize.width > 0, canvasSize.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return point
        }
        let fit = canvasFit
        let unzoomedX = point.x * fit.scale + fit.offsetX
        let unzoomedY = point.y * fit.scale + fit.offsetY
        return CGPoint(
            x: (unzoomedX - bounds.midX) * viewportScale + bounds.midX + viewportOffset.x,
            y: (unzoomedY - bounds.midY) * viewportScale + bounds.midY + viewportOffset.y
        )
    }

    /// Map UIKit view-local point → canvas pixel coordinate.
    /// Accounts for aspect-fit layout AND viewport zoom/pan.
    private func mapToCanvas(_ point: CGPoint) -> CGPoint {
        guard canvasSize.width > 0, canvasSize.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return point
        }

        // Reverse the viewport transform (zoom + pan) first.
        // The Metal view is scaled around the center and offset.
        let cx = bounds.midX
        let cy = bounds.midY
        let unzoomedX = (point.x - cx - viewportOffset.x) / viewportScale + cx
        let unzoomedY = (point.y - cy - viewportOffset.y) / viewportScale + cy

        // Then apply the aspect-fit mapping.
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
            x: (unzoomedX - offsetX) / scale,
            y: (unzoomedY - offsetY) / scale
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
