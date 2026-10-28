// LatencyProbe.swift — viewer half of the motion-to-photon stamps
// (flux RFC-0019).
//
// Each frame is stamped when it is reassembled, decoded, submitted for
// present and on glass (the drawable's presented time). The host's
// capture clock is mapped onto ours with Pong.host_us: the pong with the
// smallest RTT of the last few sets the offset, with half that RTT as the
// error bound. Every report window the stages are summarised (medians)
// for the HUD and for the host log (ViewerTiming).
//
// All times are CACurrentMediaTime() seconds, the clock of
// CAMetalDrawable.presentedTime. Thread-safe; called from the receive
// queue, the decode callback and Metal's presented handler.

import Foundation
import QuartzCore

public final class LatencyProbe {
    struct Summary {
        var frames: Int
        var clockErrMs: Double?
        var hostNetMs: Double?
        var decodeMs: Double
        var renderMs: Double
        var glassMs: Double
        var totalMs: Double?
        var totalP95Ms: Double?
        /// The window's slowest frame.
        var worst: Sample
    }

    private struct Stamps {
        var received: CFTimeInterval
        /// Since the previous frame was reassembled.
        var gap: CFTimeInterval
        var decoded: CFTimeInterval?
    }

    /// One frame's stages in ms; public because ViewerTiming carries one.
    public struct Sample {
        public var hostNet: Double?
        public var decode: Double
        public var render: Double
        public var glass: Double
        public var total: Double?
        public var gap: Double
    }

    private let lock = NSLock()
    private var pings: [UInt64: CFTimeInterval] = [:]
    /// (host capture µs − viewer µs at the ping midpoint, RTT s), newest last.
    private var offsets: [(offsetUs: Double, rtt: CFTimeInterval)] = []
    private var frames: [UInt64: Stamps] = [:]
    private var frameOrder: [UInt64] = []
    private var lastReceived: CFTimeInterval?
    private var samples: [Sample] = []
    private var windowStart = CACurrentMediaTime()

    private static let maxFrames = 240      // ~2 s at 120 fps
    private static let offsetWindow = 8     // pongs (~16 s at 0.5 Hz)
    /// Capture → glass outside this is a clock mismatch (e.g. the host's
    /// multi-display compositor stamps a start-relative clock).
    private static let plausibleTotal: ClosedRange<Double> = 0...5_000
    static let reportInterval: CFTimeInterval = 2

    func pingSent(nonce: UInt64, at: CFTimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if pings.count >= 8 { pings.removeAll() }
        pings[nonce] = at
    }

    func pong(nonce: UInt64, hostUs: UInt64, at: CFTimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard let sent = pings.removeValue(forKey: nonce), at >= sent else { return }
        let midUs = (sent + at) / 2 * 1_000_000
        offsets.append((Double(hostUs) - midUs, at - sent))
        if offsets.count > Self.offsetWindow { offsets.removeFirst() }
    }

    func received(captureUs: UInt64, at: CFTimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if frames[captureUs] == nil { frameOrder.append(captureUs) }
        frames[captureUs] = Stamps(received: at, gap: lastReceived.map { at - $0 } ?? 0)
        lastReceived = at
        while frameOrder.count > Self.maxFrames {
            frames.removeValue(forKey: frameOrder.removeFirst())
        }
    }

    func decoded(captureUs: UInt64, at: CFTimeInterval) {
        lock.lock(); defer { lock.unlock() }
        frames[captureUs]?.decoded = at
    }

    func presented(captureUs: UInt64, submitted: CFTimeInterval, onGlass: CFTimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard let stamps = frames.removeValue(forKey: captureUs),
              let decoded = stamps.decoded else { return }
        var sample = Sample(hostNet: nil,
                            decode: (decoded - stamps.received) * 1000,
                            render: (submitted - decoded) * 1000,
                            glass: (onGlass - submitted) * 1000,
                            total: nil,
                            gap: stamps.gap * 1000)
        if let offset = bestOffset()?.offsetUs {
            let captured = (Double(captureUs) - offset) / 1_000_000
            let total = (onGlass - captured) * 1000
            if Self.plausibleTotal.contains(total) {
                sample.total = total
                sample.hostNet = (stamps.received - captured) * 1000
            }
        }
        samples.append(sample)
    }

    /// The window's summary once `reportInterval` has passed and frames
    /// were presented in it; starts the next window.
    func takeSummary(now: CFTimeInterval = CACurrentMediaTime()) -> Summary? {
        lock.lock(); defer { lock.unlock() }
        guard now - windowStart >= Self.reportInterval else { return nil }
        windowStart = now
        let window = samples
        samples.removeAll(keepingCapacity: true)
        guard !window.isEmpty else { return nil }
        let totals = window.compactMap(\.total).sorted()
        // By capture → glass when the clock offset is known, else by the
        // viewer-only stages.
        let worst = window.max {
            ($0.total ?? $0.decode + $0.render + $0.glass) < ($1.total ?? $1.decode + $1.render + $1.glass)
        }!
        let hostNets = window.compactMap(\.hostNet).sorted()
        return Summary(
            frames: window.count,
            clockErrMs: totals.isEmpty ? nil : bestOffset().map { $0.rtt / 2 * 1000 },
            hostNetMs: Self.quantile(hostNets, 0.5),
            decodeMs: Self.quantile(window.map(\.decode).sorted(), 0.5) ?? 0,
            renderMs: Self.quantile(window.map(\.render).sorted(), 0.5) ?? 0,
            glassMs: Self.quantile(window.map(\.glass).sorted(), 0.5) ?? 0,
            totalMs: Self.quantile(totals, 0.5),
            totalP95Ms: Self.quantile(totals, 0.95),
            worst: worst
        )
    }

    /// New connection: the host (and its clock) may have changed.
    func reset() {
        lock.lock()
        pings.removeAll()
        offsets.removeAll()
        lock.unlock()
        resetFrames()
    }

    /// Decode pipeline reset (display switch): in-flight stamps are void,
    /// the clock offset still holds.
    func resetFrames() {
        lock.lock(); defer { lock.unlock() }
        frames.removeAll()
        frameOrder.removeAll()
        lastReceived = nil
        samples.removeAll()
        windowStart = CACurrentMediaTime()
    }

    private func bestOffset() -> (offsetUs: Double, rtt: CFTimeInterval)? {
        offsets.min { $0.rtt < $1.rtt }
    }

    private static func quantile(_ sorted: [Double], _ q: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
    }
}
