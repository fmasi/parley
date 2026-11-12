import SwiftUI
import AppKit
import AVFoundation
import TranscriberCore
import os

// SpeakerSample (the sample text + resolved audio location) lives in TranscriberCore
// (TranscriptRenamer.swift), shared with the CLI rename path.

/// What a Save did: the panel closes, or it stays open on the transcript's path — a new one when the session was
/// renamed but the speaker names could not be written (#357).
enum RenameSaveOutcome {
    case saved
    case notSaved(jsonPath: URL)
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
    /// On the units the user chose (`diarization_compute_units`): re-detect diarizes a whole channel in
    /// one pass, so it is where the Neural Engine's lower footprint matters most.
    @State private var diarizer = FluidAudioDiarizer(computeUnits: ConfigManager.shared.config.diarizationComputeUnits)
    /// Held so Cancel/close can abort a running re-detect. Without it the unstructured Task
    /// outlives the dialog and rewrites the transcript after the user asked it not to.
    @State private var rediarizeTask: Task<Void, Never>?
    /// The `speaker_names` already saved per channel, loaded ONCE by `RenameWindowController` when
    /// the dialog was opened, rather than re-read from disk on every "Re-detect" press (#207).
    /// Refreshed after a successful re-detect, since names may have changed (cleared on this
    /// channel; untouched on the other).
    @State private var cachedChannelNames: [String: [String: String]]
    /// Quiet voices the pipeline merged into a channel's main speaker (`clusters_absorbed`, P7),
    /// per channel. Read once when the dialog appears; a channel's entry is dropped after it is
    /// re-detected, since the user has then stated the count and absorption did not run.
    @State private var absorbedClusters: [String: Int] = [:]
    /// What the last Re-detect on each channel produced, shown under its row (P5) — so a run that
    /// found fewer speakers than asked for, or relabeled nothing, says so instead of looking done.
    @State private var rediarizeOutcomes: [String: TranscriptRediarizer.Outcome] = [:]
    /// Where the last Re-detect on each channel put the names already typed (#359): kept on a new
    /// speaker, offered as a suggestion, or neither. Worked out by `SpeakerNameCarryOver`; shown on
    /// the cards and under the channel's row.
    @State private var carryOver: [String: SpeakerNameCarryOver.Plan] = [:]
    /// The channel a re-detect rewrote whose rows then could not be reloaded (#359 review): its rows
    /// on screen carry labels the transcript no longer has. Save and Re-detect wait for a reload —
    /// names are never matched to the new labels by position (#202).
    @State private var staleRowsChannel: String?
    /// What the echo check recorded in the transcript (#244): which speaker rows it judged to be the
    /// other side's voice through the loudspeakers, and with what numbers. Loaded with the rows by
    /// `RenameWindowController` (one read, off the main thread) and again after a re-detect, which
    /// rewrites it. The copy and the people count are `EchoNotice`'s; nothing is worked out here.
    @State private var echo: EchoNotice.Findings

    /// The transcript this dialog edits. State, not a constant: a Save that renamed the session but could not write
    /// the speaker names leaves the dialog open on the transcript's new path (#357).
    @State private var jsonPath: URL
    /// The session's name as typed (#357): the part after the `HHMMSS-` timestamp, empty for an unnamed recording.
    @State private var sessionName: String
    /// A Save in progress — the session's files can take a moment to rename on a slow folder.
    @State private var saving = false
    /// Whether the recording's name is offered at all: not in the CLI's `rename-gui`, which cannot know whether the app
    /// is still finishing or summarizing the session (#357).
    let allowsSessionRename: Bool
    /// The speaker names, and the session name when it is a recording's (nil otherwise), for the transcript at the
    /// given path. The controller renames the session's files (`SessionRenamer`) before writing the names.
    let onSave: @MainActor ([String: String], String?, URL) async -> RenameSaveOutcome
    let onCancel: () -> Void
    /// The kept names not yet saved, each time they change (#359): the window asks before a close
    /// throws them away.
    let onUnsavedKeptNamesChange: ([String]) -> Void

    init(
        jsonPath: URL,
        allowsSessionRename: Bool = true,
        speakers: [SpeakerEntry],
        initialChannelNames: [String: [String: String]] = [:],
        initialEcho: EchoNotice.Findings = .none,
        onSave: @escaping @MainActor ([String: String], String?, URL) async -> RenameSaveOutcome,
        onCancel: @escaping () -> Void = {},
        onUnsavedKeptNamesChange: @escaping ([String]) -> Void = { _ in }
    ) {
        self._jsonPath = State(initialValue: jsonPath)
        self.allowsSessionRename = allowsSessionRename
        self._sessionName = State(initialValue: SessionRenamer.sessionName(ofTranscript: jsonPath) ?? "")
        self._speakers = State(initialValue: speakers)
        self._cachedChannelNames = State(initialValue: initialChannelNames)
        self._echo = State(initialValue: initialEcho)
        self.onSave = onSave
        self.onCancel = onCancel
        self.onUnsavedKeptNamesChange = onUnsavedKeptNamesChange
    }

    /// Ask before a Cancel, Escape or a window close throws away kept names not yet saved (#359).
    /// True to go ahead. No names, no question.
    @MainActor
    static func confirmDiscard(names: [String]) -> Bool {
        guard !names.isEmpty else { return true }
        let copy = SpeakerNameCarryOver.discardConfirmation(names: names)
        let alert = NSAlert()
        alert.messageText = copy.title
        alert.informativeText = copy.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: copy.keep)
        alert.addButton(withTitle: copy.discard)
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Channels present in this recording, in display order.
    private var channels: [String] {
        var seen: [String] = []
        // Via `channel(of:)`, not the label prefix: once a speaker has been renamed its label is
        // the name the user typed, not "Remote Speaker 1", so a prefix test finds no channels and the
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
        //
        // PEOPLE, not rows (#244): a row judged to be the other side's voice through the
        // loudspeakers is not somebody on this channel, and a stated count does not include it.
        // Pre-filling the number of rows offered "2" for the user plus an echo voice.
        echo.people(on: channel, rows: speakers.filter { self.channel(of: $0) == channel }.map(\.id))
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
                                .disabled(rediarizing != nil || staleRowsChannel != nil)
                        }
                    }
                    if let absorbed = absorbedClusters[channel], absorbed > 0 {
                        Text(absorbed == 1
                             ? "1 quiet voice was merged into the main speaker — set a count and Re-detect to undo"
                             : "\(absorbed) quiet voices were merged into the main speaker — set a count and Re-detect to undo")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let outcome = rediarizeOutcomes[channel] {
                        Text(EchoNotice.redetectOutcome(outcome))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let names = carryOver[channel].flatMap(SpeakerNameCarryOver.outcome) {
                            Text(names)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if let hint = echo.redetectHint(on: channel) {
                        // Before a re-detect: why the count is one less than the rows above, and
                        // what a re-detect does with an echo voice (#244).
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let rediarizeError {
                    Text(rediarizeError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let stale = staleRowsChannel {
                    Button("Reload Speakers") { reloadRows(after: stale) }
                        .font(.caption)
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

    /// The names on this channel's rows a re-detect has to place again: those already written to the
    /// transcript (the row's label is then the name) and those typed into a field but not yet saved.
    /// Both count (#359). In row order.
    private func names(on channel: String) -> [String] {
        let rows = speakers.filter { self.channel(of: $0) == channel }
        let fields = Dictionary(rows.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let typed = SpeakerNameCarryOver.names(fields: fields, oldLabels: [])
        var names: [String] = []
        for row in rows { if let name = typed[row.id], !names.contains(name) { names.append(name) } }
        return names
    }

    /// Whether a re-detect on this channel has names to place: on its rows, or saved for a speaker
    /// too quiet for a row. The saved ones come from the cache loaded once when the dialog appeared,
    /// not a fresh read of the transcript (#207) — `recording_directory` can be network- or
    /// iCloud-backed, and a synchronous read on every button press blocks the main thread for as
    /// long as the mount takes to answer.
    private func hasNames(on channel: String) -> Bool {
        !names(on: channel).isEmpty || !(cachedChannelNames[channel] ?? [:]).isEmpty
    }

    /// Ask before re-detecting a channel that has names (#202, #359).
    ///
    /// Re-detecting produces a new set of clusters, numbered afresh, so a name cannot follow its
    /// label. After the re-detect each name goes where the SPEECH it was typed on went
    /// (`SpeakerNameCarryOver`): kept where the voice clearly matches, otherwise offered as a
    /// suggestion, never filled in. Which name lands where is only known once the voices are worked
    /// out again, so this states the rule, and the cards and the channel's row say the result.
    /// Cancel touches nothing: the transcript is only rewritten inside `rediarize`.
    private func confirmThenRediarize(channel: String, count: Int) {
        guard hasNames(on: channel) else {
            rediarize(channel: channel, count: count)
            return
        }
        let copy = SpeakerNameCarryOver.confirmation(channel: channel, names: names(on: channel))
        let alert = NSAlert()
        alert.messageText = copy.title
        alert.informativeText = copy.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Re-detect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        rediarize(channel: channel, count: count)
    }

    private func rediarize(channel: String, count: Int) {
        rediarizing = channel
        rediarizeError = nil
        rediarizeOutcomes[channel] = nil
        // `carryOver[channel]` stays until this run succeeds: a failed or cancelled run leaves the
        // rows, and their suggestions, as they were (#359 review).
        rediarizePhase = nil
        rediarizeFraction = nil
        rediarizeStartedAt = Date()
        stopPlayback()
        let path = jsonPath
        rediarizeTask = Task {
            do {
                let outcome = try await TranscriptRediarizer.rediarize(
                    transcript: path,
                    source: channel,
                    speakerCount: count,
                    diarizer: diarizer,
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
                // minSegments: 1 — the user has just stated how many people are on this channel.
                // Dropping one of them as "diarization noise" for being quiet contradicts the
                // answer they gave and leaves a speaker they can see in the transcript with no row
                // to name. A single combined read (not two independent ones) for the same reason
                // as `RenameWindowController.show` — one round trip to what can be an
                // iCloud-mounted path instead of two.
                // What the echo check recorded comes from the same read: the re-detect has just
                // rewritten this channel's verdicts and labels (#244).
                let (refreshed, namesNow, echoNow) = await Task.detached(priority: .userInitiated) {
                    RenameWindowController.parseSpeakersAndChannelNames(from: path, minSegments: 1)
                }.value
                await MainActor.run {
                    if refreshed.isEmpty {
                        // The transcript HAS been rewritten at this point. Silently keeping the old
                        // rows would show a stale speaker list under a dialog that looked like it
                        // succeeded — worse than saying nothing happened.
                        rediarizeError = "Re-detection finished but the speaker list could not be reloaded."
                        // The rows on screen carry labels the transcript no longer has: no name is
                        // carried, and none is matched to the new labels by position (#202). The
                        // channel's fields go back to their labels; Save and Re-detect wait for a
                        // reload.
                        carryOver[channel] = nil
                        speakers = speakers.map { row in
                            guard self.channel(of: row) == channel else { return row }
                            var row = row
                            row.displayName = row.id
                            return row
                        }
                        staleRowsChannel = channel
                    } else {
                        // The names go where their speech went (#359), from the fields as they are
                        // NOW — typed during the re-detect included — and the echo findings from
                        // before it: a name typed on an echo row is never carried. An earlier
                        // re-detect's suggestions nobody took are reported again, not dropped.
                        let plan = SpeakerNameCarryOver.plan(
                            outcome.labelOverlap, fields: fields(on: channel), echo: echo, previous: carryOver[channel])
                        carryOver[channel] = plan
                        let fields = SpeakerNameCarryOver.fields(
                            rows: refreshed.map { ($0.id, self.channel(of: $0)) },
                            previous: Dictionary(speakers.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first }),
                            redetected: channel, plan: plan)
                        speakers = refreshed.map { row in
                            var row = row
                            row.displayName = fields[row.id] ?? row.id
                            return row
                        }
                        Logger.state.info(
                            "Re-detect kept \(plan.kept.count, privacy: .public) name(s) on \(channel, privacy: .public); \(plan.notKept.count, privacy: .public) not kept, \(plan.suggestions.count, privacy: .public) speaker(s) with a suggestion")
                    }
                    cachedChannelNames = namesNow
                    // Only from a transcript that was read: an unreadable one answers "no echo",
                    // which would drop the notices from the rows still on screen.
                    if !refreshed.isEmpty { echo = echoNow }
                    absorbedClusters[channel] = nil
                    rediarizeOutcomes[channel] = outcome
                    sampleIndices = [:]
                    // Drop the stated count so the stepper falls back to what the diarizer actually
                    // produced. Leaving it pinned showed "3 speakers" after a run that yielded 2,
                    // which reads as a result rather than as the request it was.
                    speakerCounts[channel] = nil
                    rediarizing = nil
                    rediarizePhase = nil
                    rediarizeFraction = nil
                    rediarizeStartedAt = nil
                }
            } catch is CancellationError {
                // The user asked for this. Reporting it as a failure would make Cancel look broken.
                await MainActor.run {
                    rediarizing = nil
                    rediarizePhase = nil
                    rediarizeFraction = nil
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
                    rediarizeFraction = nil
                    rediarizeStartedAt = nil
                }
            }
        }
    }

    /// The name fields of a channel's rows, by row label.
    private func fields(on channel: String) -> [String: String] {
        let rows = speakers.filter { self.channel(of: $0) == channel }
        return Dictionary(rows.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    /// Read the rows again after a re-detect whose reload failed (#359 review). The re-detected
    /// channel's rows come back with their labels in the fields — no carry-over; the other
    /// channel's fields keep what was typed.
    private func reloadRows(after channel: String) {
        let path = jsonPath
        rediarizeError = nil
        Task {
            let (refreshed, namesNow, echoNow) = await Task.detached(priority: .userInitiated) {
                RenameWindowController.parseSpeakersAndChannelNames(from: path, minSegments: 1)
            }.value
            await MainActor.run {
                guard !refreshed.isEmpty else {
                    rediarizeError = "The speaker list could not be reloaded."
                    return
                }
                let fields = SpeakerNameCarryOver.fields(
                    rows: refreshed.map { ($0.id, self.channel(of: $0)) },
                    previous: Dictionary(speakers.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first }),
                    redetected: channel, plan: .none)
                speakers = refreshed.map { row in
                    var row = row
                    row.displayName = fields[row.id] ?? row.id
                    return row
                }
                cachedChannelNames = namesNow
                echo = echoNow
                sampleIndices = [:]
                staleRowsChannel = nil
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

            sessionNameSection

            ForEach($speakers) { $speaker in
                speakerCard($speaker)
            }

            speakerCountSection

            HStack {
                Spacer()
                Button("Cancel") {
                    // Escape lands here too (`.cancelAction`). Kept names not yet saved are asked about (#359).
                    guard Self.confirmDiscard(names: SpeakerNameCarryOver.unsavedKeptNames(in: carryOver)) else { return }
                    rediarizeTask?.cancel()
                    onCancel()
                }
                    .keyboardShortcut(.cancelAction)
                    // Not while a Save renames the session's files (#357): the panel closes when it is done.
                    .disabled(saving)
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
                    stopPlayback()
                    saving = true
                    let name = allowsSessionRename && SessionRenamer.sessionName(ofTranscript: jsonPath) != nil
                        ? sessionName : nil
                    let path = jsonPath
                    Task {
                        if case .notSaved(let now) = await onSave(mapping, name, path) {
                            if now != path {
                                // The session was renamed, the names not written: the samples' audio has new names.
                                speakers = speakers.map { Self.relocatingSamples(of: $0, from: path, to: now) }
                            }
                            jsonPath = now
                            saving = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                // Saving mid-re-detect is a lost-work race: onSave writes the speaker names, the
                // dialog closes, and a re-diarization already past its last cancellation check then
                // rewrites the whole transcript — wiping the names that were just applied.
                .disabled(rediarizing != nil || saving || staleRowsChannel != nil)
            }
        }
        .padding(20)
        .frame(width: 400)
        .modifier(GlassBackgroundModifier(cornerRadius: 12))
        .onChange(of: carryOver) { _, plans in
            onUnsavedKeptNamesChange(SpeakerNameCarryOver.unsavedKeptNames(in: plans))
        }
        .task {
            // Off the main actor: a long meeting's transcript is several hundred KB.
            let path = jsonPath
            absorbedClusters = await Task.detached(priority: .userInitiated) {
                Self.absorbedClusterCounts(in: path)
            }.value
        }
        .onDisappear {
            // The last preview would otherwise linger: it is only cleaned up when the NEXT one is
            // created, and closing the dialog is the common exit.
            rediarizeTask?.cancel()
            stopPlayback()
            previousPreview.map { try? FileManager.default.removeItem(at: $0) }
            previousPreview = nil
        }
    }

    /// The recording's name (#357), above the speakers: editable, with the `HHMMSS-` timestamp shown and kept. Saving a
    /// new one renames every file of the recording. Hidden for a transcript that is not a recording's.
    @ViewBuilder
    private var sessionNameSection: some View {
        if allowsSessionRename, let current = SessionRenamer.sessionName(ofTranscript: jsonPath),
           let stamp = SessionRenamer.sessionId(ofTranscript: jsonPath)?.prefix(6) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recording name")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text("\(stamp)-")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                    TextField("Name", text: $sessionName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(rediarizing != nil || saving)
                }
                if sessionName.trimmingCharacters(in: .whitespacesAndNewlines) != current {
                    Text("Saving renames the recording’s audio, transcript and summary files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// `entry` with each sample's audio file under the name a session rename gave it (#357).
    private static func relocatingSamples(of entry: SpeakerEntry, from old: URL, to new: URL) -> SpeakerEntry {
        SpeakerEntry(id: entry.id, displayName: entry.displayName, samples: entry.samples.map { sample in
            SpeakerSample(text: sample.text,
                          audioFile: sample.audioFile.map { SessionRenamer.relocated($0, from: old, to: new) },
                          start: sample.start, end: sample.end, isLocal: sample.isLocal)
        })
    }

    /// Per channel, how many minority clusters the pipeline absorbed into the dominant speaker, from
    /// the transcript's `metadata.processing_issues` (`clusters_absorbed` entries, summed across
    /// chunks). Empty when absent or unreadable.
    nonisolated static func absorbedClusterCounts(in jsonPath: URL) -> [String: Int] {
        guard let data = try? Data(contentsOf: jsonPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = root["metadata"] as? [String: Any],
              let issues = metadata["processing_issues"] as? [[String: Any]]
        else { return [:] }
        var counts: [String: Int] = [:]
        for issue in issues where issue["code"] as? String == ChunkIssue.Code.clustersAbsorbed.rawValue {
            guard let track = issue["track"] as? String else { continue }
            counts[track, default: 0] += issue["count"] as? Int ?? 1
        }
        return counts
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

            // The echo check judged this row to be the other side's voice through the loudspeakers,
            // not a person on this side (#244): said above the name field, before anyone names it.
            if let notice = echo.cardNotice(forRow: speakerId) {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // What a re-detect did with the names typed before it (#359): a kept name says so, and a
            // name that was not kept is offered, never filled in.
            let plan = channel(of: speaker.wrappedValue).flatMap { carryOver[$0] }
            if let plan, let note = SpeakerNameCarryOver.cardNote(
                forRow: speakerId, field: speaker.wrappedValue.displayName, plan: plan) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Name", text: speaker.displayName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { stopPlayback() }
                .onChange(of: speaker.wrappedValue.displayName) { _, _ in stopPlayback() }

            if let suggested = plan?.suggestions[speakerId], !suggested.isEmpty {
                HStack(spacing: 6) {
                    Text("Suggested:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(suggested, id: \.self) { name in
                        Button(name) { speaker.wrappedValue.displayName = name }
                            .font(.caption)
                            .controlSize(.small)
                            .help("Use this name")
                    }
                }
            }

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
            Logger.audio.error("playSample: \(String(describing: error), privacy: .private)")
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
