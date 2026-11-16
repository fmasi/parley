import SwiftUI
import TranscriberCore

/// The recording's name, changed while it records (#358): one field, Cancel and Save. Opened from the menu or the
/// meeting island's "Rename…". Saving changes nothing on disk yet — the coordinator renames the finished files.
struct RecordingNameDialog: View {
    @State private var name: String
    @FocusState private var focused: Bool
    let onSave: @MainActor (String) -> Void
    let onCancel: () -> Void

    init(currentName: String, onSave: @escaping @MainActor (String) -> Void, onCancel: @escaping () -> Void) {
        self._name = State(initialValue: currentName)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename This Recording")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                TextField("e.g. Weekly standup", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { onSave(name) }
                // Said plainly: the recording keeps writing under the name it started with.
                Text("The recording’s files take this name when it finishes. Leave blank to use a timestamp.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(name) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .modifier(GlassBackgroundModifier(cornerRadius: 12))
        .onAppear { focused = true }
    }
}
