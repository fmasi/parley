import SwiftUI
import TranscriberCore

/// What the recording picker shows (#29): the scan of the recordings folder as it comes in.
@Observable
@MainActor
final class RecordingPickerModel {
    enum State: Equatable {
        case loading
        case loaded([PastRecording])
        /// The recordings folder could not be listed (missing, no permission).
        case folderUnreadable
        /// The recordings folder did not answer in time (a share that hangs).
        case timedOut
    }

    var state: State = .loading
}

/// The menu's "Rename Speakers…" (#29): the recent recordings, newest first, to open in the rename dialog — or any
/// transcript through Choose File…. The latest recording is selected, so Return opens it as the menu item used to.
struct RecordingPickerView: View {
    let model: RecordingPickerModel
    let onOpen: (URL) -> Void
    let onChooseFile: () -> Void
    let onCancel: () -> Void

    @State private var selection: PastRecording.ID?

    private var recordings: [PastRecording] {
        if case .loaded(let list) = model.state { return list }
        return []
    }

    private var selected: PastRecording? { recordings.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rename Speakers")
                    .font(.headline)
                Text("Choose a recording to name its speakers, re-detect them or rename it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content
                .frame(height: 260)

            HStack {
                Button("Choose File…", action: onChooseFile)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Open") { selected.map { onOpen($0.transcript) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 400)
        .modifier(GlassBackgroundModifier(cornerRadius: 12))
        .onChange(of: model.state, initial: true) { _, _ in
            if selection == nil || selected == nil { selection = recordings.first?.id }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            placeholder { ProgressView().controlSize(.small); Text("Reading the recordings folder…") }
        case .folderUnreadable:
            placeholder { Text("Parley couldn’t open the recordings folder. Choose a transcript file instead.") }
        case .timedOut:
            placeholder { Text("The recordings folder didn’t answer. Choose a transcript file instead.") }
        case .loaded(let list) where list.isEmpty:
            placeholder { Text("No recordings in the recordings folder yet.") }
        case .loaded(let list):
            List(list, selection: $selection) { recording in
                row(recording)
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds()
            // Double-click (and Return in the list) opens the row.
            .contextMenu(forSelectionType: PastRecording.ID.self, menu: { _ in }) { ids in
                guard let id = ids.first, let recording = list.first(where: { $0.id == id }) else { return }
                onOpen(recording.transcript)
            }
        }
    }

    private func row(_ recording: PastRecording) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(recording.name.isEmpty ? "Unnamed recording" : recording.name)
                .foregroundStyle(recording.name.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(Self.when(recording))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 8) { content() }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary))
    }

    /// "Today at 09:30", "12 Nov 2026 at 14:05": the day relative where it can be. The raw folder and stamp when they are
    /// no real date.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static func when(_ recording: PastRecording) -> String {
        guard let date = recording.startDate() else { return "\(recording.day) \(recording.time)" }
        return formatter.string(from: date)
    }
}
