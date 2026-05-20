import SwiftUI
import TranscriberCore

struct SessionNameDialog: View {
    /// UI-local mode for the Speakers control. Maps to `SpeakerSelection` on submit.
    private enum SpeakerMode: Hashable {
        case auto
        case atLeast
        case exactly
    }

    @State private var name: String
    @State private var selectedDeviceId: String?
    @State private var speakerMode: SpeakerMode = .auto
    @State private var speakerCount: Int = 2
    @FocusState private var focused: Bool

    let devices: [AudioInputDevice]
    let onStart: (String, String?, SpeakerSelection) -> Void  // (sessionName, micDeviceId?, speakerSelection)
    let onCancel: () -> Void

    init(
        suggestedName: String,
        initialDeviceId: String?,
        devices: [AudioInputDevice],
        onStart: @escaping (String, String?, SpeakerSelection) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._name = State(initialValue: suggestedName)
        self._selectedDeviceId = State(initialValue: initialDeviceId)
        self.devices = devices
        self.onStart = onStart
        self.onCancel = onCancel
    }

    /// Translates the UI mode + count into the core `SpeakerSelection`.
    private var speakerSelection: SpeakerSelection {
        switch speakerMode {
        case .auto:    return .auto
        case .atLeast: return .atLeast(speakerCount)
        case .exactly: return .exactly(speakerCount)
        }
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

            VStack(alignment: .leading, spacing: 6) {
                Text("Speakers")
                    .font(.subheadline.weight(.semibold))

                Picker("Speakers", selection: $speakerMode) {
                    Text("Auto").tag(SpeakerMode.auto)
                    Text("At least").tag(SpeakerMode.atLeast)
                    Text("Exactly").tag(SpeakerMode.exactly)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if speakerMode != .auto {
                    Stepper(value: $speakerCount, in: 1...20) {
                        Text("\(speakerMode == .atLeast ? "At least" : "Exactly") \(speakerCount) speaker\(speakerCount == 1 ? "" : "s")")
                    }
                }

                if speakerMode == .exactly {
                    Label(
                        "Extra speakers beyond \(speakerCount) will be merged.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Text("Auto lets the diarizer detect the speaker count. \"At least\" sets a minimum without capping.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

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
            selectedDeviceId,
            speakerSelection
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
