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
import CoreGraphics

public enum TrackpadPhase: String {
    case began = "Began", changed = "Changed", ended = "Ended", cancelled = "Cancelled"
}

public enum TrackpadGestureKind: String {
    case magnify = "Magnify", rotate = "Rotate", smartMagnify = "SmartMagnify"
    case swipeSpaces = "SwipeSpaces", swipeVertical = "SwipeVertical", pinchFour = "PinchFour"
}

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
    case qualityFeedback(rttMs: UInt32, lossPct: Float, bandwidthKbps: UInt32, rawLossPct: Float? = nil)
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
    /// Pause this viewer's host video pipeline while its video is hidden.
    case setVideoPaused(paused: Bool)

    case trackpadScroll(dx: Double, dy: Double, phase: TrackpadPhase, vx: Double, vy: Double)
    case trackpadGesture(kind: TrackpadGestureKind, phase: TrackpadPhase, delta: Double, velocity: Double)

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
        case .qualityFeedback(let rttMs, let lossPct, let bandwidthKbps, let rawLossPct):
            dict = ["QualityFeedback": [
                "rtt_ms": rttMs,
                "loss_pct": lossPct,
                "bandwidth_kbps": bandwidthKbps,
                "raw_loss_pct": rawLossPct.map { $0 as Any } ?? NSNull(),
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
        case .trackpadScroll(let dx, let dy, let phase, let vx, let vy):
            dict = ["TrackpadScroll": ["dx": dx, "dy": dy, "phase": phase.rawValue, "vx": vx, "vy": vy]]
        case .trackpadGesture(let kind, let phase, let delta, let velocity):
            dict = ["TrackpadGesture": ["kind": kind.rawValue, "phase": phase.rawValue,
                                        "delta": delta, "velocity": velocity]]
        case .setVideoPaused(let paused):
            dict = ["SetVideoPaused": ["paused": paused]]
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

/// Repeats idempotent control edges over the lossy datagram path.
/// Call on the main queue; each instance belongs to one input/session route.
final class ControlMessageRepeater {
    private enum Edge: Hashable {
        case key(String)
        case display
        case videoPaused
    }

    private var pending: [Edge: UUID] = [:]

    func cancelAll() {
        pending.removeAll()
    }

    func send(_ message: ControlMessage, using send: @escaping (ControlMessage) -> Void) {
        let edge: Edge
        let delays: [Double]
        switch message {
        case .keyEvent(let key, _, let pressed):
            edge = .key(key)
            if pressed {
                // A stale release must never lift a key held again.
                pending.removeValue(forKey: edge)
                send(message)
                return
            }
            delays = [0.05, 0.15]
        case .setActiveDisplay:
            edge = .display
            delays = [0.1, 0.3]
        case .setVideoPaused:
            edge = .videoPaused
            delays = [0.1, 0.3]
        default:
            send(message)
            return
        }

        // A generation also cancels old releases after a down/up cycle,
        // and old display/pause repeats when the latest state changes.
        let generation = UUID()
        pending[edge] = generation
        send(message)
        for (index, delay) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.pending[edge] == generation else { return }
                if index == delays.count - 1 { self.pending.removeValue(forKey: edge) }
                send(message)
            }
        }
    }
}

// MARK: - Input manager

/// Manages input capture state and sends messages to the host.
/// Platform-specific subclasses (iOS TouchInputManager, macOS
/// KeyboardInputManager) call these methods.
public final class InputManager: ObservableObject {
    /// Callback to send a control message to the host.
    public var sendControl: ((ControlMessage) -> Void)? {
        didSet { cancelPendingControls() }
    }
    private let controlRepeater = ControlMessageRepeater()
    private var trackpadEdges: [String: UUID] = [:]

    /// Callback to send a stylus sample via flux-core-ffi.
    /// Set by the StreamSession when the pen connection is available.
    public var sendStylus: ((StylusSampleData) -> Void)?

    @Published public var isKeyboardActive = false

    public init() {}

    public func cancelPendingTrackpadControls() {
        trackpadEdges.removeAll()
    }

    public func cancelPendingControls() {
        cancelPendingTrackpadControls()
        controlRepeater.cancelAll()
    }

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

    public func trackpadScroll(dx: Double, dy: Double, phase: TrackpadPhase,
                               vx: Double = 0, vy: Double = 0) {
        sendTrackpad(.trackpadScroll(dx: dx, dy: dy, phase: phase, vx: vx, vy: vy),
                     phase: phase, stream: "scroll")
    }

    public func trackpadGesture(_ kind: TrackpadGestureKind, phase: TrackpadPhase,
                                delta: Double = 0, velocity: Double = 0) {
        sendTrackpad(.trackpadGesture(kind: kind, phase: phase, delta: delta, velocity: velocity),
                     phase: phase, stream: kind.rawValue)
    }

    private func sendTrackpad(_ message: ControlMessage, phase: TrackpadPhase, stream: String) {
        guard let sendControl else { return }
        let generation = UUID()
        trackpadEdges[stream] = generation
        sendControl(message)
        guard phase == .ended || phase == .cancelled else { return }
        // Only terminal edges repeat. A new stream or route cancels stale
        // releases so they cannot terminate a subsequent gesture.
        for delay in [0.03, 0.09] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.trackpadEdges[stream] == generation else { return }
                sendControl(message)
                if delay == 0.09 { self.trackpadEdges.removeValue(forKey: stream) }
            }
        }
    }

    /// One-shot named host action (Mission Control, Launchpad,
    /// AppSwitch). Rides the KeyEvent message; the host triggers on
    /// press and ignores the release.
    public func tapHostAction(_ name: String) {
        keyDown(name)
        keyUp(name)
    }

    // MARK: - Keyboard

    public func keyDown(_ key: String, modifiers: UInt16 = 0) {
        guard let sendControl else { return }
        controlRepeater.send(.keyEvent(key: key, modifiers: modifiers, pressed: true), using: sendControl)
    }

    public func keyUp(_ key: String, modifiers: UInt16 = 0) {
        guard let sendControl else { return }
        controlRepeater.send(.keyEvent(key: key, modifiers: modifiers, pressed: false), using: sendControl)
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
        guard let sendControl else { return }
        controlRepeater.send(.setActiveDisplay(displayId: displayId), using: sendControl)
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

// MARK: - Trackpad gesture classification (points, independent of UIKit)

struct TrackpadGestureClassifier {
    struct Touch {
        var id: Int
        var point: CGPoint
    }

    enum Action: Equatable {
        case scroll(TrackpadPhase, Double, Double, Double, Double)
        case gesture(TrackpadGestureKind, TrackpadPhase, Double, Double)
        case rightClick
        case lookUp
    }

    private struct Sample {
        var time: TimeInterval
        var center: CGPoint
        var spread: CGFloat
    }

    private struct Group {
        var points: [Int: CGPoint]
        var travel: [Int: CGFloat]
        var startTime: TimeInterval
        var origin: CGPoint
        var center: CGPoint
        var initialSpread: CGFloat
        var spread: CGFloat
        var angle: CGFloat
        var rotation: CGFloat = 0
        var centroidTravel: CGFloat = 0
        var lastMotion: TimeInterval
        var samples: [Sample]
        var kind: TrackpadGestureKind?
        var scrolling = false
        var rotating = false
        var lifting = false
        var tapAllowed = true
        /// The gesture already ended because a finger lifted; the fingers
        /// still down are ignored until all of them leave the glass.
        var draining = false
    }

    private var group: Group?
    private var touchLifetimes: [Int: (time: TimeInterval, point: CGPoint, travel: CGFloat)] = [:]
    private var pendingTap: (time: TimeInterval, point: CGPoint)?
    var rightClickDeadline: TimeInterval? { pendingTap.map { $0.time + 0.35 } }

    mutating func flush(at time: TimeInterval) -> [Action] {
        guard let pendingTap, time >= pendingTap.time + 0.35 else { return [] }
        self.pendingTap = nil
        return [.rightClick]
    }

    mutating func cancel(at time: TimeInterval, size: CGSize) -> [Action] {
        let actions = group.map { finish($0, phase: .cancelled, time: time, size: size) } ?? []
        group = nil
        touchLifetimes.removeAll()
        pendingTap = nil
        return actions
    }

    /// Include lifted fingers' final positions so sequential lifts still
    /// measure the complete tap and do not lose the last motion sample.
    mutating func update(_ touches: [Touch], lifted: [Touch] = [], at time: TimeInterval,
                         size: CGSize) -> [Action] {
        var actions = flush(at: time)
        let active = Dictionary(uniqueKeysWithValues: touches.map { ($0.id, $0.point) })
        let observed = Dictionary(uniqueKeysWithValues: (touches + lifted).map { ($0.id, $0.point) })
        for (id, point) in observed {
            if var lifetime = touchLifetimes[id] {
                lifetime.travel += distance(point, lifetime.point)
                lifetime.point = point
                touchLifetimes[id] = lifetime
            } else if active[id] != nil {
                touchLifetimes[id] = (time, point, 0)
            }
        }
        defer { touchLifetimes = touchLifetimes.filter { active[$0.key] != nil } }
        guard var g = group else {
            if active.count >= 2 { group = makeGroup(active, time: time) }
            return actions
        }
        let oldIDs = Set(g.points.keys)
        let newIDs = Set(active.keys)
        for (id, previous) in g.points {
            if let point = observed[id] {
                g.travel[id, default: 0] += distance(point, previous)
                g.points[id] = point
            }
        }
        let center = centroid(g.points)
        let spread = meanSpread(g.points, center: center)
        let angle = pairAngle(g.points)
        var angleStep = angle - g.angle
        while angleStep > .pi { angleStep -= 2 * .pi }
        while angleStep < -.pi { angleStep += 2 * .pi }
        // UIKit's y axis points down; the wire's rotation is CCW positive.
        let rotationStep = -angleStep * 180 / .pi
        g.rotation += rotationStep
        let dx = center.x - g.center.x, dy = center.y - g.center.y
        g.centroidTravel += hypot(dx, dy)
        if hypot(dx, dy) > 0.001 || abs(spread - g.spread) > 0.001 { g.lastMotion = time }
        g.samples.append(Sample(time: time, center: center, spread: spread))
        while g.samples.count > 2 && g.samples[1].time <= time - 0.05 { g.samples.removeFirst() }

        if g.draining {
            group = active.isEmpty ? nil : g
            return actions
        }

        if newIDs != oldIDs {
            let isLift = newIDs.isSubset(of: oldIDs)
            let isTap = g.tapAllowed && !g.scrolling && g.kind == nil && !g.rotating
                && time - g.startTime < 0.25
                && g.travel.values.allSatisfy { $0 < (oldIDs.count == 2 ? 8 : 10) }
            if isLift && isTap {
                // Keep the original count until every finger has lifted.
                g.lifting = true
                g.center = center; g.spread = spread; g.angle = angle
                if active.isEmpty {
                    if oldIDs.count == 2 {
                        if let tap = pendingTap, time - tap.time < 0.35,
                           distance(center, tap.point) < 20 {
                            pendingTap = nil
                            actions.append(.gesture(.smartMagnify, .ended, 0, 0))
                        } else {
                            if pendingTap != nil { actions.append(.rightClick) }
                            pendingTap = (time, center)
                        }
                    } else if oldIDs.count == 3 {
                        actions.append(.lookUp)
                    }
                    group = nil
                } else {
                    group = g
                }
                return actions
            }
            // Fingers leave the glass one at a time: the first lift ENDS a
            // started gesture (a cancel would snap Mission Control / a Space
            // switch back), and the rest stay consumed until all lift, like
            // a real trackpad. Adding fingers abandons the stream instead.
            let started = g.kind != nil || g.scrolling || g.rotating
            if isLift && started {
                actions += finish(g, phase: .ended, time: time, size: size)
                g.draining = true
                group = active.isEmpty ? nil : g
                return actions
            }
            actions += finish(g, phase: isLift ? .ended : .cancelled, time: time, size: size)
            group = active.count >= 2 ? makeGroup(active, time: time) : nil
            if isLift { group?.tapAllowed = false }
            return actions
        }

        if !g.lifting {
            let totalX = center.x - g.origin.x, totalY = center.y - g.origin.y
            let translation = hypot(totalX, totalY)
            let ratio = g.initialSpread > 0 ? spread / g.initialSpread - 1 : 0
            if active.count == 2 {
                // A pair's distance is twice its mean radius.
                let distanceChange = 2 * abs(spread - g.initialSpread)
                if !g.scrolling {
                    if g.kind == nil && hypot(translation, distanceChange) >= 8 {
                        if distanceChange > max(0.001, 1.5 * translation) {
                            g.kind = .magnify
                            actions.append(.gesture(.magnify, .began, Double(ratio), 0))
                        } else if !g.rotating && translation > 0.001 {
                            g.scrolling = true
                            actions.append(.scroll(.began, Double(totalX), Double(totalY), 0, 0))
                        }
                    } else if g.kind == .magnify && g.spread > 0 && spread != g.spread {
                        actions.append(.gesture(.magnify, .changed, Double(spread / g.spread - 1), 0))
                    }
                    if !g.scrolling {
                        if !g.rotating && abs(g.rotation) > 12 {
                            g.rotating = true
                            actions.append(.gesture(.rotate, .began, Double(g.rotation), 0))
                        } else if g.rotating && rotationStep != 0 {
                            actions.append(.gesture(.rotate, .changed, Double(rotationStep), 0))
                        }
                    }
                } else if dx != 0 || dy != 0 {
                    actions.append(.scroll(.changed, Double(dx), Double(dy), 0, 0))
                }
            } else {
                if g.kind == nil {
                    if active.count >= 4 && abs(ratio) > 0.25 && g.centroidTravel < 20 {
                        g.kind = .pinchFour
                        actions.append(.gesture(.pinchFour, .began, Double(ratio), 0))
                    } else if g.centroidTravel >= 20 - 0.000001 {
                        let horizontal = abs(totalX) >= abs(totalY)
                        let kind: TrackpadGestureKind = horizontal ? .swipeSpaces : .swipeVertical
                        g.kind = kind
                        let delta = progress(kind, x: totalX, y: totalY, size: size)
                        actions.append(.gesture(kind, .began, delta, 0))
                    }
                } else if let kind = g.kind {
                    let delta = kind == .pinchFour
                        ? (g.spread > 0 ? Double(spread / g.spread - 1) : 0)
                        : progress(kind, x: dx, y: dy, size: size)
                    if delta != 0 { actions.append(.gesture(kind, .changed, delta, 0)) }
                }
            }
        }
        g.center = center; g.spread = spread; g.angle = angle
        group = g
        return actions
    }

    private func makeGroup(_ points: [Int: CGPoint], time: TimeInterval) -> Group {
        let center = centroid(points)
        let spread = meanSpread(points, center: center)
        // A tap's duration/travel starts when its first finger lands,
        // even when the remaining fingers arrive in later callbacks.
        let startTime = points.keys.compactMap { touchLifetimes[$0]?.time }.min() ?? time
        let travel = Dictionary(uniqueKeysWithValues: points.keys.map { ($0, touchLifetimes[$0]?.travel ?? 0) })
        return Group(points: points, travel: travel, startTime: startTime, origin: center, center: center,
                     initialSpread: spread, spread: spread, angle: pairAngle(points), lastMotion: time,
                     samples: [Sample(time: time, center: center, spread: spread)])
    }

    private func finish(_ g: Group, phase: TrackpadPhase, time: TimeInterval, size: CGSize) -> [Action] {
        var vx: Double = 0, vy: Double = 0, spreadVelocity: Double = 0
        if phase == .ended, time - g.lastMotion <= 0.06,
           let first = g.samples.first, let last = g.samples.last, last.time > first.time {
            let dt = last.time - first.time
            vx = Double(last.center.x - first.center.x) / dt
            vy = Double(last.center.y - first.center.y) / dt
            if first.spread > 0 { spreadVelocity = Double(last.spread / first.spread - 1) / dt }
        }
        var actions: [Action] = []
        if g.scrolling { actions.append(.scroll(phase, 0, 0, vx, vy)) }
        if let kind = g.kind {
            let velocity = kind == .pinchFour ? spreadVelocity
                : (kind == .magnify ? 0 : progress(kind, x: CGFloat(vx), y: CGFloat(vy), size: size))
            actions.append(.gesture(kind, phase, 0, velocity))
        }
        if g.rotating { actions.append(.gesture(.rotate, phase, 0, 0)) }
        return actions
    }

    private func progress(_ kind: TrackpadGestureKind, x: CGFloat, y: CGFloat, size: CGSize) -> Double {
        kind == .swipeSpaces ? Double(x / max(1, 0.6 * size.width))
            : Double(-y / max(1, 0.4 * size.height))
    }

    private func centroid(_ points: [Int: CGPoint]) -> CGPoint {
        let sum = points.values.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private func meanSpread(_ points: [Int: CGPoint], center: CGPoint) -> CGFloat {
        points.values.reduce(0) { $0 + distance($1, center) } / CGFloat(points.count)
    }

    private func pairAngle(_ points: [Int: CGPoint]) -> CGFloat {
        let ids = points.keys.sorted()
        guard ids.count == 2, let a = points[ids[0]], let b = points[ids[1]] else { return 0 }
        return atan2(b.y - a.y, b.x - a.x)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

#if TRACKPAD_GESTURE_TESTS
// swiftc -parse-as-library -D TRACKPAD_GESTURE_TESTS Shared/InputManager.swift -o /tmp/trackpad-tests
@main
private enum TrackpadGestureTests {
    static let size = CGSize(width: 200, height: 250)
    static var passed = 0

    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        precondition(condition(), "FAILED: \(name)")
        passed += 1
        print("PASS: \(name)")
        fflush(stdout)
    }

    static func touches(_ points: [CGPoint]) -> [TrackpadGestureClassifier.Touch] {
        points.enumerated().map { .init(id: $0.offset, point: $0.element) }
    }

    static func pair(x: CGFloat = 0, y: CGFloat = 0, radius: CGFloat = 20,
                     degrees: CGFloat = 0) -> [TrackpadGestureClassifier.Touch] {
        let a = degrees * .pi / 180
        let dx = radius * cos(a), dy = -radius * sin(a)
        return touches([CGPoint(x: x - dx, y: y - dy), CGPoint(x: x + dx, y: y + dy)])
    }

    static func fingers(_ count: Int, x: CGFloat = 0, y: CGFloat = 0,
                        radius: CGFloat = 20) -> [TrackpadGestureClassifier.Touch] {
        touches((0..<count).map { i in
            let a = CGFloat(i) * 2 * .pi / CGFloat(count)
            return CGPoint(x: x + radius * cos(a), y: y + radius * sin(a))
        })
    }

    static func main() {
        var c = TrackpadGestureClassifier()
        _ = c.update(pair(), at: 0, size: size)
        check(c.update(pair(x: 2), at: 0.01, size: size).isEmpty, "scroll waits for slop")
        check(c.update(pair(x: 9), at: 0.02, size: size) == [.scroll(.began, 9, 0, 0, 0)],
              "scroll Began has accumulated non-zero point delta")
        check(c.update(pair(x: 10, radius: 40, degrees: 30), at: 0.03, size: size)
                == [.scroll(.changed, 1, 0, 0, 0)], "scroll excludes pinch and rotation")
        let end = c.update([], lifted: pair(x: 10, radius: 40, degrees: 30), at: 0.04, size: size)
        if case .scroll(.ended, 0, 0, let vx, let vy) = end.first {
            check(abs(vx - 250) < 0.001 && vy == 0, "scroll release velocity in points/second")
        } else { check(false, "scroll Ended") }

        c = TrackpadGestureClassifier()
        _ = c.update(pair(), at: 0, size: size)
        let pinch = c.update(pair(radius: 25), at: 0.02, size: size)
        check(pinch == [.gesture(.magnify, .began, 0.25, 0)], "pinch classification and initial magnification")
        check(c.update(pair(radius: 30), at: 0.03, size: size)
                == [.gesture(.magnify, .changed, Double(CGFloat(30) / 25 - 1), 0)],
              "pinch delta is incremental")

        c = TrackpadGestureClassifier()
        _ = c.update(pair(radius: 50), at: 0, size: size)
        check(c.update(pair(radius: 50, degrees: 11), at: 0.01, size: size).isEmpty,
              "rotation below 12 degrees does not start a zero-delta scroll")
        let rotate = c.update(pair(radius: 50, degrees: 13), at: 0.02, size: size)
        if case .gesture(.rotate, .began, let delta, 0) = rotate.first {
            check(abs(delta - 13) < 0.001, "rotation threshold and counter-clockwise sign")
        } else { check(false, "rotation threshold") }
        let both = c.update(pair(radius: 65, degrees: 20), at: 0.03, size: size)
        check(both.count == 2, "rotation can acquire concurrent pinch")
        let bothEnd = c.update([], lifted: pair(radius: 65, degrees: 20), at: 0.04, size: size)
        check(bothEnd == [.gesture(.magnify, .ended, 0, 0), .gesture(.rotate, .ended, 0, 0)],
              "concurrent streams each end")

        c = TrackpadGestureClassifier()
        _ = c.update(pair(), at: 1, size: size)
        check(c.update([], lifted: pair(), at: 1.1, size: size).isEmpty, "right click deferred")
        check(c.flush(at: 1.44).isEmpty, "right click waits 350 ms")
        check(c.flush(at: 1.451) == [.rightClick], "single two-finger tap becomes right click")
        check(c.flush(at: 2).isEmpty, "right click fires once")

        c = TrackpadGestureClassifier()
        _ = c.update(pair(), at: 1, size: size)
        _ = c.update([], lifted: pair(), at: 1.1, size: size)
        _ = c.update(pair(x: 10), at: 1.2, size: size)
        check(c.update([], lifted: pair(x: 10), at: 1.3, size: size)
                == [.gesture(.smartMagnify, .ended, 0, 0)], "two quick two-finger taps smart magnify")
        check(c.flush(at: 2).isEmpty, "smart magnify suppresses both right clicks")

        c = TrackpadGestureClassifier()
        _ = c.update(pair(), at: 1, size: size)
        _ = c.update([], lifted: pair(), at: 1.1, size: size)
        _ = c.update(pair(x: 25), at: 1.2, size: size)
        check(c.update([], lifted: pair(x: 25), at: 1.3, size: size) == [.rightClick],
              "distant second tap does not smart magnify")
        check(c.flush(at: 1.651) == [.rightClick], "distant second tap has its own deferred click")

        c = TrackpadGestureClassifier()
        let three = fingers(3)
        _ = c.update(three, at: 0, size: size)
        _ = c.update(Array(three.dropFirst()), lifted: [three[0]], at: 0.1, size: size)
        _ = c.update([three[2]], lifted: [three[1]], at: 0.12, size: size)
        check(c.update([], lifted: [three[2]], at: 0.15, size: size) == [.lookUp],
              "three-finger tap with sequential lifts looks up")
        c = TrackpadGestureClassifier()
        _ = c.update(fingers(4), at: 0, size: size)
        check(c.update([], lifted: fingers(4), at: 0.1, size: size).isEmpty, "four-finger tap does not look up")
        c = TrackpadGestureClassifier()
        _ = c.update(three, at: 0, size: size)
        check(c.update([], lifted: fingers(3, x: 11), at: 0.1, size: size).isEmpty,
              "tap travel limit applies at lift")

        for count in [3, 4] {
            for sign: CGFloat in [-1, 1] {
                c = TrackpadGestureClassifier()
                _ = c.update(fingers(count), at: 0, size: size)
                let swipe = c.update(fingers(count, x: 24 * sign), at: 0.02, size: size)
                if case .gesture(.swipeSpaces, .began, let delta, 0) = swipe.first {
                    check(abs(delta - Double(0.2 * sign)) < 0.001, "\(count)-finger horizontal sign/width normalisation \(sign)")
                } else { check(false, "horizontal swipe") }
                let increment = c.update(fingers(count, x: 36 * sign, y: 60), at: 0.04, size: size)
                if case .gesture(.swipeSpaces, .changed, let delta, 0) = increment.first {
                    check(abs(delta - Double(0.1 * sign)) < 0.001, "swipe locks axis and sends increments")
                } else { check(false, "axis lock") }
                let ended = c.update([], lifted: fingers(count, x: 36 * sign, y: 60), at: 0.05, size: size)
                if case .gesture(.swipeSpaces, .ended, 0, let velocity) = ended.first {
                    check(abs(velocity - Double(6 * sign)) < 0.001, "swipe release velocity in progress/second")
                } else { check(false, "swipe Ended") }

                c = TrackpadGestureClassifier()
                _ = c.update(fingers(count), at: 0, size: size)
                let vertical = c.update(fingers(count, y: 20 * sign), at: 0.02, size: size)
                if case .gesture(.swipeVertical, .began, let delta, 0) = vertical.first {
                    check(abs(delta + Double(0.2 * sign)) < 0.001, "\(count)-finger vertical sign/height normalisation \(sign)")
                } else { check(false, "vertical swipe") }
            }
        }

        c = TrackpadGestureClassifier()
        _ = c.update(fingers(4), at: 0, size: size)
        let four = c.update(fingers(4, radius: 14), at: 0.02, size: size)
        if case .gesture(.pinchFour, .began, let delta, 0) = four.first {
            check(abs(delta + 0.3) < 0.001, "four-finger pinch before centroid slop")
        } else { check(false, "four-finger pinch") }
        let fourEnd = c.update([], lifted: fingers(4, radius: 14), at: 0.03, size: size)
        if case .gesture(.pinchFour, .ended, 0, let velocity) = fourEnd.first {
            check(abs(velocity + 10) < 0.001, "four-finger pinch carries spread velocity")
        } else { check(false, "four-finger pinch Ended") }

        c = TrackpadGestureClassifier()
        _ = c.update(pair(), at: 0, size: size)
        _ = c.update(pair(x: 10), at: 0.02, size: size)
        check(c.update(fingers(3, x: 10), at: 0.03, size: size)
                == [.scroll(.cancelled, 0, 0, 0, 0)], "finger-count change cancels scroll")
        check(c.update(fingers(3, x: 34), at: 0.05, size: size).count == 1,
              "new finger count reclassifies from its own origin")
        check(c.cancel(at: 0.06, size: size) == [.gesture(.swipeSpaces, .cancelled, 0, 0)],
              "touch cancellation closes active gesture")

        c = TrackpadGestureClassifier()
        _ = c.update(pair(), at: 0, size: size)
        for i in 1...10 { _ = c.update(pair(x: CGFloat(i * i)), at: Double(i) * 0.01, size: size) }
        let recent = c.update([], lifted: pair(x: 100), at: 0.1, size: size)
        if case .scroll(.ended, 0, 0, let vx, _) = recent.first {
            check(abs(vx - 1500) < 0.001, "velocity uses recent 50 ms rather than whole gesture")
        } else { check(false, "recent velocity") }
        c = TrackpadGestureClassifier()
        _ = c.update(pair(), at: 0, size: size)
        _ = c.update(pair(x: 10), at: 0.02, size: size)
        check(c.update([], lifted: pair(x: 10), at: 0.09, size: size)
                == [.scroll(.ended, 0, 0, 0, 0)], "pause over 60 ms zeros release velocity")

        c = TrackpadGestureClassifier()
        _ = c.update(pair(), at: 0, size: size)
        _ = c.update(pair(radius: 25), at: 0.02, size: size)
        let pinchRotate = c.update(pair(radius: 30, degrees: -15), at: 0.04, size: size)
        if case .gesture(.rotate, .began, let delta, 0) = pinchRotate.last {
            check(abs(delta + 15) < 0.001 && pinchRotate.count == 2, "pinch can acquire clockwise rotation")
        } else { check(false, "pinch plus rotation") }
        check(c.cancel(at: 0.05, size: size)
                == [.gesture(.magnify, .cancelled, 0, 0), .gesture(.rotate, .cancelled, 0, 0)],
              "cancellation closes both concurrent streams")

        c = TrackpadGestureClassifier()
        _ = c.update(pair(), at: 0, size: size)
        _ = c.update(pair(x: 10), at: 0.02, size: size)
        let liftedPair = pair(x: 12)
        let oneLeft = c.update([liftedPair[0]], lifted: [liftedPair[1]], at: 0.03, size: size)
        if case .scroll(.ended, 0, 0, let vx, 0) = oneLeft.first {
            check(abs(vx - 400) < 0.001, "lifting to one finger ends scroll with velocity")
        } else { check(false, "one-finger remainder") }
        check(c.update([], lifted: [liftedPair[0]], at: 0.04, size: size).isEmpty,
              "remaining finger lift cannot generate a multi-finger tap")

        c = TrackpadGestureClassifier()
        _ = c.update(fingers(5), at: 0, size: size)
        let five = c.update(fingers(5, radius: 26), at: 0.02, size: size)
        if case .gesture(.pinchFour, .began, let delta, 0) = five.first {
            check(abs(delta - 0.3) < 0.001, "five-finger spread uses PinchFour")
        } else { check(false, "five-finger spread") }
        c = TrackpadGestureClassifier()
        _ = c.update(pair(), at: 0, size: size)
        check(c.update([], lifted: pair(), at: 0.26, size: size).isEmpty,
              "long two-finger hold is not a tap")

        c = TrackpadGestureClassifier()
        _ = c.update(pair(), at: 0, size: size)
        check(c.update(pair(x: 12, degrees: 20), at: 0.02, size: size)
                == [.scroll(.began, 12, 0, 0, 0)], "scroll classification wins simultaneous angle threshold")

        c = TrackpadGestureClassifier()
        _ = c.update([pair()[0]], at: 0, size: size)
        _ = c.update(pair(), at: 0.2, size: size)
        check(c.update([], lifted: pair(), at: 0.3, size: size).isEmpty,
              "tap duration includes staggered first-finger arrival")
        c = TrackpadGestureClassifier()
        _ = c.update([pair()[0]], at: 0, size: size)
        _ = c.update([pair(x: 12)[0]], at: 0.02, size: size)
        _ = c.update(pair(x: 12), at: 0.03, size: size)
        check(c.update([], lifted: pair(x: 12), at: 0.1, size: size).isEmpty,
              "tap travel includes movement before second finger arrives")

        let scrollJSON = ControlMessage.trackpadScroll(dx: 1.5, dy: -3, phase: .changed, vx: 0, vy: 0).toJSON()!
        let scrollFields = (try! JSONSerialization.jsonObject(with: scrollJSON) as! [String: [String: Any]])["TrackpadScroll"]!
        check(scrollFields.count == 5 && scrollFields["phase"] as? String == "Changed"
                && scrollFields["dx"] as? Double == 1.5 && scrollFields["dy"] as? Double == -3,
              "TrackpadScroll JSON matches contract")
        let gestureJSON = ControlMessage.trackpadGesture(kind: .magnify, phase: .changed, delta: 0.031, velocity: 0).toJSON()!
        let gestureFields = (try! JSONSerialization.jsonObject(with: gestureJSON) as! [String: [String: Any]])["TrackpadGesture"]!
        check(gestureFields.count == 4 && gestureFields["kind"] as? String == "Magnify"
                && gestureFields["phase"] as? String == "Changed" && gestureFields["delta"] as? Double == 0.031,
              "TrackpadGesture JSON matches contract")

        let input = InputManager()
        var messages: [ControlMessage] = []
        input.sendControl = { messages.append($0) }
        input.trackpadScroll(dx: 3, dy: 0, phase: .began)
        input.trackpadScroll(dx: 1, dy: 0, phase: .changed)
        RunLoop.main.run(until: Date().addingTimeInterval(0.11))
        check(messages.count == 2, "continuous updates do not repeat")
        messages.removeAll()
        input.trackpadScroll(dx: 0, dy: 0, phase: .ended, vx: 5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.11))
        check(messages.count == 3, "Ended sends exactly two extra copies")
        messages.removeAll()
        input.trackpadGesture(.rotate, phase: .cancelled)
        RunLoop.main.run(until: Date().addingTimeInterval(0.11))
        check(messages.count == 3, "Cancelled sends exactly two extra copies")
        messages.removeAll()
        input.trackpadScroll(dx: 0, dy: 0, phase: .ended)
        input.trackpadScroll(dx: 3, dy: 0, phase: .began)
        RunLoop.main.run(until: Date().addingTimeInterval(0.11))
        check(messages.count == 2, "new stream cancels stale terminal retries")
        messages.removeAll()
        input.trackpadGesture(.magnify, phase: .ended)
        input.sendControl = { messages.append($0) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.11))
        check(messages.count == 1, "new session route cancels terminal retries")
        messages.removeAll()
        input.keyDown("d", modifiers: 10)
        input.keyUp("d", modifiers: 10)
        if case .keyEvent("d", 10, true) = messages[0], case .keyEvent("d", 10, false) = messages[1] {
            check(true, "Look Up chord uses host key name d and Control|Meta")
        } else { check(false, "Look Up chord") }
        input.cancelPendingControls()
        // Real fingers leave the glass one at a time. A classified swipe must
        // END (committing Mission Control / the Space switch), never cancel,
        // and the fingers still down must not start a new gesture.
        for (dx, dy, kind) in [(CGFloat(0), CGFloat(-60), TrackpadGestureKind.swipeVertical),
                               (CGFloat(80), CGFloat(0), TrackpadGestureKind.swipeSpaces)] {
            var s = TrackpadGestureClassifier()
            _ = s.update(fingers(3), at: 0, size: size)
            _ = s.update(fingers(3, x: dx / 2, y: dy / 2), at: 0.02, size: size)
            _ = s.update(fingers(3, x: dx, y: dy), at: 0.04, size: size)
            let three = fingers(3, x: dx, y: dy)
            let firstLift = s.update(Array(three.prefix(2)), lifted: [three[2]], at: 0.05, size: size)
            check(firstLift.contains { if case .gesture(kind, .ended, _, _) = $0 { return true }; return false }
                  && !firstLift.contains { if case .gesture(_, .cancelled, _, _) = $0 { return true }; return false },
                  "\(kind.rawValue): first of three fingers lifting ends the swipe (no cancel)")
            let drift = fingers(3, x: dx + 30, y: dy + 30)
            check(s.update(Array(drift.prefix(2)), at: 0.07, size: size).isEmpty,
                  "\(kind.rawValue): remaining two fingers stay consumed (no scroll/pinch)")
            check(s.update(Array(drift.prefix(1)), lifted: [drift[1]], at: 0.08, size: size).isEmpty
                  && s.update([], lifted: [drift[0]], at: 0.09, size: size).isEmpty,
                  "\(kind.rawValue): later lifts emit nothing")
            check(!s.update(fingers(2), at: 0.5, size: size).contains { if case .gesture(_, .cancelled, _, _) = $0 { return true }; return false },
                  "\(kind.rawValue): a fresh touch afterwards starts clean")
        }

        print("All \(passed) trackpad tests passed")
    }
}
#endif
