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

import CoreMedia
import VideoToolbox
import CoreVideo

public final class HEVCDecoder {
    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?

    /// When true, discard all input until fresh VPS/SPS/PPS arrive.
    /// Set by `reset()`, cleared by `configureSession()`.
    private var waitingForKeyframe = false

    /// Concatenated VPS/SPS/PPS bytes of the live session. Hosts attach
    /// param sets to every keyframe; rebuilding the session each time
    /// cost a multi-ms stall per keyframe for nothing.
    private var currentParamSets = Data()

    /// Called on the decode thread with each decoded pixel buffer.
    public var onDecodedFrame: ((CVPixelBuffer, UInt64) -> Void)?

    public init() {}

    deinit {
        if let s = session {
            VTDecompressionSessionInvalidate(s)
        }
    }

    /// Tear down the current session and discard all input until a
    /// fresh keyframe with VPS/SPS/PPS arrives. Call this when the
    /// capture source changes (display switch).
    public func reset() {
        if let s = session {
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
        formatDesc = nil
        currentParamSets = Data()
        waitingForKeyframe = true
    }

    /// Decode one Annex-B access unit. The first call must be a
    /// keyframe containing VPS/SPS/PPS.
    public func decode(annexB: Data, timestampUs: UInt64) throws {
        let nalUnits = parseAnnexB(annexB)
        if nalUnits.isEmpty { return }

        // Extract parameter sets (VPS=32, SPS=33, PPS=34) and slice NALs.
        var paramSets: [Data] = []
        var sliceNALs: [Data] = []
        for nal in nalUnits {
            guard !nal.isEmpty else { continue }
            let nalType = (nal[nal.startIndex] >> 1) & 0x3F
            switch nalType {
            case 32, 33, 34: // VPS, SPS, PPS
                paramSets.append(nal)
            default:
                sliceNALs.append(nal)
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

        // Convert each slice NAL from Annex-B to AVCC (4-byte length prefix)
        // and wrap in a CMSampleBuffer for VT.
        for nal in sliceNALs {
            let avcc = avccFromNAL(nal)
            try decodeAVCC(avcc, session: session, timestampUs: timestampUs)
        }
    }

    // MARK: - Session management

    private func configureSession(paramSets: [Data]) throws {
        // Tear down any existing session.
        if let s = session {
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
        session = newSession
    }

    // MARK: - Decode one NAL

    private func decodeAVCC(_ avcc: Data, session: VTDecompressionSession, timestampUs: UInt64) throws {
        // Wrap in a CMBlockBuffer that owns its own memory and copy the
        // NAL bytes in. (Pointing the block buffer at Swift-managed
        // memory with kCFAllocatorNull is use-after-scope UB once the
        // pointer closure returns — it only ever worked here because
        // the decode below is synchronous.)
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
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
        guard let blockBuffer = blockBuffer else { return }
        let copyStatus = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard copyStatus == noErr else { return }

        // Wrap in CMSampleBuffer.
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avcc.count
        CMSampleBufferCreateReady(
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
        guard let sampleBuffer = sampleBuffer else { return }

        // Decode synchronously — don't allow async queueing, which can
        // cause decoded CVPixelBuffers to pile up and blow memory.
        var flagsOut: VTDecodeInfoFlags = []
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._1xRealTimePlayback],
            infoFlagsOut: &flagsOut,
            outputHandler: { [weak self] status, _, pixelBuffer, _, _ in
                guard status == noErr, let pb = pixelBuffer else { return }
                self?.onDecodedFrame?(pb, timestampUs)
            }
        )
        if decodeStatus != noErr {
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
        case decodeFailed(OSStatus)
    }
}
