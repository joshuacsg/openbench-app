#if canImport(UIKit)
import SwiftUI
import UIKit

struct MinimapView: View {
    let thumbnail: UIImage?
    let viewportScale: CGFloat
    let viewportOffset: CGPoint
    let viewBounds: CGSize
    var onPanNormalized: ((CGFloat, CGFloat) -> Void)?
    var onZoomChanged: ((CGFloat) -> Void)?
    @Binding var isVisible: Bool

    @State private var sliderValue: CGFloat = 1.0

    // Drag-to-corner state.
    @State private var corner: Corner = .bottomTrailing
    /// Absolute panel center while dragging; `nil` means use corner position.
    @State private var dragPosition: CGPoint? = nil
    /// The panel center at the moment the drag started.
    @State private var dragStartPosition: CGPoint = .zero
    @State private var isDragging: Bool = false

    private let panelWidth: CGFloat = 300

    enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
    }

    var body: some View {
        GeometryReader { container in
            let pos = panelPosition(in: container.size)

            VStack(spacing: 6) {
                // Draggable header
                HStack {
                    Text("Minimap")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        isVisible = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.top, 16)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
                .gesture(panelDragGesture(containerSize: container.size))

                // Thumbnail + draggable viewport rectangle
                GeometryReader { geo in
                    let tw = geo.size.width
                    let th = geo.size.height

                    ZStack {
                        if let thumbnail {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: tw, height: th)
                                .clipped()
                        } else {
                            Color.black.opacity(0.4)
                        }

                        // Viewport rectangle — draggable to pan.
                        viewportRect(thumbWidth: tw, thumbHeight: th)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                // Convert drag position in thumbnail to normalized coords.
                                let nx = min(max(value.location.x / tw, 0), 1)
                                let ny = min(max(value.location.y / th, 0), 1)
                                onPanNormalized?(nx, ny)
                            }
                    )
                    .simultaneousGesture(
                        // Tap to jump.
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                let nx = min(max(value.location.x / tw, 0), 1)
                                let ny = min(max(value.location.y / th, 0), 1)
                                onPanNormalized?(nx, ny)
                            }
                    )
                }
                .aspectRatio(thumbnailAspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(.horizontal, 10)

                // Zoom slider
                HStack(spacing: 6) {
                    Slider(value: $sliderValue, in: 1.0...6.0, step: 0.1)
                        .onChange(of: sliderValue) { _, newValue in
                            onZoomChanged?(newValue)
                        }
                    Text(String(format: "%.1fx", sliderValue))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .frame(width: panelWidth)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(radius: 8)
            .position(dragPosition ?? pos)
            .animation(isDragging ? nil : .spring(response: 0.35, dampingFraction: 0.75), value: dragPosition)
            .animation(isDragging ? nil : .spring(response: 0.35, dampingFraction: 0.75), value: corner)
        }
        .onAppear { sliderValue = viewportScale }
        .onChange(of: viewportScale) { _, v in sliderValue = v }
    }

    // MARK: - Thumbnail aspect

    private var thumbnailAspect: CGFloat {
        guard let thumbnail else { return 16.0 / 9.0 }
        let s = thumbnail.size
        guard s.height > 0 else { return 16.0 / 9.0 }
        return s.width / s.height
    }

    // MARK: - Viewport rectangle

    @ViewBuilder
    private func viewportRect(thumbWidth: CGFloat, thumbHeight: CGFloat) -> some View {
        if viewportScale > 1.01 {
            let rw = thumbWidth / viewportScale
            let rh = thumbHeight / viewportScale
            // viewportOffset is how far the scaled Metal view is shifted
            // from center, in view points. Convert to thumbnail space:
            // the visible center in normalized coords is offset / (viewBounds * scale).
            let cx = thumbWidth / 2 - (viewportOffset.x / max(viewBounds.width * viewportScale, 1)) * thumbWidth
            let cy = thumbHeight / 2 - (viewportOffset.y / max(viewBounds.height * viewportScale, 1)) * thumbHeight

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 2)
                .background(Color.white.opacity(0.05))
                .frame(width: rw, height: rh)
                .position(x: cx, y: cy)
        }
    }

    // MARK: - Panel positioning + drag-to-corner

    private func panelPosition(in containerSize: CGSize) -> CGPoint {
        let margin: CGFloat = 20
        // Estimate panel height from width + aspect ratio.
        let thumbH = panelWidth / thumbnailAspect
        let panelH = thumbH + 96 // header + slider + padding
        let halfW = panelWidth / 2
        let halfH = panelH / 2

        switch corner {
        case .topLeading:
            return CGPoint(x: margin + halfW, y: margin + halfH)
        case .topTrailing:
            return CGPoint(x: containerSize.width - margin - halfW, y: margin + halfH)
        case .bottomLeading:
            return CGPoint(x: margin + halfW, y: containerSize.height - margin - halfH)
        case .bottomTrailing:
            return CGPoint(x: containerSize.width - margin - halfW, y: containerSize.height - margin - halfH)
        }
    }

    private func panelDragGesture(containerSize: CGSize) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    dragStartPosition = panelPosition(in: containerSize)
                }
                dragPosition = CGPoint(
                    x: dragStartPosition.x + value.translation.width,
                    y: dragStartPosition.y + value.translation.height
                )
            }
            .onEnded { value in
                let currentX = dragStartPosition.x + value.translation.width
                let currentY = dragStartPosition.y + value.translation.height

                // Project velocity forward (180ms) to determine throw target.
                let projectionTime: CGFloat = 0.18
                let targetX = currentX + value.predictedEndLocation.x - value.location.x
                let targetY = currentY + value.predictedEndLocation.y - value.location.y

                // Use projected position to pick the corner the user is
                // "throwing" toward, not just the nearest to current position.
                let midX = containerSize.width / 2
                let midY = containerSize.height / 2

                let newCorner: Corner
                if targetX < midX {
                    newCorner = targetY < midY ? .topLeading : .bottomLeading
                } else {
                    newCorner = targetY < midY ? .topTrailing : .bottomTrailing
                }

                isDragging = false
                corner = newCorner
                dragPosition = nil
            }
    }
}
#endif
