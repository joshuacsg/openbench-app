// VideoDecoder.swift — HEVC hardware decode via VTDecompressionSession.
//
// Swift port of the decode path from flux-codec/src/hevc_decoder.rs.
// Uses the iPad/Mac's native VideoToolbox — same hardware, no FFI
// overhead. The handoff doc explicitly says: "Do NOT decode HEVC via
// the Rust FFI. Use Swift's own VTDecompressionSession."
//
// Input:  Annex-B byte stream (0x00 0x00 0x00 0x01 start codes)
// Output: CVPixelBuffer (BGRA or NV12, hardware decides)
//
// The first call must include a keyframe with VPS/SPS/PPS so the
// decoder can construct its CMVideoFormatDescription. Subsequent
// delta frames reference the stored parameter sets.

import Foundation
import CoreMedia
import VideoToolbox
import CoreVideo

public final class HEVCDecoder {
    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private let sessionLock = NSLock()
    private let inFlight = DispatchSemaphore(value: 2)
    // The callback state outlives teardown without retaining the decoder.
    private final class OutputState {
        let lock = NSLock()
        let callbackLock = NSLock()
        var needsKeyframe = false
        var lastDeliveredSequence: UInt64 = 0
        var keyframeSequence: UInt64 = 0
        var handler: ((CVPixelBuffer, UInt64) -> Void)?
    }
    private let output = OutputState()
    private var nextSequence: UInt64 = 0

    /// When true, discard all input until fresh VPS/SPS/PPS arrive.
    /// Set by `reset()`, cleared by `configureSession()`.
    private var waitingForKeyframe = false

    /// Concatenated VPS/SPS/PPS bytes of the live session. Hosts attach
    /// param sets to every keyframe; rebuilding the session each time
    /// cost a multi-ms stall per keyframe for nothing.
    private var currentParamSets = Data()

    /// Called serially from VT's output callbacks with each decoded buffer.
    public var onDecodedFrame: ((CVPixelBuffer, UInt64) -> Void)? {
        get {
            output.lock.lock()
            defer { output.lock.unlock() }
            return output.handler
        }
        set {
            output.lock.lock()
            output.handler = newValue
            output.lock.unlock()
        }
    }

    public init() {}

    deinit {
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
    }

    /// Tear down the current session and discard all input until a
    /// fresh keyframe with VPS/SPS/PPS arrives. Call this when the
    /// capture source changes (display switch).
    public func reset() {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        // Preserve the 2026-09-26 reset-race fix with async decode too:
        // drain callbacks before invalidating, so old-display output cannot
        // arrive after reset returns. Callbacks never take sessionLock.
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
        output.lock.lock()
        output.needsKeyframe = false
        output.lastDeliveredSequence = 0
        output.keyframeSequence = 0
        output.lock.unlock()
        nextSequence = 0
        session = nil
        formatDesc = nil
        currentParamSets = Data()
        waitingForKeyframe = true
    }

    /// Decode one Annex-B access unit. The first call must be a
    /// keyframe containing VPS/SPS/PPS.
    public func decode(annexB: Data, timestampUs: UInt64) throws {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        let nalUnits = parseAnnexB(annexB)
        if nalUnits.isEmpty { return }

        // Extract parameter sets (VPS=32, SPS=33, PPS=34) and slice NALs.
        var paramSets: [Data] = []
        var sliceNALs: [Data] = []
        var isKeyframe = false
        for nal in nalUnits {
            guard !nal.isEmpty else { continue }
            let nalType = (nal[nal.startIndex] >> 1) & 0x3F
            switch nalType {
            case 32, 33, 34: // VPS, SPS, PPS
                paramSets.append(nal)
            case 0...31: // VCL; AUD/SEI are not separate pictures.
                sliceNALs.append(nal)
                if (16...23).contains(nalType) { isKeyframe = true }
            default:
                break
            }
        }

        // After a reset, discard everything until we see fresh parameter
        // sets (VPS/SPS/PPS) which arrive with the first keyframe from
        // the new display.
        if waitingForKeyframe && paramSets.isEmpty {
            return
        }

        // If we got new parameter sets, (re)create the format description
        // and decompression session — but only when they actually
        // changed (every keyframe carries them).
        if !paramSets.isEmpty {
            var concat = Data()
            for ps in paramSets { concat.append(ps) }
            if concat != currentParamSets || session == nil {
                try configureSession(paramSets: paramSets)
                currentParamSets = concat
            } else {
                waitingForKeyframe = false
            }
        }

        guard let session = session, let _ = formatDesc else {
            // No session yet and no parameter sets → can't decode.
            return
        }

        guard !sliceNALs.isEmpty else { return }
        output.lock.lock()
        let recoveryRequired = output.needsKeyframe
        output.lock.unlock()
        if recoveryRequired && !isKeyframe {
            throw DecoderError.waitingForRecoveryKeyframe
        }

        // One access unit is one sample, including every slice in order.
        var avcc = Data(capacity: sliceNALs.reduce(0) { $0 + 4 + $1.count })
        for nal in sliceNALs { avcc.append(avccFromNAL(nal)) }
        do {
            try decodeAVCC(avcc, session: session, timestampUs: timestampUs, isKeyframe: isKeyframe)
        } catch {
            output.lock.lock()
            output.needsKeyframe = true
            output.lock.unlock()
            throw error
        }
    }

    // MARK: - Session management

    private func configureSession(paramSets: [Data]) throws {
        // Tear down any existing session.
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
            session = nil
        }

        // Build the format description from VPS/SPS/PPS. The param-set
        // bytes are copied into manually allocated buffers that stay
        // alive for the whole call — capturing `baseAddress` out of a
        // `withUnsafeBufferPointer` closure (the previous code) is
        // use-after-scope UB that only ever worked by allocation luck,
        // and it broke deterministically in Release builds: every
        // format-description create failed with -12712 and the viewer
        // decoded nothing.
        let buffers: [UnsafeMutableBufferPointer<UInt8>] = paramSets.map { ps in
            let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: ps.count)
            _ = buf.initialize(from: ps)
            return buf
        }
        defer { buffers.forEach { $0.deallocate() } }
        let ptrs: [UnsafePointer<UInt8>] = buffers.map { UnsafePointer($0.baseAddress!) }
        var sizes = buffers.map { $0.count }

        var desc: CMVideoFormatDescription?
        let status = ptrs.withUnsafeBufferPointer { ptrsBuf in
            sizes.withUnsafeMutableBufferPointer { sizesBuf in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: paramSets.count,
                    parameterSetPointers: ptrsBuf.baseAddress!,
                    parameterSetSizes: sizesBuf.baseAddress!,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &desc
                )
            }
        }
        guard status == noErr, let desc = desc else {
            throw DecoderError.formatDescriptionFailed(status)
        }
        formatDesc = desc
        waitingForKeyframe = false

        // Create a new decompression session.
        let outputAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var newSession: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: desc,
            decoderSpecification: nil,
            imageBufferAttributes: outputAttrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        guard sessionStatus == noErr, let newSession = newSession else {
            throw DecoderError.sessionCreateFailed(sessionStatus)
        }
        let realTimeStatus = VTSessionSetProperty(
            newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue
        )
        guard realTimeStatus == noErr else {
            VTDecompressionSessionInvalidate(newSession)
            throw DecoderError.sessionPropertyFailed(realTimeStatus)
        }
        session = newSession
    }

    // MARK: - Decode one access unit

    private func decodeAVCC(_ avcc: Data, session: VTDecompressionSession,
                            timestampUs: UInt64, isKeyframe: Bool) throws {
        // Wrap in a CMBlockBuffer that owns its own memory and copy the
        // access-unit bytes in; VT can keep this buffer after submission.
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == noErr, let blockBuffer = blockBuffer else {
            throw DecoderError.sampleBufferFailed(blockStatus)
        }
        let copyStatus = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard copyStatus == noErr else { throw DecoderError.sampleBufferFailed(copyStatus) }

        // Wrap in CMSampleBuffer.
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avcc.count
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer = sampleBuffer else {
            throw DecoderError.sampleBufferFailed(sampleStatus)
        }

        // Keep at most two access units in flight. A saturated decoder gets
        // 5 ms to catch up; report rejected deltas through the existing throws
        // path and suppress their dependent chain until an IRAP arrives.
        // Keyframes always wait for a slot rather than being dropped.
        if inFlight.wait(timeout: .now() + .milliseconds(5)) == .timedOut {
            if isKeyframe {
                inFlight.wait()
            } else {
                throw DecoderError.backpressure
            }
        }
        let slots = inFlight
        let output = output
        nextSequence += 1
        let sequence = nextSequence
        if isKeyframe {
            output.lock.lock()
            output.keyframeSequence = sequence
            output.needsKeyframe = false
            output.lock.unlock()
        }
        var flagsOut: VTDecodeInfoFlags = []
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &flagsOut,
            outputHandler: { status, info, pixelBuffer, _, _ in
                defer { slots.signal() }
                // Serialize the consumer without holding the state lock:
                // slow thumbnail work must not block the next submission.
                output.callbackLock.lock()
                defer { output.callbackLock.unlock() }
                output.lock.lock()
                guard status == noErr, !info.contains(.frameDropped), let pb = pixelBuffer else {
                    if sequence >= output.keyframeSequence { output.needsKeyframe = true }
                    output.lock.unlock()
                    print("[HEVCDecoder] async decode failed: status=\(status), flags=\(info.rawValue)")
                    return
                }
                guard sequence > output.lastDeliveredSequence else {
                    output.lock.unlock()
                    print("[HEVCDecoder] superseded out-of-order output: \(sequence)")
                    return
                }
                output.lastDeliveredSequence = sequence
                let handler = output.handler
                output.lock.unlock()
                handler?(pb, timestampUs)
            }
        )
        if decodeStatus != noErr {
            // VT does not call the output handler on a submission error.
            slots.signal()
            throw DecoderError.decodeFailed(decodeStatus)
        }
    }

    // MARK: - Annex-B parsing

    /// Split an Annex-B byte stream on start codes (0x00 0x00 0x00 0x01
    /// or 0x00 0x00 0x01) and return individual NAL unit bodies.
    private func parseAnnexB(_ data: Data) -> [Data] {
        var nals: [Data] = []
        var i = data.startIndex
        let end = data.endIndex

        func findStartCode(from: Int) -> (Int, Int)? { // (position, scLen)
            var j = from
            while j + 2 < end {
                if data[j] == 0 && data[j+1] == 0 {
                    if data[j+2] == 1 { return (j, 3) }
                    if j + 3 < end && data[j+2] == 0 && data[j+3] == 1 { return (j, 4) }
                }
                j += 1
            }
            return nil
        }

        guard let (firstSC, firstLen) = findStartCode(from: i) else { return [] }
        i = firstSC + firstLen

        while let (nextSC, nextLen) = findStartCode(from: i) {
            if nextSC > i { nals.append(data[i..<nextSC]) }
            i = nextSC + nextLen
        }
        if i < end { nals.append(data[i..<end]) }
        return nals
    }

    /// Convert one NAL unit body to AVCC format (4-byte big-endian
    /// length prefix + NAL body).
    private func avccFromNAL(_ nal: Data) -> Data {
        var avcc = Data(capacity: 4 + nal.count)
        var len = UInt32(nal.count).bigEndian
        avcc.append(Data(bytes: &len, count: 4))
        avcc.append(nal)
        return avcc
    }

    enum DecoderError: Error {
        case formatDescriptionFailed(OSStatus)
        case sessionCreateFailed(OSStatus)
        case sessionPropertyFailed(OSStatus)
        case sampleBufferFailed(OSStatus)
        case decodeFailed(OSStatus)
        case backpressure
        case waitingForRecoveryKeyframe
    }
}
