// ClipboardBlobSender.swift — Send a large clipboard payload (image,
// file, video) from the iPad to the host over a reliable QUIC stream.
//
// Text clipboard sync rides small control datagrams, but media is far
// too large for the ~1 KB datagram path. A blob travels as a single
// bincode-framed ClipboardBlob over a dedicated stream-mode QUIC
// connection to the pen port (the host disambiguates: pen = datagrams,
// clipboard = a stream). Matches flux-protocol::clipboard::ClipboardBlob.

import Foundation
import Network

/// Mirrors `flux_protocol::clipboard::ClipboardKind` (bincode variant index).
public enum ClipboardBlobKind: UInt32 {
    case image = 0
    case file = 1
}

/// Mirrors `flux_protocol::clipboard::ClipboardBlob`.
public struct ClipboardBlobData {
    public let kind: ClipboardBlobKind
    public let uti: String
    public let filename: String
    public let pasteAfter: Bool
    public let data: Data

    public init(kind: ClipboardBlobKind, uti: String, filename: String,
                pasteAfter: Bool = true, data: Data) {
        self.kind = kind
        self.uti = uti
        self.filename = filename
        self.pasteAfter = pasteAfter
        self.data = data
    }

    /// Hard cap, matching the host's `MAX_CLIPBOARD_BLOB` (50 MiB).
    public static let maxBytes = 50 * 1024 * 1024

    /// bincode (fixint, little-endian) layout:
    ///   kind:        u32 LE (enum variant index)
    ///   uti:         u64 LE length + UTF-8
    ///   filename:    u64 LE length + UTF-8
    ///   paste_after: u8 (0/1)
    ///   data:        u64 LE length + bytes
    public func encodeWire() -> Data {
        var out = Data()
        func leU32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { out.append(contentsOf: $0) } }
        func leU64(_ v: UInt64) { var le = v.littleEndian; withUnsafeBytes(of: &le) { out.append(contentsOf: $0) } }
        func str(_ s: String) {
            let b = Data(s.utf8)
            leU64(UInt64(b.count))
            out.append(b)
        }
        leU32(kind.rawValue)
        str(uti)
        str(filename)
        out.append(pasteAfter ? 1 : 0)
        leU64(UInt64(data.count))
        out.append(data)
        return out
    }
}
