import SwiftUI
import AVFoundation
import TranscriberCore
import os

// SpeakerSample (the sample text + resolved audio location) lives in TranscriberCore
// (TranscriptRenamer.swift), shared with the CLI rename path.

struct SpeakerEntry: Identifiable {
    let id: String  // "Local Speaker 1", "Remote Speaker 1", etc.
    var displayName: String
    let samples: [SpeakerSample]  // up to 3, sorted by duration (longest first)
}

struct RenameDialog: View {
    @State private var speakers: [SpeakerEntry]
    @State private var audioPlayer: AVAudioPlayer?
    @State private var sampleIndices: [String: Int] = [:]  // speaker id → current sample index
    @State private var speakerCounts: [String: Int] = [:]  // "local"/"remote" → user-stated count
    @State private var rediarizing: String?                // channel currently being re-detected
    @State private var rediarizeError: String?
    /// One instance for the dialog's lifetime. `FluidAudioDiarizer` caches a loaded manager per
    /// speaker count, and a fresh instance per press would throw that away — re-loading the models
    /// from disk on every Re-detect, including the common "try 2, then try 3" flow.
    @State private var diarizer = FluidAudioDiarizer()
    /// Held so Cancel/close can abort a running re-detect. Without it the unstructured Task
    /// outlives the dialog and rewrites the transcript after the user asked it not to.
    @State private var rediarizeTask: Task<Void, Never>?

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

    /// Channels present in this recording, in display order.
    private var channels: [String] {
        var seen: [String] = []
        for id in speakers.map(\.id) {
            let channel = id.hasPrefix("Local ") ? "local" : (id.hasPrefix("Remote ") ? "remote" : "")
            if !channel.isEmpty, !seen.contains(channel) { seen.append(channel) }
        }
        return seen
    }

    private func detectedCount(for channel: String) -> Int {
        let prefix = channel == "local" ? "Local " : "Remote "
        return max(1, speakers.filter { $0.id.hasPrefix(prefix) }.count)
    }

    /// Manual override for the diarizer's speaker count (#67).
    ///
    /// It lives here, after the recording, rather than only in the pre-recording dialog: before a
    /// call you often do not know (someone joins late, a call goes to speakerphone mid-conversation),
    /// but here the user is looking at the speaker list and can see it is wrong.
    @ViewBuilder
    private var speakerCountSection: some View {
        if !channels.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Wrong number of speakers?")
                    .font(.footnote.weight(.semibold))
                Text("Set how many people were on a channel and Parley will work out the speakers again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(channels, id: \.self) { channel in
                    // Resolved once per row: `detectedCount` filters `speakers`, and SwiftUI
                    // re-evaluates this body on every stepper tick.
                    let count = speakerCounts[channel] ?? detectedCount(for: channel)
                    HStack(spacing: 8) {
                        Text(channel == "local" ? "This side" : "Other side")
                            .font(.caption)
                            .frame(width: 70, alignment: .leading)
                        Stepper(
                            value: Binding(
                                get: { count },
                                set: { speakerCounts[channel] = max(1, min(20, $0)) }
                            ),
                            in: 1...20
                        ) {
                            Text("\(count)")
                                .font(.caption.monospacedDigit())
                        }
                        .labelsHidden()
                        Text("\(count) speaker\(count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if rediarizing == channel {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Re-detect") { rediarize(channel: channel, count: count) }
                                .font(.caption)
                                .disabled(rediarizing != nil)
                        }
                    }
                }

                if let rediarizeError {
                    Text(rediarizeError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func rediarize(channel: String, count: Int) {
        rediarizing = channel
        rediarizeError = nil
        stopPlayback()
        let path = jsonPath
        let vadThreshold = ConfigManager.shared.config.vadSpeechThreshold ?? 0.5
        rediarizeTask = Task {
            do {
                _ = try await TranscriptRediarizer.rediarize(
                    transcript: path,
                    source: channel,
                    speakerCount: count,
                    diarizer: diarizer,
                    vadSpeechThreshold: vadThreshold
                )
                // Rebuild the rows from the rewritten transcript: labels, sample text and the
                // resolved audio offsets can all have moved.
                let refreshed = RenameWindowController.parseSpeakers(from: path)
                await MainActor.run {
                    if refreshed.isEmpty {
                        // The transcript HAS been rewritten at this point. Silently keeping the old
                        // rows would show a stale speaker list under a dialog that looked like it
                        // succeeded — worse than saying nothing happened.
                        rediarizeError = "Re-detection finished but the speaker list could not be reloaded."
                    } else {
                        speakers = refreshed
                    }
                    sampleIndices = [:]
                    // Drop the stated count so the stepper falls back to what the diarizer actually
                    // produced. Leaving it pinned showed "3 speakers" after a run that yielded 2,
                    // which reads as a result rather than as the request it was.
                    speakerCounts[channel] = nil
                    rediarizing = nil
                }
            } catch {
                // .private: OS errors routinely embed full filesystem paths in their messages,
                // and a recording's path names the meeting.
                Logger.transcription.error("Re-diarize failed: \(error.localizedDescription, privacy: .private)")
                await MainActor.run {
                    rediarizeError = error.localizedDescription
                    rediarizing = nil
                }
            }
        }
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

            speakerCountSection

            HStack {
                Spacer()
                Button("Cancel") { rediarizeTask?.cancel(); onCancel() }
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
                // Saving mid-re-detect is a lost-work race: onSave writes the speaker names, the
                // dialog closes, and a re-diarization already past its last cancellation check then
                // rewrites the whole transcript — wiping the names that were just applied.
                .disabled(rediarizing != nil)
            }
        }
        .padding(20)
        .frame(width: 400)
        .modifier(GlassBackgroundModifier(cornerRadius: 12))
        .onDisappear {
            // The last preview would otherwise linger: it is only cleaned up when the NEXT one is
            // created, and closing the dialog is the common exit.
            rediarizeTask?.cancel()
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
