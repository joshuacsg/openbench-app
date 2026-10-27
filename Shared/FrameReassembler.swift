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
    /// Final-group parity (negotiated): payload is prefixed with the
    /// frame's total data-fragment count (BE u16) before the parity.
    public var isLastGroup: Bool { isFECParity && flags & 0x40 != 0 }

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
    private final class PendingFrame {
        var fragments: [UInt16: Data] = [:] // fragment_idx → payload
        var parity: [UInt16: Data] = [:]    // FEC group → parity payload
        var totalFragments: Int?
        var receivedFragments = 0
        var isKeyframe: Bool
        let timestampUs: UInt64
        let firstSeen: TimeInterval

        init(header: VideoPacketHeader, now: TimeInterval) {
            isKeyframe = header.isKeyframe
            timestampUs = header.timestampUs
            firstSeen = now
            fragments.reserveCapacity(32)
            parity.reserveCapacity(4)
        }
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
    // Includes expired frames so late fragments cannot resurrect a loss
    // or make the next delivery count that same gap twice.
    private var lastRetired: UInt16?
    private var lastVideoTraffic: TimeInterval = 0

    /// Missing frame ids and incomplete frames superseded or expired.
    /// Drives keyframe re-requests and post-FEC frame-loss feedback.
    public private(set) var discarded: UInt64 = 0
    /// Data fragments reconstructed from FEC parity.
    public private(set) var recovered: UInt64 = 0
    /// Complete frames delivered. With `discarded`, gives a true frame
    /// loss ratio for QualityFeedback.
    public private(set) var delivered: UInt64 = 0
    /// Settled data fragments, including those missing before FEC.
    /// Unknown-size lost frames contribute a lower bound (at least one).
    public private(set) var totalDataFragments: UInt64 = 0
    public private(set) var lostDataFragments: UInt64 = 0

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

    private func applyResetIfNeeded() {
        if needsReset {
            pending.removeAll()
            latestFrameId = 0
            lastDelivered = nil
            lastRetired = nil
            lastVideoTraffic = 0
            needsReset = false
        }
    }

    /// Push one datagram; return a complete frame after data or parity
    /// supplies its last missing fragment. `now` uses a monotonic clock.
    public func push(_ datagram: Data, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> ReassembledFrame? {
        applyResetIfNeeded()
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
        if let last = lastRetired, !Self.newer(fid, last) {
            let isResync = header.isKeyframe && !header.isFECParity
                && fid != last && fid != lastDelivered
            guard isResync else { return nil }
            pending.removeAll()
            lastDelivered = nil
            lastRetired = nil
        }
        lastVideoTraffic = now

        // Track the latest frame_id seen.
        if fid &- latestFrameId < 0x8000 { // fid is ahead
            latestFrameId = fid
        }
        // Reference storage avoids copying both dictionaries for every
        // fragment while the pending table still owns the frame.
        let frame: PendingFrame
        if let existing = pending[fid] {
            frame = existing
        } else {
            frame = PendingFrame(header: header, now: now)
            pending[fid] = frame
        }
        if header.isKeyframe { frame.isKeyframe = true }

        if header.isFECParity {
            // fragmentIdx is the FEC group index for parity packets.
            var parityPayload = Data(payload)
            var learnedTotal = false
            if header.isLastGroup {
                // The final group's parity names the frame's fragment
                // count, so a lost LAST_FRAGMENT is still repairable —
                // and never guessed from what happened to arrive so far.
                guard parityPayload.count >= 2 else { return nil }
                let total = Int(parityPayload.readBE16(at: 0))
                parityPayload = Data(parityPayload.dropFirst(2))
                if total > 0, frame.totalFragments == nil {
                    frame.totalFragments = total
                    frame.fragments = frame.fragments.filter { Int($0.key) < total }
                    frame.receivedFragments = frame.fragments.count
                    learnedTotal = true
                }
            }
            if frame.parity[fidx] == nil {
                frame.parity[fidx] = parityPayload
            }
            if learnedTotal {
                for group in frame.parity.keys {
                    tryRecover(frame: frame, group: Int(group))
                }
            } else {
                tryRecover(frame: frame, group: Int(fidx))
            }
        } else {
            // Int math: `fidx + 1` in UInt16 traps on a crafted 0xFFFF.
            let idx = Int(fidx)
            if let total = frame.totalFragments, idx >= total {
                // Bogus index past the announced total — discard, or it
                // would satisfy the completion count with a hole.
                return nil
            }
            if frame.fragments[fidx] == nil {
                frame.receivedFragments += 1
                frame.fragments[fidx] = Data(payload)
            }
            if header.isLastFragment, frame.totalFragments == nil {
                frame.totalFragments = idx + 1
                // Drop any out-of-range fragments that arrived earlier.
                frame.fragments = frame.fragments.filter { Int($0.key) <= idx }
                // Group bounds just became knowable — sweep all groups.
                for group in frame.parity.keys {
                    tryRecover(frame: frame, group: Int(group))
                }
            } else {
                tryRecover(frame: frame, group: idx / Self.fecGroupSize)
            }
        }

        // Check if all fragments have arrived.
        if let total = frame.totalFragments, frame.fragments.count == total {
            pending.removeValue(forKey: fid)
            // Concatenate in fragment-index order; abandon on any hole
            // (count satisfied by a bogus index would corrupt the
            // decoder otherwise).
            var assembled = Data()
            assembled.reserveCapacity(frame.fragments.values.reduce(0) { $0 + $1.count })
            for i in 0..<total {
                guard let frag = frame.fragments[UInt16(i)] else { return nil }
                assembled.append(frag)
            }

            // Loss accounting at delivery time (~1 frame period, not
            // the old ~10 s eviction lag): any pending frame older than
            // the one we're delivering was superseded — lost.
            retireLosses(before: fid, countGaps: !frame.isKeyframe)
            lastDelivered = fid
            lastRetired = fid
            delivered &+= 1
            accountFragments(frame, lost: false)

            return ReassembledFrame(
                data: assembled,
                isKeyframe: frame.isKeyframe,
                timestampUs: frame.timestampUs
            )
        } else {
            // Bound incomplete assemblies even during a long loss burst.
            if pending.count > 8,
               let oldest = pending.keys.max(by: { latestFrameId &- $0 < latestFrameId &- $1 }) {
                discardThrough(oldest)
            }
            return nil
        }
    }

    /// XOR-recover a single missing data fragment in `group`, if its
    /// parity is present and the frame's total fragment count is known
    /// (from LAST_FRAGMENT or a LAST_GROUP parity's total).
    private func tryRecover(frame: PendingFrame, group: Int) {
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

    private func accountFragments(_ frame: PendingFrame, lost: Bool) {
        let observedEnd = frame.fragments.keys.max().map { Int($0) + 1 } ?? 0
        let total = frame.totalFragments ?? max(observedEnd, frame.fragments.count + (lost ? 1 : 0))
        totalDataFragments &+= UInt64(total)
        lostDataFragments &+= UInt64(max(0, total - frame.receivedFragments))
    }

    private func retireLosses(before fid: UInt16, countGaps: Bool) {
        let stale = pending.keys.filter { Self.newer(fid, $0) }
        let gap = countGaps ? lastRetired.map { Int(fid &- $0) - 1 } ?? 0 : 0
        let unseen = max(0, gap - stale.count)
        discarded &+= UInt64(stale.count + unseen)
        // No fragment metadata survives a wholly missing frame.
        totalDataFragments &+= UInt64(unseen)
        lostDataFragments &+= UInt64(unseen)
        for key in stale {
            if let frame = pending.removeValue(forKey: key) { accountFragments(frame, lost: true) }
        }
    }

    private func discardThrough(_ fid: UInt16) {
        retireLosses(before: fid, countGaps: true)
        if let frame = pending.removeValue(forKey: fid) {
            discarded &+= 1
            accountFragments(frame, lost: true)
        }
        lastRetired = fid
    }

    /// Video-silence deadline after which an incomplete assembly is
    /// given up on: 2 x RTT, clamped so a 1.7 s RTT spike can't add
    /// seconds of detection time and a LAN RTT keeps the 60 ms floor.
    public static func recoveryTimeout(rttMs: UInt32) -> TimeInterval {
        min(0.25, max(0.06, Double(rttMs) / 500.0))
    }

    /// Called on the receive queue even while the sender is idle. Only
    /// video silence counts: pongs must not keep a broken tail alive.
    public func expireStalledFrames(now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                                    timeout: TimeInterval) {
        applyResetIfNeeded()
        guard now - lastVideoTraffic >= timeout,
              let newest = pending.keys.min(by: { latestFrameId &- $0 < latestFrameId &- $1 }),
              let frame = pending[newest], now - frame.firstSeen >= timeout else { return }
        discardThrough(newest)
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

#if FRAME_REASSEMBLER_TESTS
// Standalone pure-logic suite (no Xcode test target/source registration):
// swiftc -parse-as-library -D FRAME_REASSEMBLER_TESTS Shared/FrameReassembler.swift -o /tmp/frame-reassembler-tests
private struct FrameReassemblerTests {
    private func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                                           file: StaticString = #file, line: UInt = #line) {
        precondition(actual == expected, "\(message): \(actual) != \(expected)", file: file, line: line)
    }

    private func checkNil<T>(_ actual: T?, file: StaticString = #file, line: UInt = #line) {
        precondition(actual == nil, "expected nil", file: file, line: line)
    }

    private func checkNotNil<T>(_ actual: T?, file: StaticString = #file, line: UInt = #line) {
        precondition(actual != nil, "expected a completed frame", file: file, line: line)
    }

    private func packet(_ fid: UInt16, _ idx: UInt16, flags: UInt16 = 0, payload: Data = Data([1])) -> Data {
        var result = Data([1])
        func append(_ value: UInt64, bytes: Int) {
            for shift in stride(from: (bytes - 1) * 8, through: 0, by: -8) {
                result.append(UInt8(truncatingIfNeeded: value >> shift))
            }
        }
        append(UInt64(fid) << 16 | UInt64(idx), bytes: 4)
        append(123, bytes: 8)
        append(UInt64(flags), bytes: 2)
        append(UInt64(payload.count), bytes: 4)
        result.append(payload)
        return result
    }

    /// `total` set = LAST_GROUP parity (prefixed with the fragment count).
    private func parity(_ payloads: [Data], total: Int? = nil) -> Data {
        var length: UInt16 = 0
        var bytes = [UInt8](repeating: 0, count: payloads.map(\.count).max() ?? 0)
        for payload in payloads {
            length ^= UInt16(payload.count)
            for (index, byte) in payload.enumerated() { bytes[index] ^= byte }
        }
        let prefix = total.map { [UInt8($0 >> 8), UInt8(truncatingIfNeeded: $0)] } ?? []
        return Data(prefix + [UInt8(length >> 8), UInt8(truncatingIfNeeded: length)] + bytes)
    }

    func testWholeAndPartialLossDoNotDoubleCount() {
        let r = FrameReassembler()
        checkNotNil(r.push(packet(10, 0, flags: 0x11)))
        checkNil(r.push(packet(11, 0)))
        checkNotNil(r.push(packet(13, 0, flags: 0x10)))
        checkEqual(r.discarded, 2) // partial 11, wholly absent 12
        checkEqual(r.lostDataFragments, 2)
        checkEqual(r.totalDataFragments, 5)
        checkNil(r.push(packet(11, 1, flags: 0x10)))
        checkNotNil(r.push(packet(14, 0, flags: 0x10)))
        checkEqual(r.discarded, 2)
    }

    func testWrappingGapAndKeyframeResync() {
        let r = FrameReassembler()
        checkNotNil(r.push(packet(65534, 0, flags: 0x11)))
        checkNotNil(r.push(packet(1, 0, flags: 0x10)))
        checkEqual(r.discarded, 2) // 65535 and 0
        checkNotNil(r.push(packet(5, 0, flags: 0x11)))
        checkEqual(r.discarded, 2) // keyframe doesn't need prior refs
        checkNotNil(r.push(packet(0, 0, flags: 0x11)))
        checkNotNil(r.push(packet(1, 0, flags: 0x10)))
        checkEqual(r.discarded, 2)
    }

    func testTailExpiryAndLateFragments() {
        let r = FrameReassembler()
        checkNotNil(r.push(packet(10, 0, flags: 0x11), now: 1))
        checkNil(r.push(packet(11, 0), now: 2))
        r.expireStalledFrames(now: 2.05, timeout: 0.06)
        checkEqual(r.discarded, 0)
        r.expireStalledFrames(now: 2.07, timeout: 0.06)
        checkEqual(r.discarded, 1)
        r.expireStalledFrames(now: 3, timeout: 0.06)
        checkNil(r.push(packet(11, 1, flags: 0x10), now: 3))
        checkNotNil(r.push(packet(12, 0, flags: 0x10), now: 3))
        checkEqual(r.discarded, 1)
        checkEqual(r.lostDataFragments, 1)
    }

    func testNewVideoTrafficDefersExpiry() {
        let r = FrameReassembler()
        checkNil(r.push(packet(1, 0), now: 1))
        checkNil(r.push(packet(2, 0), now: 1.05))
        r.expireStalledFrames(now: 1.07, timeout: 0.06)
        checkEqual(r.discarded, 0)
        r.expireStalledFrames(now: 1.12, timeout: 0.06)
        checkEqual(r.discarded, 2)
    }

    func testEverySingleFECFragmentLossIncludingFinalGroup() {
        for count in [1, 2, 3, 16, 17, 31, 32, 33] {
            let payloads = (0..<count).map { Data(repeating: UInt8($0 + 1), count: $0 == count - 1 ? 1 : 3) }
            let expected = payloads.reduce(into: Data()) { $0.append($1) }
            for missing in 0..<count {
                let r = FrameReassembler()
                var completed: FrameReassembler.ReassembledFrame?
                for idx in 0..<count where idx != missing {
                    completed = r.push(packet(1, UInt16(idx), flags: idx == count - 1 ? 0x10 : 0,
                                              payload: payloads[idx])) ?? completed
                }
                let groups = (count + 15) / 16
                for group in 0..<groups {
                    let payload = parity(Array(payloads[(group * 16)..<min(count, (group + 1) * 16)]),
                                         total: group == groups - 1 ? count : nil)
                    completed = r.push(packet(1, UInt16(group), flags: group == groups - 1 ? 0x60 : 0x20,
                                              payload: payload)) ?? completed
                }
                checkEqual(completed?.data, expected, "count=\(count) missing=\(missing)")
                checkEqual(r.recovered, 1)
                checkEqual(r.discarded, 0)
                checkEqual(r.totalDataFragments, UInt64(count))
                checkEqual(r.lostDataFragments, 1)
            }
        }
    }

    func testLastGroupTotalCompletesWithoutLastFragmentMarker() {
        let r = FrameReassembler()
        let payloads = [Data([1, 2, 3]), Data([4, 5, 6]), Data([7, 8, 9])]
        checkNil(r.push(packet(1, 0, payload: payloads[0])))
        checkNil(r.push(packet(1, 2, payload: payloads[2]))) // LAST_FRAGMENT flag lost in transit
        let completed = r.push(packet(1, 0, flags: 0x60, payload: parity(payloads, total: 3)))
        checkEqual(completed?.data, Data([1, 2, 3, 4, 5, 6, 7, 8, 9]))
        checkEqual(r.recovered, 1)
        checkEqual(r.lostDataFragments, 1)
    }

    func testParityBeforeDataNeverCompletesAShortFrame() {
        // Reordering: the final-group parity overtakes the data. With
        // only fragment 0 present two are missing, so nothing completes;
        // the old flag-only inference "repaired" a 2-fragment frame here.
        let r = FrameReassembler()
        let payloads = [Data([1, 2, 3]), Data([4, 5, 6]), Data([7, 8, 9])]
        checkNil(r.push(packet(1, 0, flags: 0x60, payload: parity(payloads, total: 3))))
        checkNil(r.push(packet(1, 0, payload: payloads[0])))
        checkEqual(r.recovered, 0)
        let completed = r.push(packet(1, 1, payload: payloads[1]))
        checkEqual(completed?.data, Data([1, 2, 3, 4, 5, 6, 7, 8, 9]))
        checkEqual(r.recovered, 1)
    }

    func testTwoKnownLossesCannotRecoverAndParityDuplicatesAreIgnored() {
        let r = FrameReassembler()
        let payloads = [Data([1]), Data([2]), Data([3])]
        checkNil(r.push(packet(1, 2, flags: 0x10, payload: payloads[2]), now: 1))
        let p = packet(1, 0, flags: 0x60, payload: parity(payloads, total: 3))
        checkNil(r.push(p, now: 1))
        checkNil(r.push(p, now: 1))
        checkEqual(r.recovered, 0)
        r.expireStalledFrames(now: 1.1, timeout: 0.06)
        checkEqual(r.discarded, 1)
        checkEqual(r.totalDataFragments, 3)
        checkEqual(r.lostDataFragments, 2)
    }

    func testResetKeepsFeedbackCountersMonotonic() {
        let r = FrameReassembler()
        checkNotNil(r.push(packet(100, 0, flags: 0x11), now: 1))
        checkNil(r.push(packet(101, 0), now: 1))
        r.reset()
        r.expireStalledFrames(now: 2, timeout: 0.06)
        checkNotNil(r.push(packet(1, 0, flags: 0x11), now: 2))
        checkEqual(r.discarded, 0)
        checkEqual(r.delivered, 2)
        checkEqual(r.totalDataFragments, 2)
    }

    func testHealthyDuplicatesAndTrailingParity() {
        let r = FrameReassembler()
        let payloads = [Data([1, 2]), Data([3])]
        let first = packet(1, 0, payload: payloads[0])
        checkNil(r.push(first, now: 1))
        checkNil(r.push(first, now: 1))
        checkNotNil(r.push(packet(1, 1, flags: 0x10, payload: payloads[1]), now: 1))
        checkNil(r.push(packet(1, 0, flags: 0x60, payload: parity(payloads, total: 2)), now: 1))
        r.expireStalledFrames(now: 2, timeout: 0.06)
        checkEqual(r.discarded, 0)
        checkEqual(r.recovered, 0)
        checkEqual(r.totalDataFragments, 2)
        checkEqual(r.lostDataFragments, 0)
    }

    func testPendingBoundCountsLossOnce() {
        let r = FrameReassembler()
        for fid in 1...9 { checkNil(r.push(packet(UInt16(fid), 0), now: 1)) }
        checkEqual(r.discarded, 1)
        r.expireStalledFrames(now: 2, timeout: 0.06)
        checkEqual(r.discarded, 9)
        checkNil(r.push(packet(9, 1, flags: 0x10), now: 2))
        checkNotNil(r.push(packet(10, 0, flags: 0x10), now: 2))
        checkEqual(r.discarded, 9)
    }
}

@main
private enum FrameReassemblerTestRunner {
    static func main() {
        let tests = FrameReassemblerTests()
        tests.testWholeAndPartialLossDoNotDoubleCount()
        tests.testWrappingGapAndKeyframeResync()
        tests.testTailExpiryAndLateFragments()
        tests.testNewVideoTrafficDefersExpiry()
        tests.testEverySingleFECFragmentLossIncludingFinalGroup()
        tests.testLastGroupTotalCompletesWithoutLastFragmentMarker()
        tests.testParityBeforeDataNeverCompletesAShortFrame()
        tests.testTwoKnownLossesCannotRecoverAndParityDuplicatesAreIgnored()
        tests.testResetKeepsFeedbackCountersMonotonic()
        tests.testHealthyDuplicatesAndTrailingParity()
        tests.testPendingBoundCountsLossOnce()
        print("11 reassembly tests passed (including 135 single-fragment FEC loss cases)")
    }
}
#endif
