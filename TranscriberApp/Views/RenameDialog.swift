import SwiftUI
import AVFoundation

struct SpeakerSample {
    let text: String
    let audioFile: URL?
    let start: TimeInterval
    let end: TimeInterval
}

struct SpeakerEntry: Identifiable {
    let id: String  // "Local Speaker 1", "Remote Speaker 1", etc.
    var displayName: String
    let samples: [SpeakerSample]  // up to 3, sorted by duration (longest first)
}

struct RenameDialog: View {
    @State private var speakers: [SpeakerEntry]
    @State private var audioPlayer: AVAudioPlayer?
    @State private var sampleIndices: [String: Int] = [:]  // speaker id → current sample index

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
                let speakerId = speaker.id
                let sampleIdx = sampleIndices[speakerId, default: 0]
                let sample = speaker.samples.indices.contains(sampleIdx) ? speaker.samples[sampleIdx] : nil

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(speaker.id)
                            .frame(width: 120, alignment: .leading)
                            .foregroundStyle(.secondary)

                        TextField("Name", text: $speaker.displayName)
                            .textFieldStyle(.roundedBorder)

                        if let sample, sample.audioFile != nil {
                            Button {
                                playSample(
                                    sample.audioFile!,
                                    from: sample.start,
                                    to: sample.end
                                )
                            } label: {
                                Image(systemName: "play.circle")
                            }
                            .buttonStyle(.borderless)
                        }

                        if speaker.samples.count > 1 {
                            Button {
                                let current = sampleIndices[speaker.id] ?? 0
                                sampleIndices[speaker.id] = (current + 1) % speaker.samples.count
                            } label: {
                                Image(systemName: "forward.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Next sample (\(sampleIdx + 1)/\(speaker.samples.count))")
                        }
                    }

                    if let sample {
                        HStack(spacing: 4) {
                            if speaker.samples.count > 1 {
                                Text("\(sampleIdx + 1)/\(speaker.samples.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.quaternary)
                                    .monospacedDigit()
                            }
                            Text(sample.text)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                        .padding(.leading, 124)
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
        .modifier(GlassBackgroundModifier(cornerRadius: 12))
    }

    @State private var stopTimer: Timer?

    private func playSample(_ url: URL, from start: TimeInterval, to end: TimeInterval) {
        audioPlayer?.stop()
        stopTimer?.invalidate()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        let safeStart = min(start, player.duration)
        let safeEnd = min(end, player.duration)
        let duration = safeEnd - safeStart
        guard duration > 0 else { return }
        player.currentTime = safeStart
        player.play()
        audioPlayer = player
        stopTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            self.audioPlayer?.stop()
        }
    }
}
