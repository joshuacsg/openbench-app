// DisplaySidebarView.swift — Left overlay listing host displays with
// live thumbnails (host-captured JPEG snapshots). Replaces the old
// DisplayPickerView dropdown.

import SwiftUI

public struct DisplaySidebarView: View {
    public let displays: [DisplayInfo]
    public let thumbnails: [UInt32: CGImage]
    public let selectedDisplayID: UInt32?
    public var onSelect: (UInt32?) -> Void
    public var onClose: () -> Void

    public init(
        displays: [DisplayInfo],
        thumbnails: [UInt32: CGImage],
        selectedDisplayID: UInt32?,
        onSelect: @escaping (UInt32?) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.displays = displays
        self.thumbnails = thumbnails
        self.selectedDisplayID = selectedDisplayID
        self.onSelect = onSelect
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Displays")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    ForEach(displays) { display in
                        displayCard(display)
                    }
                    if displays.count > 1 {
                        allDisplaysCard
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .frame(width: 232)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }

    private func displayCard(_ display: DisplayInfo) -> some View {
        let selected = selectedDisplayID == display.id
        return Button {
            onSelect(display.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(.black.opacity(0.35))
                    if let cg = thumbnails[display.id] {
                        Image(decorative: cg, scale: 1)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white.opacity(0.5))
                    }
                }
                .aspectRatio(aspect(display), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(
                            selected ? Color.accentColor : .white.opacity(0.15),
                            lineWidth: selected ? 2 : 0.5
                        )
                )

                HStack(spacing: 4) {
                    Text(label(display))
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(selected ? 0.95 : 0.7))
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The unified multi-display composite ("All Displays", id nil).
    private var allDisplaysCard: some View {
        let selected = selectedDisplayID == nil
        return Button {
            onSelect(nil)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.3.group")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                Text("All Displays")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(selected ? 0.95 : 0.7))
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(.black.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(
                        selected ? Color.accentColor : .white.opacity(0.15),
                        lineWidth: selected ? 2 : 0.5
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func aspect(_ display: DisplayInfo) -> CGFloat {
        guard display.width > 0, display.height > 0 else { return 16.0 / 10.0 }
        return CGFloat(display.width) / CGFloat(display.height)
    }

    private func label(_ display: DisplayInfo) -> String {
        display.name.isEmpty
            ? "\(display.width)×\(display.height)"
            : display.name
    }
}
