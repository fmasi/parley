import SwiftUI
import AppKit
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
    /// Live progress for the channel in `rediarizing`, so the row shows more than a bare spinner
    /// on an operation that can take minutes (#203). A local phase list, not
    /// `TranscriptRediarizer.Progress.Phase` directly: "Rebuilding list" happens here in the
    /// dialog (re-reading the rewritten transcript into rows), after `rediarize` itself returns,
    /// so Core has no phase for it.
    private enum RediarizePhase: Equatable {
        case decodingAudio
        case detectingSpeakers
        case rebuildingList
    }
    @State private var rediarizePhase: RediarizePhase?
    @State private var rediarizeFraction: Double?
    @State private var rediarizeStartedAt: Date?
    /// One instance for the dialog's lifetime. `FluidAudioDiarizer` caches a loaded manager per
    /// speaker count, and a fresh instance per press would throw that away — re-loading the models
    /// from disk on every Re-detect, including the common "try 2, then try 3" flow.
    @State private var diarizer = FluidAudioDiarizer()
    /// Held so Cancel/close can abort a running re-detect. Without it the unstructured Task
    /// outlives the dialog and rewrites the transcript after the user asked it not to.
    @State private var rediarizeTask: Task<Void, Never>?
    /// The `speaker_names` already saved per channel, loaded ONCE by `RenameWindowController` when
    /// the dialog was opened, rather than re-read from disk on every "Re-detect" press (#207).
    /// Refreshed after a successful re-detect, since names may have changed (cleared on this
    /// channel; untouched on the other).
    @State private var cachedChannelNames: [String: [String: String]]

    let jsonPath: URL
    let onSave: ([String: String]) -> Void
    let onCancel: () -> Void

    init(
        jsonPath: URL,
        speakers: [SpeakerEntry],
        initialChannelNames: [String: [String: String]] = [:],
        onSave: @escaping ([String: String]) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.jsonPath = jsonPath
        self._speakers = State(initialValue: speakers)
        self._cachedChannelNames = State(initialValue: initialChannelNames)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    /// Channels present in this recording, in display order.
    private var channels: [String] {
        var seen: [String] = []
        // Via `channel(of:)`, not the label prefix: once a speaker has been renamed its label is
        // "Jacques", not "Remote Speaker 1", so a prefix test finds no channels at all and the
        // Re-detect controls disappear entirely — on precisely the transcripts someone has already
        // invested naming effort in, which are the ones most worth re-detecting.
        for speaker in speakers {
            guard let channel = channel(of: speaker) else { continue }
            if !seen.contains(channel) { seen.append(channel) }
        }
        return seen
    }

    private func detectedCount(for channel: String) -> Int {
        // `channel(of:)`, not the label prefix — the same reason `channels` above uses it. On a
        // transcript whose speakers have been renamed, a prefix test matches nothing, the count
        // floors to 1, and the stepper pre-fills 1 however many speakers were actually detected:
        // wrong on exactly the recordings #205 made Re-detect reachable for again.
        max(1, speakers.filter { self.channel(of: $0) == channel }.count)
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
                            rediarizeStatus
                        } else {
                            Button("Re-detect") { confirmThenRediarize(channel: channel, count: count) }
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

    /// Phase + elapsed + (when known) a fraction, plus a Cancel that only aborts THIS operation —
    /// distinct from the dialog-level Cancel button, which also dismisses the whole panel (#203).
    /// Cancellation is already handled correctly by `rediarize(channel:count:)` (a `CancellationError`
    /// is treated as success, not failure); this is what makes it reachable and visible.
    @ViewBuilder
    private var rediarizeStatus: some View {
        HStack(spacing: 6) {
            if let rediarizeFraction {
                ProgressView(value: rediarizeFraction).controlSize(.small).frame(width: 50)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(rediarizePhaseLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let rediarizeStartedAt {
                    Text(rediarizeStartedAt, style: .timer)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Button("Cancel") { rediarizeTask?.cancel() }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }

    private var rediarizePhaseLabel: String {
        switch rediarizePhase {
        case .none: return "Starting…"
        case .decodingAudio: return "Splitting audio…"
        case .detectingSpeakers: return "Detecting speakers…"
        case .rebuildingList: return "Rebuilding list…"
        }
    }

    /// Which channel a row belongs to.
    ///
    /// The label prefix answers it until a speaker has been renamed — after that the label IS the
    /// person's name and carries no prefix, so fall back to the channel its samples were taken
    /// from. Without the fallback a renamed speaker looks like it belongs to no channel, and the
    /// warning below would miss exactly the names it exists to protect.
    /// Precondition: every `SpeakerEntry` in `speakers` has at least one sample. `parseSpeakers`
    /// populates them before building the entry, so the `nil` return below is unreachable today —
    /// but a future path that builds entries straight from the JSON would make those speakers
    /// invisible to the whole Re-detect UI (no channel section, not counted by the stepper), with
    /// nothing on screen to say so.
    private func channel(of speaker: SpeakerEntry) -> String? {
        if speaker.id.hasPrefix("Local ") { return "local" }
        if speaker.id.hasPrefix("Remote ") { return "remote" }
        guard let isLocal = speaker.samples.first?.isLocal else { return nil }
        return isLocal ? "local" : "remote"
    }

    /// Names a re-detect on this channel would destroy: those already written to the transcript,
    /// plus any typed into a field but not yet saved. Both are lost, so both have to count.
    private func hasNamesToLose(on channel: String) -> Bool {
        let unsaved = speakers.contains { speaker in
            guard self.channel(of: speaker) == channel else { return false }
            let typed = speaker.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return !typed.isEmpty && typed != speaker.id
        }
        if unsaved { return true }
        // From the cache loaded once when the dialog appeared, not a fresh read of the transcript
        // (#207) — `recording_directory` can be network- or iCloud-backed, and a synchronous read
        // on every button press blocks the main thread for as long as the mount takes to answer.
        return !(cachedChannelNames[channel] ?? [:]).isEmpty
    }

    /// Ask before clearing names (#202).
    ///
    /// Re-detecting produces a new set of clusters, and the names on this channel are dropped
    /// rather than carried over — carrying them re-points a name at whatever cluster the new run
    /// emits first, which can be a different person. That trade is defensible but it is not
    /// guessable, so it is stated in plain words before anything is written. Cancel touches
    /// nothing: the transcript is only rewritten inside `rediarize`.
    private func confirmThenRediarize(channel: String, count: Int) {
        guard hasNamesToLose(on: channel) else {
            rediarize(channel: channel, count: count)
            return
        }
        let side = channel == "local" ? "this side" : "the other side"
        let alert = NSAlert()
        alert.messageText = "Re-detecting will clear the names on \(side)"
        alert.informativeText =
            "Working out the speakers again produces a new set of voices, and Parley will not guess "
            + "which new speaker each existing name belongs to — guessing wrong would put the wrong "
            + "name on the wrong words. You can name them again straight afterwards, and the old "
            // Name the OPPOSITE channel explicitly: when the channel being re-detected is the remote
            // one, `side` above is already "the other side", and a fixed "the other side" here
            // contradicted the title in the one sentence meant to reassure — at the exact moment
            // the user is deciding whether to discard naming work.
            + "names are kept in the transcript's metadata. Names on \(channel == "local" ? "the other side" : "this side") are unaffected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Re-detect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        rediarize(channel: channel, count: count)
    }

    private func rediarize(channel: String, count: Int) {
        rediarizing = channel
        rediarizeError = nil
        rediarizePhase = nil
        rediarizeFraction = nil
        rediarizeStartedAt = Date()
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
                    vadSpeechThreshold: vadThreshold,
                    // Fires from off-main work (chunk decode loop, the diarizer's own background
                    // progress callback) — hop back to the main actor per update rather than
                    // requiring the whole signature be @MainActor, which the diarizer isn't.
                    onProgress: { progress in
                        Task { @MainActor in
                            guard rediarizing == channel else { return }
                            switch progress.phase {
                            case .decodingAudio: rediarizePhase = .decodingAudio
                            case .detectingSpeakers: rediarizePhase = .detectingSpeakers
                            }
                            rediarizeFraction = progress.fraction
                        }
                    }
                )
                await MainActor.run {
                    rediarizePhase = .rebuildingList
                    rediarizeFraction = nil
                }
                // Rebuild the rows from the rewritten transcript: labels, sample text and the
                // resolved audio offsets can all have moved. Also reload the channel-names cache
                // (#207) — the channel just re-diarized had its names cleared, and the other
                // channel is unaffected but re-reading both keeps the cache one honest snapshot
                // rather than hand-patching just the changed side.
                // Detached, matching `RenameWindowController.show`: `parseSpeakers` opens an
                // AVAudioFile per chunk to measure durations, and this `Task` inherits the view's
                // MainActor, so running it inline stalls the UI for O(chunks) file opens — right
                // when the dialog is meant to be showing progress.
                let (refreshed, namesNow) = await Task.detached(priority: .userInitiated) {
                    // minSegments: 1 — the user has just stated how many people are on this
                    // channel. Dropping one of them as "diarization noise" for being quiet
                    // contradicts the answer they gave and leaves a speaker they can see in the
                    // transcript with no row to name.
                    (
                        RenameWindowController.parseSpeakers(from: path, minSegments: 1),
                        RenameWindowController.loadChannelNames(from: path)
                    )
                }.value
                await MainActor.run {
                    if refreshed.isEmpty {
                        // The transcript HAS been rewritten at this point. Silently keeping the old
                        // rows would show a stale speaker list under a dialog that looked like it
                        // succeeded — worse than saying nothing happened.
                        rediarizeError = "Re-detection finished but the speaker list could not be reloaded."
                    } else {
                        speakers = refreshed
                    }
                    cachedChannelNames = namesNow
                    sampleIndices = [:]
                    // Drop the stated count so the stepper falls back to what the diarizer actually
                    // produced. Leaving it pinned showed "3 speakers" after a run that yielded 2,
                    // which reads as a result rather than as the request it was.
                    speakerCounts[channel] = nil
                    rediarizing = nil
                    rediarizePhase = nil
                    rediarizeStartedAt = nil
                }
            } catch is CancellationError {
                // The user asked for this. Reporting it as a failure would make Cancel look broken.
                await MainActor.run {
                    rediarizing = nil
                    rediarizePhase = nil
                    rediarizeStartedAt = nil
                }
            } catch {
                // .private: OS errors routinely embed full filesystem paths in their messages,
                // and a recording's path names the meeting.
                Logger.transcription.error("Re-diarize failed: \(error.localizedDescription, privacy: .private)")
                await MainActor.run {
                    // Only OUR errors are shown verbatim — we write those strings and they name no
                    // paths. Foundation embeds the full file path in its descriptions, and a
                    // recording's path names the meeting; this label can be on screen while the
                    // user is sharing that screen. Same reasoning as the sanitized summary errors.
                    rediarizeError = (error as? TranscriptRediarizer.RediarizeError)?.errorDescription
                        ?? "Re-detection failed. See Console for details."
                    rediarizing = nil
                    rediarizePhase = nil
                    rediarizeStartedAt = nil
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
