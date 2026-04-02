import SwiftUI
import TranscriberCore

struct SessionNameDialog: View {
    @State private var name: String
    @State private var selectedDeviceId: String?
    @FocusState private var focused: Bool

    let devices: [AudioInputDevice]
    let onStart: (String, String?) -> Void  // (sessionName, micDeviceId?)
    let onCancel: () -> Void

    init(
        suggestedName: String,
        initialDeviceId: String?,
        devices: [AudioInputDevice],
        onStart: @escaping (String, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._name = State(initialValue: suggestedName)
        self._selectedDeviceId = State(initialValue: initialDeviceId)
        self.devices = devices
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

            MicrophonePicker(
                selectedDeviceId: $selectedDeviceId,
                devices: devices
            )

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Recording") { start() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 380)
        .modifier(GlassBackgroundModifier(cornerRadius: 12))
        .onAppear { focused = true }
    }

    private func start() {
        onStart(
            name.trimmingCharacters(in: .whitespaces),
            selectedDeviceId
        )
    }
}

/// Applies Liquid Glass on macOS 26+, falls back to .regularMaterial on older versions.
/// Used by both SessionNameDialog and RenameDialog.
struct GlassBackgroundModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(
                in: .rect(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: cornerRadius,
                    bottomTrailingRadius: cornerRadius,
                    topTrailingRadius: 0
                )
            )
        } else {
            content.background {
                UnevenRoundedRectangle(
                    bottomLeadingRadius: cornerRadius,
                    bottomTrailingRadius: cornerRadius
                ).fill(.regularMaterial)
            }
        }
        #else
        content.background {
            UnevenRoundedRectangle(
                bottomLeadingRadius: cornerRadius,
                bottomTrailingRadius: cornerRadius
            ).fill(.regularMaterial)
        }
        #endif
    }
}
