import SwiftUI
import AVFoundation

struct SpeakerEntry: Identifiable {
    let id: String  // "speaker_0", "speaker_1", etc.
    var displayName: String
    let samplePath: URL?
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
                HStack {
                    Text(speaker.id)
                        .frame(width: 80, alignment: .leading)
                        .foregroundStyle(.secondary)

                    TextField("Name", text: $speaker.displayName)
                        .textFieldStyle(.roundedBorder)

                    if speaker.samplePath != nil {
                        Button {
                            playSample(speaker.samplePath!)
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.borderless)
                    }
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
        .background {
            if #available(macOS 26.0, *) {
                RoundedRectangle(cornerRadius: 12).glassEffect()
            } else {
                RoundedRectangle(cornerRadius: 12).fill(.regularMaterial)
            }
        }
    }

    private func playSample(_ url: URL) {
        audioPlayer?.stop()
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.play()
    }
}
