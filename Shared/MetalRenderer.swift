// MetalRenderer.swift — render decoded CVPixelBuffers to a CAMetalLayer.
//
// Presentation uses:
//   - CAMetalLayer with maximumDrawableCount = 2 (third drawable costs
//     a full frame of latency)
//   - present on decode from a serial render queue, without a main-thread
//     display-link tick before the compositor's own vsync
//
// The input is a CVPixelBuffer (NV12, BT.709 limited range) from the
// VTDecompressionSession. Its two planes are sampled as Metal textures
// and converted to RGB in a fragment shader while drawing the drawable.

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
    private let pipeline: MTLRenderPipelineState
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

        // Compiled from source: a few ms once, and no .metal file to keep
        // registered in both Xcode projects.
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertex = library.makeFunction(name: "fullscreen_vertex"),
              let fragment = library.makeFunction(name: "nv12_fragment") else {
            return nil
        }
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        self.pipeline = pipeline

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
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
    }

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

        guard let luma = texture(pb, plane: 0, format: .r8Unorm),
              let chroma = texture(pb, plane: 1, format: .rg8Unorm),
              let lumaTexture = CVMetalTextureGetTexture(luma),
              let chromaTexture = CVMetalTextureGetTexture(chroma) else {
            return
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(lumaTexture, index: 0)
        encoder.setFragmentTexture(chromaTexture, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        // Metal retains its texture, but not the CVMetalTexture wrapper
        // or pixel buffer. Keep them alive until the draw has finished.
        let slots = inFlight
        let cache = textureCache
        commandBuffer.addCompletedHandler { [pb, luma, chroma] _ in
            withExtendedLifetime((pb, luma, chroma)) {
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

    private func texture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pb,
            nil,
            format,
            CVPixelBufferGetWidthOfPlane(pb, plane),
            CVPixelBufferGetHeightOfPlane(pb, plane),
            plane,
            &texture
        )
        return status == kCVReturnSuccess ? texture : nil
    }

    /// One triangle covering the drawable; BT.709 limited range → RGB,
    /// matching the host encoder's VUI (flux-codec hevc.rs).
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Varyings { float4 position [[position]]; float2 uv; };

    vertex Varyings fullscreen_vertex(uint id [[vertex_id]]) {
        float2 uv = float2((id << 1) & 2, id & 2);
        Varyings out;
        out.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
        out.uv = uv;
        return out;
    }

    fragment half4 nv12_fragment(Varyings in [[stage_in]],
                                 texture2d<half> luma [[texture(0)]],
                                 texture2d<half> chroma [[texture(1)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        half y = (luma.sample(s, in.uv).r - 16.0h / 255.0h) * (255.0h / 219.0h);
        half2 c = (chroma.sample(s, in.uv).rg - 128.0h / 255.0h) * (255.0h / 224.0h);
        half3 rgb = half3(y + 1.5748h * c.y,
                          y - 0.1873h * c.x - 0.4681h * c.y,
                          y + 1.8556h * c.x);
        return half4(saturate(rgb), 1.0h);
    }
    """
}
