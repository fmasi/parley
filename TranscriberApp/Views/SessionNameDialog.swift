import SwiftUI

struct SessionNameDialog: View {
    @State private var name: String
    @FocusState private var focused: Bool

    let onStart: (String) -> Void
    let onCancel: () -> Void

    init(
        suggestedName: String,
        onStart: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._name = State(initialValue: suggestedName)
        self.onStart = onStart
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Name This Recording")
                .font(.headline)

            TextField("e.g. Weekly standup", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { start() }

            Text("Leave blank to use a timestamp.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Recording") { start() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 320)
        .background {
            if #available(macOS 26.0, *) {
                RoundedRectangle(cornerRadius: 12).glassEffect()
            } else {
                RoundedRectangle(cornerRadius: 12).fill(.regularMaterial)
            }
        }
        .onAppear { focused = true }
    }

    private func start() {
        onStart(name.trimmingCharacters(in: .whitespaces))
    }
}
