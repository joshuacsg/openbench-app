// MetalRenderer.swift — render decoded CVPixelBuffers to a CAMetalLayer.
//
// Presentation uses:
//   - CAMetalLayer with maximumDrawableCount = 2 (third drawable costs
//     a full frame of latency)
//   - present on decode from a serial render queue, without a main-thread
//     display-link tick before the compositor's own vsync
//   - on iOS, an idle display link that only asks for the panel's maximum
//     refresh (holdsMaxRefreshRate), so ProMotion does not drop its rate
//     on a 30 fps stream and make each present wait for a slower vsync
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
        lock.unlock()
        presentIfNeeded()
    }

    /// Stop accepting frames when the hosting view is removed. A blocked
    /// drawable acquisition can finish on the render queue after teardown.
    public func stop() {
        lock.lock()
        stopped = true
        pendingBuffer = nil
        lock.unlock()
        #if os(iOS)
        holdsMaxRefreshRate = false
        #endif
    }

    #if os(iOS)
    /// UserDefaults key for the viewer's "hold 120 Hz" setting.
    public static let holdMaxRefreshKey = "display.holdMaxRefresh"

    private var refreshHold: CADisplayLink?

    /// Keep the panel at its maximum refresh while this renderer is on
    /// screen. Main thread only.
    public var holdsMaxRefreshRate = false {
        didSet {
            guard holdsMaxRefreshRate != oldValue else { return }
            refreshHold?.invalidate()
            refreshHold = nil
            guard holdsMaxRefreshRate else { return }
            // The link retains its target, so give it one that is not us.
            let link = CADisplayLink(target: RefreshHoldTarget(), selector: #selector(RefreshHoldTarget.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            refreshHold = link
        }
    }

    private final class RefreshHoldTarget: NSObject {
        @objc func tick() {}
    }
    #endif

    /// Schedule at most one drain, even if the GPU or drawable is busy.
    public func presentIfNeeded() {
        lock.lock()
        guard pendingBuffer != nil, !presentationScheduled else {
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

        let width = CVPixelBufferGetWidth(sizing)
        let height = CVPixelBufferGetHeight(sizing)

        // Update the layer's drawable size if the frame resolution changed.
        let drawableSize = CGSize(width: width, height: height)
        geometryLock.lock()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if metalLayer.drawableSize != drawableSize {
            metalLayer.drawableSize = drawableSize
        }
        CATransaction.commit()
        geometryLock.unlock()

        guard let drawable = metalLayer.nextDrawable() else { return }
        lock.lock()
        guard let pb = pendingBuffer else {
            lock.unlock()
            return
        }
        pendingBuffer = nil
        let timestampUs = pendingTimestampUs
        lock.unlock()

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
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return
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
        submitted = true
        commandBuffer.commit()
    }
}
