// DisplayPickerView.swift — A capsule-styled picker for switching between
// host displays.  Shown in the StreamView status overlay bar.

import SwiftUI

/// A compact Menu-based picker that lets the user switch between displays.
/// Styled as a capsule pill to match the status overlay aesthetic.
///
/// - `displays`: the list of displays reported by the host (from StreamSession).
/// - `selectedDisplayID`: binding to the currently active display (`nil`
///    means "Unified / let the host decide").
/// - `onSelect`: called with the new display ID whenever the selection changes.
public struct DisplayPickerView: View {
    public let displays: [DisplayInfo]
    @Binding public var selectedDisplayID: UInt32?
    public var onSelect: (UInt32?) -> Void

    public init(
        displays: [DisplayInfo],
        selectedDisplayID: Binding<UInt32?>,
        onSelect: @escaping (UInt32?) -> Void
    ) {
        self.displays = displays
        self._selectedDisplayID = selectedDisplayID
        self.onSelect = onSelect
    }

    private var selectedLabel: String {
        if let id = selectedDisplayID,
           let display = displays.first(where: { $0.id == id }) {
            return "\(display.width)×\(display.height)"
        }
        return "Unified Display"
    }

    public var body: some View {
        Menu {
            // "Unified" option — sends nil display ID
            Button {
                selectedDisplayID = nil
                onSelect(nil)
            } label: {
                HStack {
                    Text("Unified Display")
                    if selectedDisplayID == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            if !displays.isEmpty {
                Divider()
                ForEach(displays) { display in
                    Button {
                        selectedDisplayID = display.id
                        onSelect(display.id)
                    } label: {
                        HStack {
                            Text("Display \(display.id) (\(display.width)×\(display.height))")
                            if selectedDisplayID == display.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "display.2")
                    .font(.caption)
                Text(selectedLabel)
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.white.opacity(0.85))
        }
        .menuStyle(.borderlessButton)
    }
}
