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

    /// Called on the decode thread with each decoded pixel buffer.
    public var onDecodedFrame: ((CVPixelBuffer, UInt64) -> Void)?

    public init() {}

    deinit {
        if let s = session {
            VTDecompressionSessionInvalidate(s)
        }
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

        // If we got new parameter sets, (re)create the format description
        // and decompression session.
        if !paramSets.isEmpty {
            try configureSession(paramSets: paramSets)
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

        // Build the format description from VPS/SPS/PPS.
        let pointers = paramSets.map { Array($0) }
        var sizes = pointers.map { $0.count }
        let ptrs = pointers.map { $0.withUnsafeBufferPointer { $0.baseAddress! } }

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
        // Wrap in CMBlockBuffer.
        var blockBuffer: CMBlockBuffer?
        let avccBytes = Array(avcc)
        avccBytes.withUnsafeBufferPointer { buf in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: UnsafeMutableRawPointer(mutating: buf.baseAddress!),
                blockLength: buf.count,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: buf.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        guard let blockBuffer = blockBuffer else { return }

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
