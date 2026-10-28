// MetalRenderer.swift — render decoded CVPixelBuffers to a CAMetalLayer.
//
// Presentation uses:
//   - CAMetalLayer with maximumDrawableCount = 2 (third drawable costs
//     a full frame of latency)
//   - present on decode from a serial render queue, without a main-thread
//     display-link tick before the compositor's own vsync
//   - or, with lowLatencyPresent, a CAMetalDisplayLink at one frame of
//     latency on its own thread, presenting the latest frame each refresh
//
// The input is a CVPixelBuffer (BGRA) from the VTDecompressionSession.
// We create a Metal texture from it and blit to the drawable.

import Foundation
import Metal
import MetalKit
import CoreVideo
import QuartzCore

/// A SwiftUI-compatible Metal view that displays decoded video frames.
/// Call `enqueue(_:)` from any thread; a serial render queue presents
/// the latest frame without blocking input or the decode callback.
public final class MetalRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    public let metalLayer: CAMetalLayer

    /// One latest-frame slot, rather than one queued closure per frame.
    private var pendingBuffer: CVPixelBuffer?
    private var pendingTimestampUs: UInt64 = 0

    /// Called from Metal's presented handler with the frame's capture
    /// timestamp, when it was submitted and when it reached the glass
    /// (CACurrentMediaTime seconds). Set before frames are enqueued.
    public var onPresented: ((_ timestampUs: UInt64, _ submitted: CFTimeInterval, _ onGlass: CFTimeInterval) -> Void)?
    private let lock = NSLock()

    private var presentationScheduled = false
    private var stopped = false
    private let renderQueue = DispatchQueue(label: "fastport.video.render", qos: .userInteractive)
    private let inFlight = DispatchSemaphore(value: 2)
    private let geometryLock = NSLock()

    /// UserDefaults key for presenting through a display link.
    public static let lowLatencyPresentKey = "display.lowLatencyPresent"
    /// Under `lock`: frames wait for the display link instead of the
    /// render queue.
    private var usesDisplayLink = false
    private var displayLink: CAMetalDisplayLink?
    private var linkProxy: LinkProxy?

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = queue

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        ) == kCVReturnSuccess, let cache = cache else {
            return nil
        }
        self.textureCache = cache

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false  // must be false for blit encoder copy
        layer.maximumDrawableCount = 2 // Third drawable = +1 frame latency
        layer.contentsGravity = .resizeAspect
        layer.allowsNextDrawableTimeout = true
        #if os(macOS)
        layer.displaySyncEnabled = true
        #endif
        self.metalLayer = layer
    }

    /// Enqueue a decoded frame for immediate off-main presentation.
    /// Thread-safe; called from the decode callback.
    public func enqueue(_ pixelBuffer: CVPixelBuffer, timestampUs: UInt64 = 0) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        pendingBuffer = pixelBuffer
        pendingTimestampUs = timestampUs
        let linked = usesDisplayLink
        lock.unlock()
        // A display link asks for no update while the drawable is 0x0.
        if linked { sizeDrawable(for: pixelBuffer) }
        presentIfNeeded()
    }

    /// Stop accepting frames when the hosting view is removed. A blocked
    /// drawable acquisition can finish on the render queue after teardown.
    public func stop() {
        lock.lock()
        stopped = true
        pendingBuffer = nil
        lock.unlock()
        lowLatencyPresent = false
    }

    /// Present through a CAMetalDisplayLink at one frame of latency rather
    /// than on arrival, where the 2026-10-28 iPad sessions measured ~16 ms
    /// from submit to glass. A/B experiment, off by default: on macOS 26
    /// (60 Hz display) the link targeted presentation 3 refreshes out and
    /// glass rose from ~25 to ~50 ms; iOS is untested. Main thread only.
    public var lowLatencyPresent = false {
        didSet {
            guard lowLatencyPresent != oldValue else { return }
            displayLink?.invalidate()
            displayLink = nil
            linkProxy = nil
            lock.lock()
            usesDisplayLink = lowLatencyPresent
            lock.unlock()
            guard lowLatencyPresent else {
                presentIfNeeded()
                return
            }
            let link = CAMetalDisplayLink(metalLayer: metalLayer)
            let proxy = LinkProxy(renderer: self)
            link.delegate = proxy
            link.preferredFrameLatency = 1
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: Self.linkRunLoop, forMode: .default)
            displayLink = link
            linkProxy = proxy
        }
    }

    /// One shared thread whose run loop drives the display links, so a
    /// busy main thread cannot delay a present.
    private static let linkRunLoop: RunLoop = {
        var loop: RunLoop?
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            loop = RunLoop.current
            // A port keeps run(mode:before:) from returning at once.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            while true { RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
        thread.name = "fastport.video.displaylink"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return loop!
    }()

    private final class LinkProxy: NSObject, CAMetalDisplayLinkDelegate {
        weak var renderer: MetalRenderer?
        init(renderer: MetalRenderer) { self.renderer = renderer }
        func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
            renderer?.present(update)
        }
    }

    /// Display-link callback: present the latest frame, if one arrived
    /// since the last refresh and the GPU has room.
    private func present(_ update: CAMetalDisplayLink.Update) {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        lock.lock()
        guard usesDisplayLink, let pb = pendingBuffer else {
            lock.unlock()
            inFlight.signal()
            return
        }
        pendingBuffer = nil
        let timestampUs = pendingTimestampUs
        lock.unlock()
        autoreleasepool {
            if !encode(pb, timestampUs: timestampUs, into: update.drawable) { inFlight.signal() }
        }
    }

    /// Schedule at most one drain, even if the GPU or drawable is busy.
    public func presentIfNeeded() {
        lock.lock()
        guard pendingBuffer != nil, !presentationScheduled, !usesDisplayLink else {
            lock.unlock()
            return
        }
        presentationScheduled = true
        lock.unlock()
        renderQueue.async { [weak self] in self?.drainPendingFrames() }
    }

    /// Layout stays on main; serialize layer geometry changes against
    /// drawableSize writes without holding the lock during nextDrawable().
    public func setFrame(_ frame: CGRect) {
        geometryLock.lock()
        defer { geometryLock.unlock() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = frame
        CATransaction.commit()
    }

    private func drainPendingFrames() {
        while true {
            // Do not consume the latest-frame slot until GPU capacity is
            // available. The decode callback can replace it while we wait.
            inFlight.wait()
            lock.lock()
            guard let sizing = pendingBuffer else {
                presentationScheduled = false
                lock.unlock()
                inFlight.signal()
                return
            }
            lock.unlock()
            autoreleasepool { render(sizedBy: sizing) }
        }
    }

    /// Acquire the drawable first and only then take the latest frame:
    /// nextDrawable() blocks while both drawables are queued or on glass,
    /// and on 2026-10-28 an iPad at ~44 fps spent a median 16 ms there
    /// holding a frame that newer decodes had already superseded.
    private func render(sizedBy sizing: CVPixelBuffer) {
        var submitted = false
        defer { if !submitted { inFlight.signal() } }

        sizeDrawable(for: sizing)

        guard let drawable = metalLayer.nextDrawable() else { return }
        lock.lock()
        guard let pb = pendingBuffer else {
            lock.unlock()
            return
        }
        pendingBuffer = nil
        let timestampUs = pendingTimestampUs
        lock.unlock()
        submitted = encode(pb, timestampUs: timestampUs, into: drawable)
    }

    /// Update the layer's drawable size if the frame resolution changed.
    private func sizeDrawable(for pb: CVPixelBuffer) {
        let drawableSize = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        geometryLock.lock()
        defer { geometryLock.unlock() }
        guard metalLayer.drawableSize != drawableSize else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.drawableSize = drawableSize
        CATransaction.commit()
    }

    /// Blit `pb` into `drawable` and present it. True once committed; its
    /// completion then releases one `inFlight` slot.
    private func encode(_ pb: CVPixelBuffer, timestampUs: UInt64, into drawable: CAMetalDrawable) -> Bool {
        // Create a Metal texture from the CVPixelBuffer.
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pb,
            nil,
            .bgra8Unorm,
            CVPixelBufferGetWidth(pb),
            CVPixelBufferGetHeight(pb),
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture = cvTexture,
              let sourceTexture = CVMetalTextureGetTexture(cvTexture) else {
            return false
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return false
        }

        // Blit from the source texture (decoded frame) to the drawable.
        let sourceSize = MTLSizeMake(
            min(sourceTexture.width, drawable.texture.width),
            min(sourceTexture.height, drawable.texture.height),
            1
        )
        blitEncoder.copy(
            from: sourceTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOriginMake(0, 0, 0),
            sourceSize: sourceSize,
            to: drawable.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOriginMake(0, 0, 0)
        )
        blitEncoder.endEncoding()
        // Metal retains its texture, but not the CVMetalTexture wrapper
        // or pixel buffer. Keep both alive until the blit has finished.
        let slots = inFlight
        let cache = textureCache
        commandBuffer.addCompletedHandler { [pb, cvTexture] _ in
            withExtendedLifetime((pb, cvTexture)) {
                CVMetalTextureCacheFlush(cache, 0)
            }
            slots.signal()
        }
        if let onPresented {
            let submittedAt = CACurrentMediaTime()
            drawable.addPresentedHandler { d in
                // 0 when the drawable was dropped instead of shown.
                if d.presentedTime > 0 { onPresented(timestampUs, submittedAt, d.presentedTime) }
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }
}
