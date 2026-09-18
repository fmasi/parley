import SwiftUI
import os
import TranscriberCore

struct SessionNameDialog: View {
    @State private var name: String
    @State private var selectedDeviceId: String?
    /// One-way latch: once the user touches the field the name is theirs, so
    /// the calendar attribution stays gone rather than flickering back if they
    /// happen to retype the suggestion exactly.
    @State private var userHasEdited = false
    /// Whether `name` currently holds the calendar's suggestion (vs. empty or user-typed), so the
    /// hint below the field can say where it came from even though the lookup resolves late (#197).
    @State private var calendarSuggestionApplied: Bool
    @State private var isStarting = false
    @State private var levelMonitor = InputLevelMonitor()
    @FocusState private var focused: Bool

    /// Filled in late by a background calendar lookup that this dialog never waits on before
    /// appearing (#197). `name` adopts it once, the first time it resolves non-empty, unless the
    /// user has already started typing.
    private let suggestion: SessionNameSuggestion

    /// Main-actor: the window controller's wrapper checks its panel is still live (#192).
    let onStart: @MainActor (String, String?) -> Void  // (sessionName, micDeviceId?)
    let onCancel: () -> Void

    init(
        suggestion: SessionNameSuggestion,
        initialDeviceId: String?,
        onStart: @escaping @MainActor (String, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.suggestion = suggestion
        let initialTitle = suggestion.eventTitle ?? ""
        self._name = State(initialValue: initialTitle)
        self._calendarSuggestionApplied = State(initialValue: !initialTitle.isEmpty)
        self._selectedDeviceId = State(initialValue: initialDeviceId)
        self.onStart = onStart
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Name This Recording")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                TextField("e.g. Weekly standup", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { start() }
                    .onChange(of: name) { _, _ in userHasEdited = true }

                // Say where the pre-filled name came from; the hint steps
                // aside as soon as the user types their own.
                if calendarSuggestionApplied && !userHasEdited {
                    Label("Suggested from your calendar", systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Leave blank to use a timestamp.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            MicrophonePicker(
                selectedDeviceId: $selectedDeviceId,
                levelMonitor: levelMonitor
            )
            .disabled(isStarting)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Recording") { start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isStarting)
            }
        }
        .padding(20)
        .frame(width: 380)
        .modifier(GlassBackgroundModifier(cornerRadius: 12))
        .onAppear { focused = true }
        .onChange(of: suggestion.eventTitle) { _, newTitle in
            // Late arrival from the background calendar lookup (#197): adopt it only if the field
            // is still exactly what the user found it as — empty, or an earlier suggestion. The
            // decision itself is a pure, unit-tested function (SessionNameSuggestionPolicyTests).
            guard let adopted = SessionNameSuggestionPolicy.adopt(userHasEdited: userHasEdited, newTitle: newTitle) else { return }
            name = adopted
            calendarSuggestionApplied = true
        }
    }

    private func start() {
        guard !isStarting else { return }   // Return in the field and the button both land here
        isStarting = true
        let sessionName = name.trimmingCharacters(in: .whitespaces)
        let deviceId = selectedDeviceId
        Task {
            // Let go of the mic before the capture helper opens it, so the two never contend for the
            // device's HAL IO (#192). Bounded: a wedged meter must not hold up the recording.
            if await !levelMonitor.stopAndRelease(timeout: 1) {
                // Known, accepted overlap (#192): the meter's start is still stuck. Logged so a future
                // hang report can be traced to it.
                Logger.state.warning("Level meter did not release the mic within 1 s — proceeding with the recording start anyway")
            }
            onStart(sessionName, deviceId)
        }
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
