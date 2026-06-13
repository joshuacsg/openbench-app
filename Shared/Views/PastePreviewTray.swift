// PastePreviewTray.swift — Messenger-style staging tray for clipboard
// items being pasted to the Mac. Tapping the paste button stages the
// clipboard contents here as thumbnail chips (image preview, or a file
// glyph + type badge), each removable with an ✕, and a send button
// ships them all over the reliable clipboard stream.

#if canImport(UIKit)
import SwiftUI

/// One staged clipboard item awaiting send.
struct PastePreviewItem: Identifiable {
    let id = UUID()
    let blob: ClipboardBlobData
    /// Image preview, if the payload is an image.
    let thumbnail: UIImage?
    /// Filename / label shown under the chip.
    let displayName: String
    /// Short type badge, e.g. "PNG", "PDF", "MP3".
    let typeBadge: String
    /// True while its send is in flight.
    var isSending = false
}

struct PastePreviewTray: View {
    @Binding var items: [PastePreviewItem]
    var onSend: () -> Void
    var onRemove: (PastePreviewItem) -> Void

    private var anySending: Bool { items.contains { $0.isSending } }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items) { item in
                        chip(item)
                    }
                }
                .padding(.vertical, 2)
            }

            sendButton
                .padding(.top, 4)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
    }

    private func chip(_ item: PastePreviewItem) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(white: 0.16))
                    .frame(width: 84, height: 84)

                if let thumb = item.thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white.opacity(0.55))
                        Text(item.typeBadge)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                }

                if item.isSending {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.black.opacity(0.45))
                        .frame(width: 84, height: 84)
                    ProgressView()
                        .controlSize(.regular)
                        .tint(.white)
                }
            }
            .frame(width: 84, height: 84)
            .overlay(alignment: .topTrailing) {
                if !item.isSending {
                    Button {
                        onRemove(item)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color(white: 0.25))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 7, y: -7)
                }
            }

            Text(item.displayName)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .frame(width: 84)
        }
    }

    private var sendButton: some View {
        Button(action: onSend) {
            Image(systemName: "arrow.up")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    Circle().fill(items.isEmpty || anySending
                                  ? Color.gray.opacity(0.5)
                                  : Color.accentColor)
                )
        }
        .buttonStyle(.plain)
        .disabled(items.isEmpty || anySending)
    }
}
#endif
