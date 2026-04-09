// FrameReassembler.swift — RFC-0008 wire header parsing + fragment reassembly.
//
// Swift port of flux-protocol's VideoPacketHeader + Reassembler. Pure
// data structures, no platform deps. The 19-byte header layout is:
//
//   type (1B) | sequence (4B, BE) | timestamp_us (8B, BE) | flags (2B, BE) | payload_len (4B, BE)
//
// `sequence` packs frame_id (high 16) + fragment_idx (low 16).
// Flags: KEYFRAME = 0x01, LAST_FRAGMENT = 0x10.

import Foundation

public struct VideoPacketHeader {
    public let packetType: UInt8
    public let sequence: UInt32
    public let timestampUs: UInt64
    public let flags: UInt16
    public let payloadLen: UInt32

    public var frameId: UInt16 { UInt16(sequence >> 16) }
    public var fragmentIdx: UInt16 { UInt16(sequence & 0xFFFF) }
    public var isKeyframe: Bool { flags & 0x01 != 0 }
    public var isLastFragment: Bool { flags & 0x10 != 0 }

    public static let headerLength = 19

    public static func decode(_ data: Data) -> VideoPacketHeader? {
        guard data.count >= headerLength else { return nil }
        let type = data[data.startIndex]
        guard type == 1 else { return nil } // type 1 = video frame fragment
        let seq = data.readBE32(at: 1)
        let ts  = data.readBE64(at: 5)
        let fl  = data.readBE16(at: 13)
        let pl  = data.readBE32(at: 15)
        return VideoPacketHeader(packetType: type, sequence: seq, timestampUs: ts, flags: fl, payloadLen: pl)
    }
}

/// Reassembles fragmented video frames from a stream of datagrams.
/// Each frame is identified by its `frame_id` (high 16 of sequence).
/// Fragments are collected until the one with `LAST_FRAGMENT` arrives,
/// then concatenated in order and returned as a single Annex-B byte
/// stream.
public final class FrameReassembler {
    private struct PendingFrame {
        var fragments: [UInt16: Data] // fragment_idx → payload
        var totalFragments: UInt16?    // set when LAST_FRAGMENT arrives
        var isKeyframe: Bool
        var timestampUs: UInt64
    }

    private var pending: [UInt16: PendingFrame] = [:] // frame_id → fragments

    public struct ReassembledFrame {
        public let data: Data       // complete Annex-B byte stream
        public let isKeyframe: Bool
        public let timestampUs: UInt64
    }

    public init() {}

    /// Push one datagram (header + payload). Returns a complete frame
    /// when the last fragment of a frame arrives.
    public func push(_ datagram: Data) -> ReassembledFrame? {
        guard let header = VideoPacketHeader.decode(datagram) else { return nil }
        let payloadStart = datagram.startIndex + VideoPacketHeader.headerLength
        let payloadEnd = payloadStart + Int(header.payloadLen)
        guard payloadEnd <= datagram.endIndex else { return nil }
        let payload = datagram[payloadStart..<payloadEnd]

        let fid = header.frameId
        let fidx = header.fragmentIdx

        var frame = pending[fid] ?? PendingFrame(
            fragments: [:],
            totalFragments: nil,
            isKeyframe: header.isKeyframe,
            timestampUs: header.timestampUs
        )
        frame.fragments[fidx] = Data(payload)
        if header.isKeyframe { frame.isKeyframe = true }
        if header.isLastFragment {
            frame.totalFragments = fidx + 1
        }

        // Check if all fragments have arrived.
        if let total = frame.totalFragments, frame.fragments.count == Int(total) {
            pending.removeValue(forKey: fid)
            // Concatenate in fragment-index order.
            var assembled = Data()
            for i in 0..<total {
                if let frag = frame.fragments[i] {
                    assembled.append(frag)
                }
            }
            return ReassembledFrame(
                data: assembled,
                isKeyframe: frame.isKeyframe,
                timestampUs: frame.timestampUs
            )
        } else {
            pending[fid] = frame
            return nil
        }
    }
}

// MARK: - Data helpers for big-endian reads

private extension Data {
    func readBE16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) << 8 | UInt16(self[i+1])
    }
    func readBE32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i+1]) << 16 | UInt32(self[i+2]) << 8 | UInt32(self[i+3])
    }
    func readBE64(at offset: Int) -> UInt64 {
        let i = startIndex + offset
        var val: UInt64 = 0
        for j in 0..<8 { val = val << 8 | UInt64(self[i+j]) }
        return val
    }
}
