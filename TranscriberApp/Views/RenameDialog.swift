import SwiftUI
import AVFoundation
import TranscriberCore
import os

struct SpeakerSample {
    let text: String
    /// Chunk file this sample lives in, already resolved — nil when no playable audio exists.
    let audioFile: URL?
    /// Offsets WITHIN `audioFile`, not absolute transcript time (#132).
    let start: TimeInterval
    let end: TimeInterval
    /// Which channel of the stereo archive holds this speaker (L = local/mic, R = remote/system).
    /// Comes from the segment's `source`, not the display name — renaming a speaker must not
    /// change which channel we read.
    let isLocal: Bool
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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rename Speakers")
                    .font(.headline)
                Text("Play a sample to recognize each voice. Names replace the speaker labels in this recording's transcript.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach($speakers) { $speaker in
                speakerCard($speaker)
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var mapping: [String: String] = [:]
                    for speaker in speakers {
                        // Trim: a whitespace-only name passed the old !isEmpty check and replaced a
                        // real speaker label with blanks.
                        let name = speaker.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty {
                            mapping[speaker.id] = name
                        }
                    }
                    onSave(mapping)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .modifier(GlassBackgroundModifier(cornerRadius: 12))
        .onDisappear {
            // The last preview would otherwise linger: it is only cleaned up when the NEXT one is
            // created, and closing the dialog is the common exit.
            stopPlayback()
            previousPreview.map { try? FileManager.default.removeItem(at: $0) }
            previousPreview = nil
        }
    }

    /// One card per detected speaker: label + sample controls, name field,
    /// then the sample quote — no rigid label column, no magic padding.
    private func speakerCard(_ speaker: Binding<SpeakerEntry>) -> some View {
        let speakerId = speaker.wrappedValue.id
        let samples = speaker.wrappedValue.samples
        let sampleIdx = sampleIndices[speakerId, default: 0]
        let sample = samples.indices.contains(sampleIdx) ? samples[sampleIdx] : nil

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(speakerId)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                if samples.count > 1 {
                    Text("\(sampleIdx + 1) of \(samples.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if let sample, let audioFile = sample.audioFile {
                    Button {
                        playSample(
                            audioFile,
                            from: sample.start,
                            to: sample.end,
                            isLocal: sample.isLocal
                        )
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.title3)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .help("Play Sample")
                }

                if samples.count > 1 {
                    Button {
                        let current = sampleIndices[speakerId] ?? 0
                        sampleIndices[speakerId] = (current + 1) % samples.count
                    } label: {
                        Image(systemName: "forward.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.title3)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .help("Next Sample")
                }
            }

            TextField("Name", text: speaker.displayName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { stopPlayback() }
                .onChange(of: speaker.wrappedValue.displayName) { _, _ in stopPlayback() }

            if let sample {
                Text("“\(sample.text)”")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quinary)
        )
    }

    @State private var stopTimer: Timer?
    @State private var previousPreview: URL?

    private func stopPlayback() {
        audioPlayer?.stop()
        stopTimer?.invalidate()
    }

    /// Play a speaker sample: the resolved chunk, the resolved offset, the resolved channel.
    /// Channel extraction (L = local mic, R = remote system) keeps the other party out of the clip.
    private func playSample(_ url: URL, from start: TimeInterval, to end: TimeInterval, isLocal: Bool) {
        stopPlayback()

        let preview: URL
        do {
            preview = try SpeakerSamplePreview.makeMonoPreview(
                of: url, from: start, to: end, isLocal: isLocal
            )
        } catch {
            Logger.audio.error("playSample: \(String(describing: error), privacy: .public)")
            return
        }

        // Clean up the previous clip only now — removing it earlier could race a player still
        // reading it.
        previousPreview.map { try? FileManager.default.removeItem(at: $0) }
        previousPreview = preview

        guard let player = try? AVAudioPlayer(contentsOf: preview) else {
            Logger.audio.error("playSample: AVAudioPlayer init failed")
            try? FileManager.default.removeItem(at: preview)
            previousPreview = nil
            return
        }
        player.play()
        audioPlayer = player
        stopTimer = Timer.scheduledTimer(withTimeInterval: player.duration, repeats: false) { _ in
            self.audioPlayer?.stop()
        }
    }

}
