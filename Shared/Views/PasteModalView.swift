#if canImport(UIKit)
import SwiftUI

struct PasteModalView: View {
    let onSend: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Type or paste text to send to the remote desktop.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextEditor(text: $text)
                    .focused($isFocused)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .frame(minHeight: 150)
            }
            .padding()
            .navigationTitle("Paste to Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        onSend(text)
                        dismiss()
                    }
                    .disabled(text.isEmpty)
                }
            }
            .onAppear {
                isFocused = true
            }
        }
    }
}

#Preview {
    PasteModalView { text in
        print("Sending: \(text)")
    }
}
#endif
