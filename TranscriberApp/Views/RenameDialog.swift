import SwiftUI
import AVFoundation

struct SpeakerEntry: Identifiable {
    let id: String  // "Local Speaker 1", "Remote Speaker 1", etc.
    var displayName: String
    let sampleText: String
    let sampleAudioFile: URL?  // source WAV file containing this speaker
    let sampleStart: TimeInterval  // start time in the source WAV
    let sampleEnd: TimeInterval    // end time in the source WAV
}

struct RenameDialog: View {
    @State private var speakers: [SpeakerEntry]
    @State private var audioPlayer: AVAudioPlayer?

    let jsonPath: URL
    let onSave: ([String: String]) -> Void
    let onCancel: () -> Void

    init(
        jsonPath: URL,
        speakers: [SpeakerEntry],
        onSave: @escaping ([String: String]) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.jsonPath = jsonPath
        self._speakers = State(initialValue: speakers)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Speakers")
                .font(.headline)

            ForEach($speakers) { $speaker in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(speaker.id)
                            .frame(width: 120, alignment: .leading)
                            .foregroundStyle(.secondary)

                        TextField("Name", text: $speaker.displayName)
                            .textFieldStyle(.roundedBorder)

                        if speaker.sampleAudioFile != nil {
                            Button {
                                playSample(
                                    speaker.sampleAudioFile!,
                                    from: speaker.sampleStart,
                                    to: speaker.sampleEnd
                                )
                            } label: {
                                Image(systemName: "play.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    Text(speaker.sampleText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .padding(.leading, 124)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var mapping: [String: String] = [:]
                    for speaker in speakers {
                        if !speaker.displayName.isEmpty {
                            mapping[speaker.id] = speaker.displayName
                        }
                    }
                    onSave(mapping)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 400)
        .modifier(GlassBackgroundModifier(cornerRadius: 12))
    }

    @State private var stopTimer: Timer?

    private func playSample(_ url: URL, from start: TimeInterval, to end: TimeInterval) {
        audioPlayer?.stop()
        stopTimer?.invalidate()
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.currentTime = start
        audioPlayer?.play()
        let duration = end - start
        stopTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            audioPlayer?.stop()
        }
    }
}
