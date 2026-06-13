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
    /// XOR parity packet (RFC-0008 FEC): `fragmentIdx` is the parity
    /// group index; payload = 2 length bytes + XOR of the group's
    /// payloads. One recoverable loss per group of 16.
    public var isFECParity: Bool { flags & 0x20 != 0 }

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
        var parity: [UInt16: Data]    // FEC group → parity payload
        var totalFragments: Int?       // set when LAST_FRAGMENT arrives
        var isKeyframe: Bool
        var timestampUs: UInt64
    }

    private static let fecGroupSize = 16

    private var pending: [UInt16: PendingFrame] = [:] // frame_id → fragments
    private var latestFrameId: UInt16 = 0
    /// Frame id of the most recently delivered frame. Late stragglers,
    /// duplicates, and (critically) the trailing FEC parity of a frame
    /// that already completed are ignored against this — without it,
    /// trailing parity fabricates phantom pending entries that read as
    /// loss and trigger spurious keyframe requests at zero actual loss.
    private var lastDelivered: UInt16?

    /// Incomplete frames superseded by a delivered newer frame — i.e.
    /// frames actually lost to the network. Drives keyframe re-requests.
    public private(set) var discarded: UInt64 = 0
    /// Data fragments reconstructed from FEC parity.
    public private(set) var recovered: UInt64 = 0
    /// Complete frames delivered. With `discarded`, gives a true frame
    /// loss ratio for QualityFeedback.
    public private(set) var delivered: UInt64 = 0

    /// `true` if `a` is strictly newer than `b` in wrapping u16 space.
    private static func newer(_ a: UInt16, _ b: UInt16) -> Bool {
        a != b && (a &- b) < 0x8000
    }

    public struct ReassembledFrame {
        public let data: Data       // complete Annex-B byte stream
        public let isKeyframe: Bool
        public let timestampUs: UInt64
    }

    /// When true, the next call to `push()` clears all state first.
    /// Set from any thread; checked inside `push()` which is always
    /// called from the receive queue.
    public var needsReset = false

    public init() {}

    /// Mark the reassembler for reset. The actual clear happens on the
    /// next `push()` call (same thread as the receive loop).
    public func reset() {
        needsReset = true
    }

    /// Push one datagram (header + payload). Returns a complete frame
    /// when the last fragment of a frame arrives.
    public func push(_ datagram: Data) -> ReassembledFrame? {
        if needsReset {
            pending.removeAll()
            latestFrameId = 0
            lastDelivered = nil
            needsReset = false
        }
        guard let header = VideoPacketHeader.decode(datagram) else { return nil }
        let payloadStart = datagram.startIndex + VideoPacketHeader.headerLength
        let payloadEnd = payloadStart + Int(header.payloadLen)
        guard payloadEnd <= datagram.endIndex else { return nil }
        let payload = datagram[payloadStart..<payloadEnd]

        let fid = header.frameId
        let fidx = header.fragmentIdx

        // Ignore datagrams at or before the last delivered frame:
        // duplicates, reordered stragglers, and the trailing FEC parity
        // of a frame that already completed. A keyframe *data* fragment
        // of a strictly older frame means the sender's counter reset —
        // resync.
        if let last = lastDelivered, !Self.newer(fid, last) {
            let isResync = header.isKeyframe && !header.isFECParity && fid != last
            guard isResync else { return nil }
            pending.removeAll()
            lastDelivered = nil
        }

        // Track the latest frame_id seen.
        if fid &- latestFrameId < 0x8000 { // fid is ahead
            latestFrameId = fid
        }
        // Memory bound: evict (without counting — loss accounting
        // happens on delivery below) anything absurdly far behind.
        if pending.count > 8 {
            pending = pending.filter { key, _ in
                latestFrameId &- key < 32
            }
        }

        var frame = pending[fid] ?? PendingFrame(
            fragments: [:],
            parity: [:],
            totalFragments: nil,
            isKeyframe: header.isKeyframe,
            timestampUs: header.timestampUs
        )
        if header.isKeyframe { frame.isKeyframe = true }

        if header.isFECParity {
            // fragmentIdx is the FEC group index for parity packets.
            if frame.parity[fidx] == nil {
                frame.parity[fidx] = Data(payload)
            }
            tryRecover(frame: &frame, group: Int(fidx))
        } else {
            // Int math: `fidx + 1` in UInt16 traps on a crafted 0xFFFF.
            let idx = Int(fidx)
            if let total = frame.totalFragments, idx >= total {
                // Bogus index past the announced total — discard, or it
                // would satisfy the completion count with a hole.
                pending[fid] = frame
                return nil
            }
            frame.fragments[fidx] = Data(payload)
            if header.isLastFragment, frame.totalFragments == nil {
                frame.totalFragments = idx + 1
                // Drop any out-of-range fragments that arrived earlier.
                frame.fragments = frame.fragments.filter { Int($0.key) <= idx }
                // Group bounds just became knowable — sweep all groups.
                for group in frame.parity.keys {
                    tryRecover(frame: &frame, group: Int(group))
                }
            } else {
                tryRecover(frame: &frame, group: idx / Self.fecGroupSize)
            }
        }

        // Check if all fragments have arrived.
        if let total = frame.totalFragments, frame.fragments.count == total {
            pending.removeValue(forKey: fid)
            // Concatenate in fragment-index order; abandon on any hole
            // (count satisfied by a bogus index would corrupt the
            // decoder otherwise).
            var assembled = Data()
            for i in 0..<total {
                guard let frag = frame.fragments[UInt16(i)] else { return nil }
                assembled.append(frag)
            }

            // Loss accounting at delivery time (~1 frame period, not
            // the old ~10 s eviction lag): any pending frame older than
            // the one we're delivering was superseded — lost.
            let stale = pending.keys.filter { Self.newer(fid, $0) }
            for key in stale {
                pending.removeValue(forKey: key)
                discarded &+= 1
            }
            lastDelivered = fid
            delivered &+= 1

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

    /// XOR-recover a single missing data fragment in `group`, if its
    /// parity is present and the frame's total fragment count is known
    /// (group bounds depend on it).
    private func tryRecover(frame: inout PendingFrame, group: Int) {
        guard let total = frame.totalFragments,
              let parity = frame.parity[UInt16(clamping: group)],
              parity.count >= 2 else { return }
        let start = group * Self.fecGroupSize
        guard start >= 0, start < total else { return }
        let end = min(start + Self.fecGroupSize, total)

        var missing: Int?
        for idx in start..<end where frame.fragments[UInt16(idx)] == nil {
            if missing != nil { return } // >1 loss — unrecoverable
            missing = idx
        }
        guard let missingIdx = missing else { return }

        var len = UInt16(parity[parity.startIndex]) << 8
                | UInt16(parity[parity.startIndex + 1])
        var data = [UInt8](parity.dropFirst(2))
        for idx in start..<end where idx != missingIdx {
            guard let p = frame.fragments[UInt16(idx)] else { return }
            len ^= UInt16(p.count)
            for (i, b) in p.enumerated() where i < data.count {
                data[i] ^= b
            }
        }
        guard Int(len) <= data.count else { return } // inconsistent parity
        frame.fragments[UInt16(missingIdx)] = Data(data.prefix(Int(len)))
        recovered &+= 1
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
