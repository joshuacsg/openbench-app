// MetalRenderer.swift — render decoded CVPixelBuffers to a CAMetalLayer.
//
// The handoff doc specifies:
//   - CAMetalLayer with maximumDrawableCount = 2 (third drawable costs
//     a full frame of latency)
//   - presentAtTime: ~1 ms before vsync driven by CADisplayLink at
//     120 Hz (ProMotion)
//
// The input is a CVPixelBuffer (BGRA) from the VTDecompressionSession.
// We create a Metal texture from it and blit to the drawable.

import Foundation
import Metal
import MetalKit
import CoreVideo
import QuartzCore

#if canImport(UIKit)
import UIKit
#endif

/// A SwiftUI-compatible Metal view that displays decoded video frames.
/// Call `enqueue(_:)` from any thread; the next display refresh picks
/// it up and presents it.
public final class MetalRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    public let metalLayer: CAMetalLayer

    /// The most recently /Users/joshuachua/Documents/GitHub/openbench-app/Sharedenqueued pixel buffer, waiting for the next
    /// display refresh to present.
    private var pendingBuffer: CVPixelBuffer?
    private let lock = NSLock()

    #if canImport(UIKit)
    private var displayLink: CADisplayLink?
    #endif

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
        #if os(macOS)
        layer.displaySyncEnabled = true
        #endif
        self.metalLayer = layer
    }

    /// Enqueue a decoded frame for presentation on the next vsync.
    /// Thread-safe; called from the decode callback.
    public func enqueue(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        pendingBuffer = pixelBuffer
        lock.unlock()
    }

    /// Drive presentation from a display link or timer. Call this once
    /// per vsync to pick up the latest enqueued frame and blit it to
    /// the drawable.
    public func presentIfNeeded() {
        lock.lock()
        let pb = pendingBuffer
        pendingBuffer = nil
        lock.unlock()

        guard let pb = pb else { return }

        let width = CVPixelBufferGetWidth(pb)
        let height = CVPixelBufferGetHeight(pb)

        // Update the layer's drawable size if the frame resolution changed.
        let drawableSize = CGSize(width: width, height: height)
        if metalLayer.drawableSize != drawableSize {
            metalLayer.drawableSize = drawableSize
        }

        // Create a Metal texture from the CVPixelBuffer.
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pb,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture = cvTexture,
              let sourceTexture = CVMetalTextureGetTexture(cvTexture) else {
            return
        }

        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
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
        commandBuffer.present(drawable)
        commandBuffer.commit()

        // Flush stale entries from the texture cache so CVPixelBuffer
        // backing memory can be reclaimed. Without this the cache grows
        // unbounded and the OS kills the app for memory pressure.
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    #if canImport(UIKit)
    /// Start a CADisplayLink that drives presentation at the display's
    /// native refresh rate (120 Hz on ProMotion iPads).
    public func startDisplayLink() {
        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30,
            maximum: 120,
            preferred: 120
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    public func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        presentIfNeeded()
    }
    #endif
}
