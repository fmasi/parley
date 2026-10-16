import AVFoundation
import Foundation
import os

/// Re-runs diarization on ONE channel of an existing recording at a user-stated speaker count,
/// and rewrites the transcript with the result (#67).
///
/// Why this exists at all: the diarizer's speaker count is a guess, and it is wrong in both
/// directions. On 2026-08-26 it invented a second remote speaker out of 28s of fragments; on
/// 2026-09-02 it collapsed two people sharing a speakerphone into one. `DiarizationCleanup` fixes
/// the first automatically. Nothing automatic fixes the second — only the person who was there
/// knows how many people were talking — so this is the manual override, offered *after* the
/// recording when the user can see the speaker list is wrong.
public enum TranscriptRediarizer {

    /// Replace one source's segments with a freshly labeled set, keeping the other source as-is.
    ///
    /// Not a 1:1 relabel: word-level boundary splitting (#120) can turn one ASR segment into two
    /// when a speaker change lands mid-segment — measured 73 → 84 segments on a speakerphone call
    /// with two people on one mic — so the target source is replaced wholesale rather than patched
    /// in place.
    public static func mergeRelabeled(
        into segments: [[String: Any]],
        source: String,
        relabeled: [LabeledSegment]
    ) -> [[String: Any]] {
        // Flagged segments (`filtered` / `echo` / `duplicate`, or no usable time) on this channel are
        // kept as they are given: they are not relabeled here, and replacing the channel wholesale
        // must not drop them (P10/P11, R2b item 5). `rediarize` sets their label first (#296).
        var kept = segments.filter { ($0["source"] as? String) != source || TranscriptAssembler.isFlagged($0) }
        kept.append(contentsOf: relabeled.map { seg in
            var dict: [String: Any] = [
                "start": seg.start,
                "end": seg.end,
                "speaker": seg.speaker,
                "source": seg.source,
                "text": seg.text,
            ]
            if let confidence = seg.confidence { dict["confidence"] = confidence }
            if let language = seg.language { dict["language"] = language }
            // Same rule as TranscriptAssembler: a flag is written when set, never silently dropped.
            if seg.filtered { dict["filtered"] = true }
            if seg.echo { dict["echo"] = true }
            if seg.duplicate { dict["duplicate"] = true }
            return dict
        })
        // Timed segments in time order; a segment with no usable time is never placed at 0 — it
        // follows them, in its original order.
        let timed = kept.filter(TranscriptAssembler.hasUsableTime)
            .sorted { ($0["start"] as? Double ?? 0) < ($1["start"] as? Double ?? 0) }
        return timed + kept.filter { !TranscriptAssembler.hasUsableTime($0) }
    }

    /// Metadata key holding the names a re-detect cleared, so a mistaken one is recoverable.
    static let previousNamesKey = "speaker_names_previous"

    private static func labelPrefix(for source: String) -> String {
        source == "local" ? "Local " : "Remote "
    }

    /// The `speaker_names` entries belonging to one channel.
    ///
    /// Speaker labels are channel-prefixed, so the prefix is the whole of the ownership test. The
    /// dialog uses this to decide whether re-detecting has anything to destroy, and therefore
    /// whether to ask first.
    public static func channelNames(in metadata: [String: Any], source: String) -> [String: String] {
        let names = metadata["speaker_names"] as? [String: String] ?? [:]
        let prefix = labelPrefix(for: source)
        return names.filter { $0.key.hasPrefix(prefix) }
    }

    /// The names stored for one channel in a transcript on disk.
    ///
    /// Only used to decide whether a re-detect has anything to destroy, and therefore whether to
    /// ask first — an unreadable file yields no names, because the re-diarize that follows will
    /// fail on its own read and report it properly.
    public static func channelNames(inTranscriptAt url: URL, source: String) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = json["metadata"] as? [String: Any]
        else { return [:] }
        return channelNames(in: metadata, source: source)
    }

    /// Clear the re-diarized channel's speaker names, stashing them under `speaker_names_previous`.
    ///
    /// Names are NOT carried across a re-detect, and this is deliberate (#202). Speaker numbering
    /// is positional: "Remote Speaker 1" after a fresh clustering is whichever cluster that run
    /// happened to emit first, which can easily be a different person. Keeping a name because its
    /// key survived therefore re-points it at a voice nobody chose it for — silent mislabelling of
    /// a record this product asks people to rely on. Losing a name is recoverable in seconds from
    /// the rows on screen; a name attached to the wrong voice is not recoverable at all, because
    /// nothing about it looks wrong.
    ///
    /// The cleared map is stashed rather than discarded so a mistaken re-detect leaves a trail, and
    /// it MERGES into any existing stash — overwriting would throw away the other channel's history
    /// (the #162 mistake, in a new place). Where the same key appears twice the newer name wins: the
    /// stash is a recovery aid, and the most recent answer is the one worth recovering.
    ///
    /// The other channel is untouched, and a channel with no names is left exactly as it was — no
    /// empty stash key appears in a file people read.
    public static func clearingChannelNames(in metadata: [String: Any], source: String) -> [String: Any] {
        let cleared = channelNames(in: metadata, source: source)
        guard !cleared.isEmpty else { return metadata }

        var metadata = metadata
        let names = metadata["speaker_names"] as? [String: String] ?? [:]
        let prefix = labelPrefix(for: source)
        let kept = names.filter { !$0.key.hasPrefix(prefix) }
        if kept.isEmpty {
            metadata["speaker_names"] = nil
        } else {
            metadata["speaker_names"] = kept
        }

        var previous = metadata[previousNamesKey] as? [String: String] ?? [:]
        previous.merge(cleared) { _, newer in newer }
        metadata[previousNamesKey] = previous
        return metadata
    }

    // MARK: - Orchestration

    public struct Outcome: Sendable {
        /// The people found on the channel: its labels that are neither "Unknown" nor an echo cluster.
        public let speakerCount: Int
        /// The unflagged lines this re-detect gave a label to.
        public let segmentsRelabeled: Int
        /// The raw clusters on this channel the echo check judged to be the other side's voice
        /// through the speakers, and kept out of the merge (#243). 0 when the check did not run
        /// (the remote channel).
        public let echoClusters: Int
        /// The lines on this channel that check flagged `echo`, those that already carried the flag
        /// and were confirmed included. 0 when the check did not run.
        public let echoFlagged: Int
    }

    /// A coarse phase report for a running `rediarize`, so a caller can show more than a bare
    /// spinner on a call that can take minutes (#203). `fraction`, when present, is 0...1 within
    /// the CURRENT phase — chunk-splitting is trivially countable (N of M chunks), and the
    /// diarizer backend also reports its own chunk progress during `detectingSpeakers`.
    public struct Progress: Sendable, Equatable {
        public enum Phase: Sendable, Equatable {
            /// Decoding the channel's audio to mono samples (the old "splitting + concatenating").
            case decodingAudio
            /// Running the diarizer over the decoded samples.
            case detectingSpeakers
        }
        public let phase: Phase
        public let fraction: Double?

        public init(phase: Phase, fraction: Double? = nil) {
            self.phase = phase
            self.fraction = fraction
        }
    }

    public enum RediarizeError: LocalizedError {
        case unreadableTranscript
        case noAudioForChannel(String)
        case invalidSpeakerCount(Int)
        case producedNoLabels(String)
        /// A chunk listed in `audio_paths` is not on disk: its 1-based position and the chunk count.
        /// By position, never file name — file names name the meeting and this text reaches the UI.
        case chunkMissing(chunk: Int, of: Int)
        /// A chunk that contributes silence to this channel has no known length (not recorded, and
        /// its file cannot be read): 1-based position and the chunk count.
        case chunkDurationUnknown(chunk: Int, of: Int)
        /// The recording has capture gaps and the chunks' wall-clock offsets were not recorded, so
        /// its timeline cannot be rebuilt without shifting every chunk after a gap.
        case timelineUnknown
        /// The chunks' recorded wall-clock offsets are not ones this recording could have (non-finite,
        /// negative, or beyond its audio plus its gaps) — the timing WAS recorded, but looks
        /// inconsistent.
        case chunkTimingImplausible

        public var errorDescription: String? {
            switch self {
            case .chunkMissing(let chunk, let total):
                return "Chunk \(chunk) of \(total) is missing — re-detect cannot rebuild the timeline without it."
            case .chunkDurationUnknown(let chunk, let total):
                return "The length of chunk \(chunk) of \(total) is unknown — re-detect cannot rebuild the timeline without it."
            case .chunkTimingImplausible:
                return "The recording's chunk timing looks corrupted, so re-detect can't place the audio safely."
            case .timelineUnknown:
                return "This recording has capture gaps and its chunk timing was not recorded — re-detect cannot rebuild the timeline."
            case .unreadableTranscript: return "Could not read the transcript."
            case .noAudioForChannel(let c): return "No \(c) audio is available for this recording."
            case .invalidSpeakerCount(let n): return "\(n) is not a valid number of speakers."
            case .producedNoLabels(let c): return "Re-detection found no speech on the \(c) channel; the transcript is unchanged."
            }
        }
    }

    /// Re-diarize one channel at `speakerCount` and rewrite the transcript in place.
    ///
    /// **Relabels only — it does not re-run ASR.** The words stay exactly as recorded; only speaker
    /// attribution changes. Re-transcribing would produce marginally better turn boundaries (word
    /// timings let #120 split a segment where a speaker change lands mid-sentence), but silently
    /// rewriting what was *said* to fix who said it is the wrong trade for a record people rely on.
    ///
    /// **On the mic channel the echo check runs before the count is enforced (#243).** With the far
    /// side on loudspeakers its voice comes back through the mic and the diarizer finds it as a
    /// cluster of its own. "One speaker on this side" then merged that cluster into the user: on a
    /// real call about 2,400 of the other participant's words took the user's name. So
    /// `EchoDeduplicator` judges the RAW clusters first, and a cluster it calls echo is kept out of
    /// the merge: its matched lines are flagged `echo`, the rest stay under its own label, and it is
    /// not counted as a person. It never refuses — the count is enforced on everything else — and
    /// re-detecting a transcript that was merged that way takes the echo voice back out.
    public static func rediarize(
        transcript url: URL,
        source: String,
        speakerCount: Int,
        diarizer: any DiarizationProvider,
        scratchDirectory: URL = FileManager.default.temporaryDirectory,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Outcome {
        try await rediarize(transcript: url, source: source, speakerCount: speakerCount, diarizer: diarizer,
                            scratchDirectory: scratchDirectory, onProgress: onProgress, rawLabeling: label)
    }

    /// `rediarize`, with the echo check's labelling step as a parameter — only so a test can make it
    /// lose a segment and see the check stand down.
    static func rediarize(
        transcript url: URL,
        source: String,
        speakerCount: Int,
        diarizer: any DiarizationProvider,
        scratchDirectory: URL = FileManager.default.temporaryDirectory,
        onProgress: (@Sendable (Progress) -> Void)? = nil,
        rawLabeling: Labeling
    ) async throws -> Outcome {
        // Refuse before touching anything. A non-positive count is not merely ignored downstream:
        // `FluidAudioDiarizer` correctly treats <= 0 as "unforced", but we still pass
        // `speakerCountIsUserStated: true` below, which DISABLES minority absorption — leaving
        // unforced diarization with the automatic cleanup switched off, which is neither of the two
        // behaviours anyone asked for.
        guard speakerCount > 0 else { throw RediarizeError.invalidSpeakerCount(speakerCount) }

        // Read and parse SEPARATELY, and let the read throw: flattening permission-denied,
        // quota-exceeded and deleted-mid-run into one message of our own left a failure report
        // with no way to name its own cause.
        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard var json = parsed as? [String: Any],
              let rawSegments = json["segments"] as? [[String: Any]]
        else { throw RediarizeError.unreadableTranscript }

        var metadata = json["metadata"] as? [String: Any] ?? [:]
        let audioPaths = (metadata["audio_paths"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
        let layout = SpeakerSampleLocator.classify(audioPaths: audioPaths)
        // One entry per `audio_paths` element: `chunk_durations` stamped at archive time (#204;
        // 0 = unreadable then), `chunk_offsets` the wall-clock seconds from the meeting start the
        // transcript placed each at (finalize).
        let chunkDurations = metadata["chunk_durations"] as? [Double] ?? []
        let chunkOffsets = metadata["chunk_offsets"] as? [Double]
        let hasCaptureGaps = !((metadata["capture"] as? [String: Any])?["gaps"] as? [Any] ?? []).isEmpty
        // Recorded periods with no capture: part of the timeline the offsets may legitimately span
        // (validated and capped in `timelineBound`).
        let gapSeconds = ((metadata["capture"] as? [String: Any])?["gaps"] as? [[String: Any]] ?? [])
            .compactMap { $0["seconds"] as? Double }

        // Decode ONCE, at the target format (16 kHz mono Float), and hand that buffer to the
        // diarizer (#204) — the old path decoded the channel's audio up to four separate times
        // (split, concatenate, diarizer's own decode, VAD's own decode).
        //
        // `.legacyDualStream` is a single file with nothing to concatenate, so there is no
        // decode-reuse to be had there: our own `AudioDecode` pass would just add a full extra
        // in-memory copy (~3x the file's decoded size, once for the native-rate read and again
        // for the resample) on top of what the diarizer already holds internally. Handing it the
        // path instead lets it stream the file with FluidAudio's own decoder, matching the
        // pre-#204 memory profile for this case — and, as a side effect, keeps the `AudioDecode`
        // reimplementation (see its doc comment) out of the picture entirely for single-file
        // recordings, which is most of them.
        onProgress?(Progress(phase: .decodingAudio))
        let decoded = try await decodeChannelAudio(
            layout: layout, source: source, chunkDurations: chunkDurations, chunkOffsets: chunkOffsets,
            hasCaptureGaps: hasCaptureGaps, gapSeconds: gapSeconds, scratchDirectory: scratchDirectory,
            onProgress: onProgress)

        // The user's answer is authoritative: force the count AND skip minority absorption, which
        // exists to second-guess a count nobody supplied.
        // Decoding the channel can be the slowest phase on a multi-chunk recording; without a
        // check here a cancel during that work goes unnoticed until a full diarize has also run.
        try Task.checkCancellation()
        onProgress?(Progress(phase: .detectingSpeakers))
        let raw: DiarizationResult
        switch decoded {
        case .samples(let samples):
            raw = try await diarizer.diarize(
                audio: samples, numSpeakers: speakerCount,
                progress: { processed, total in
                    guard total > 0 else { return }
                    onProgress?(Progress(phase: .detectingSpeakers, fraction: Double(processed) / Double(total)))
                })
        case .path(let audioURL):
            // No pre-decoded buffer to share here (see the comment above) — each backend decodes
            // its own copy, same as before #204 for this layout. No per-chunk progress fraction is
            // available on this route either, but the coarser phase indicator still applies.
            raw = try await diarizer.diarize(audioPath: audioURL, numSpeakers: speakerCount)
        }
        // The diarizer's "forced" count is a target, not a ceiling — asking for 1 on an 82-minute
        // call still returned 2 (#201). Enforce it here, where the clusters and their embeddings
        // are both in hand, rather than hoping the clusterer honours the request.
        //
        // But first, on the mic channel, find the clusters that are not a person on this side at
        // all (#243): the echo check runs on the RAW clusters, and those it judges echo are kept out
        // of the merge. Enforcing first would fold the other side's voice into the stated speaker.
        let candidates = relabelCandidates(in: rawSegments, source: source)
        var echo = source == "local" ? echoCheck(on: candidates, raw: raw, transcript: rawSegments, labeling: rawLabeling) : nil
        // With the check, every candidate is labeled — a line already flagged `echo` needs its
        // cluster's new label too. Without it, only the unflagged lines, as before the check existed.
        func relabel() -> (pool: [Candidate], labeled: [LabeledSegment]) {
            let pool = echo == nil ? candidates.filter { !$0.wasEcho } : candidates
            let diarization = SpeakerCountEnforcer.enforce(raw, to: speakerCount, keeping: echo?.clusterIDs ?? [])
            return (pool, label(pool.map(\.segment), against: diarization).labeled)
        }
        var (pool, labeled) = relabel()
        if echo != nil, labeled.count != pool.count {
            // The check's verdicts are put on the lines by position. Not reachable while its own
            // labelling was one-to-one (this is the same function over the same segments); if it
            // ever is, the flags must not land on the wrong lines.
            Logger.transcription.error(
                "Re-diarize: \(labeled.count, privacy: .public) labels for \(pool.count, privacy: .public) segments — relabelling without the echo check")
            echo = nil
            (pool, labeled) = relabel()
        }
        try Task.checkCancellation()

        // `mergeRelabeled` replaces the channel WHOLESALE, so an empty relabeling would delete every
        // segment this channel had. That is never the right outcome for a transcript that demonstrably
        // contained speech a moment ago: it means diarization or VAD returned nothing, and losing the
        // words is far worse than leaving the speaker labels as they were.
        guard !labeled.isEmpty || pool.isEmpty else {
            Logger.transcription.error(
                "Re-diarize produced no labels for \(source, privacy: .public) from \(pool.count, privacy: .public) segments — refusing to write")
            throw RediarizeError.producedNoLabels(source)
        }
        // Before the source prefix goes on, while labels are still raw: a stated count of 1 means
        // every word on this channel belongs to that one person, including the ones the assigner
        // could not tie to a diarization turn — but never to an echo cluster, and not at all when
        // the unattributed speech was itself judged echo.
        let echoClusterLabels = echo.map { echo in Set(pool.indices.filter(echo.isInEchoCluster).map { labeled[$0].speaker }) } ?? []
        labeled = SpeakerCountEnforcer.foldUnattributed(labeled, statedCount: speakerCount, keeping: echoClusterLabels)
        for i in labeled.indices { labeled[i].source = source }
        SpeakerAssignment.tagWithSourcePrefix(&labeled)

        let unattributed = labelPrefix(for: source) + SpeakerAssignment.unknownSpeaker
        var segments = rawSegments
        // One rule for every line on this channel that is already flagged (`filtered`, `echo`,
        // `duplicate`, no usable time), on either channel and whether or not the echo check runs
        // (#296): it takes the channel's unattributed label, which nothing counts as a person or a
        // voice. Its old label comes from an earlier clustering (and perhaps a rename); speaker
        // numbers are positional, so after this re-detect that label can be somebody else's. The
        // flag itself stays. The only exception is below: an echo line the check puts in an echo
        // cluster carries that cluster's label, which this pass has just given it.
        for i in segments.indices where segments[i]["source"] as? String == source && TranscriptAssembler.isFlagged(segments[i]) {
            segments[i]["speaker"] = unattributed
        }
        // Raw cluster label → the label its lines carry in the rewritten transcript.
        var finalLabels: [String: String] = [:]
        if let echo {
            // What the check found, line by line (#243):
            // - a line of an echo cluster carries that cluster's own label; its matched lines are
            //   flagged, the rest are not — nothing of it is given to the stated speaker;
            // - elsewhere, a flagged line (a match of 3+ words) is not given to the stated speaker,
            //   and does not keep the label it had either (#277): it is the other side's words, and
            //   after a repair the old label is the user's. It takes the channel's unattributed
            //   label, like every other flagged line on the channel (#296). A line that already
            //   carried the flag keeps it, and is labelled by the same rule.
            // The flag is one-way: a later re-detect whose clustering no longer judges that line
            // echo does not clear it, so the line stays hidden. A re-detect cannot un-mark echo.
            var relabeled: [LabeledSegment] = []
            for (i, candidate) in pool.enumerated() {
                finalLabels[echo.rawLabels[i]] = labeled[i].speaker
                if candidate.wasEcho {
                    segments[candidate.index]["speaker"] = echo.isInEchoCluster(i) ? labeled[i].speaker : unattributed
                    continue
                }
                var line = labeled[i]
                if echo.result.segments[i].echo {
                    line.echo = true
                    if !echo.isInEchoCluster(i) { line.speaker = unattributed }
                }
                relabeled.append(line)
            }
            labeled = relabeled
        }
        segments = mergeRelabeled(into: segments, source: source, relabeled: labeled)
        json["segments"] = segments
        // The channel's names go, they are not carried over — see `clearingChannelNames`. The
        // dialog warns before reaching here, so this is never a surprise.
        metadata = clearingChannelNames(in: metadata, source: source)
        // Persist what the diarizer actually PRODUCED, not what was requested. They diverge — on
        // 2026-09-02 a request for 2 could yield 1 — and a stored request would misreport the
        // transcript's own contents to anything reading it back, including the stepper's pre-fill.
        // It counts PEOPLE. "Unknown" is an absence of attribution, not a person: counting it told
        // the stepper there were 2 speakers on a channel holding one speaker plus some
        // unattributable backchannels. An echo cluster is the other side's voice, not a person on
        // this one (#243). A label that only flagged lines carry is not counted either.
        // Built from `labelPrefix(for:)` so the channel-prefix format lives in one place. Note this
        // is a runtime string comparison, NOT a compile-time guarantee: if `tagWithSourcePrefix`
        // ever stops using "<Prefix><Unknown>", this silently over-counts again, so the two must
        // change together.
        let visible = labeled.filter { !$0.isFlagged }
        let echoClusters = Set((echo?.echoLabels ?? []).compactMap { finalLabels[$0] })
        let found = Set(visible.map(\.speaker)).subtracting([unattributed]).subtracting(echoClusters).count
        metadata["speaker_count_\(source)"] = found
        // Which channels a re-detect has rewritten: their labels are no longer the pipeline's.
        var rediarized = metadata[rediarizedChannelsKey] as? [String] ?? []
        if !rediarized.contains(source) { rediarized.append(source) }
        metadata[rediarizedChannelsKey] = rediarized
        // The stated count undid any minority absorption on this channel: its `clusters_absorbed`
        // issue no longer describes the transcript (and would keep the rename dialog's hint alive).
        // Not content-affecting, so the processing counts do not change. The same goes for what an
        // earlier pass said about echo on this track, once the check has run again.
        var stale: Set<String> = [ChunkIssue.Code.clustersAbsorbed.rawValue]
        if let echo {
            stale.formUnion([ChunkIssue.Code.echoFlagged.rawValue, ChunkIssue.Code.echoCluster.rawValue])
            // One entry per raw cluster, under the label its lines now carry, and no `chunk`: the
            // check ran over the whole channel. Clusters the count merged share a label.
            let verdicts = (metadata["echo_clusters"] as? [[String: Any]] ?? []).filter { $0["track"] as? String != source }
            metadata["echo_clusters"] = verdicts + echo.result.clusters.map {
                $0.metadataDictionary(track: source, chunk: nil) { finalLabels[$0] ?? $0 }
            }
            TranscriptAssembler.stampEchoFlagged(segments.filter { $0["echo"] as? Bool == true }.count, in: &metadata)
        }
        if let issues = metadata["processing_issues"] as? [[String: Any]] {
            metadata["processing_issues"] = issues.filter {
                !(stale.contains($0["code"] as? String ?? "") && $0["track"] as? String == source)
            } + (echo?.result.issues ?? []).map { $0.metadataDictionary(chunk: nil) }
        }
        json["metadata"] = metadata

        // Last check before the only irreversible step. Cancelling after diarization has run just
        // wastes the work; cancelling after this leaves a transcript the user asked us not to write.
        try Task.checkCancellation()
        try TranscriptWrites.exclusive(url) {
            // The file was read before diarization, which can take minutes: a storage-limit pass may
            // have marked it since (#224). Keep the mark on disk now, not the one read then.
            let onDisk = (try? Data(contentsOf: url))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["metadata"] as? [String: Any]
            metadata[TranscriptAudioMark.key] = onDisk?[TranscriptAudioMark.key]
            json["metadata"] = metadata
            let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            // Keep the transcript as the pipeline wrote it (P5): written once, before the FIRST
            // re-detect, and never overwritten — after two re-detects the original labels would
            // otherwise be gone. If it cannot be written, the transcript is not overwritten either.
            let backup = backupURL(for: url)
            if !FileManager.default.fileExists(atPath: backup.path) {
                try DurableFile.replace(backup, with: data)   // round 4 item 6
            }
            try DurableFile.replace(url, with: out)
        }
        let outcome = Outcome(speakerCount: found, segmentsRelabeled: visible.count,
                              echoClusters: echo?.echoLabels.count ?? 0, echoFlagged: echo?.result.flaggedCount ?? 0)
        Logger.transcription.info(
            "Re-diarized \(source, privacy: .public) at \(speakerCount, privacy: .public) speakers: \(found, privacy: .public) label(s) across \(outcome.segmentsRelabeled, privacy: .public) segments, \(outcome.echoClusters, privacy: .public) echo cluster(s), \(outcome.echoFlagged, privacy: .public) segment(s) flagged as echo")
        return outcome
    }

    // MARK: - Labelling and the echo check (#243)

    /// Metadata key: the channels (`"local"` / `"remote"`) a re-detect has rewritten, each once, in
    /// the order they were first re-detected. Absent on a transcript that never was.
    public static let rediarizedChannelsKey = "rediarized_channels"

    /// One of the channel's segments a re-detect labels.
    private struct Candidate {
        /// Its position in the transcript's `segments`.
        let index: Int
        let segment: TranscriptSegment
        /// Already flagged `echo`, and nothing else. Such a line is not relabelled as a line — it
        /// stays flagged — but it is evidence for the echo check: the pipeline flags an echo
        /// cluster's matched lines, and judged on the unmatched residue alone that cluster would
        /// look like a person.
        let wasEcho: Bool
    }

    /// The channel's segments with a time and a text that are unflagged, or flagged only as echo.
    /// A `filtered` or `duplicate` segment is neither labelled by a cluster nor evidence: it takes
    /// the unattributed label (#296).
    private static func relabelCandidates(in segments: [[String: Any]], source: String) -> [Candidate] {
        segments.enumerated().compactMap { index, dict in
            guard dict["source"] as? String == source,
                  let start = dict["start"] as? Double,
                  let end = dict["end"] as? Double,
                  let text = dict["text"] as? String else { return nil }
            let flagged = TranscriptAssembler.isFlagged(dict)
            let echoOnly = TranscriptAssembler.hasUsableTime(dict)
                && dict["filtered"] as? Bool != true && dict["duplicate"] as? Bool != true
            guard !flagged || echoOnly else { return nil }
            return Candidate(
                index: index,
                segment: TranscriptSegment(
                    start: start, end: end, text: text,
                    language: dict["language"] as? String,
                    confidence: (dict["confidence"] as? Double).map(Float.init)),
                wasEcho: flagged)
        }
    }

    /// Segments labelled against a diarization result, with its speaker database keyed like the labels.
    typealias Labeling = (_ segments: [TranscriptSegment], _ diarization: DiarizationResult)
        -> (labeled: [LabeledSegment], speakerDatabase: [String: [Float]])

    /// How a re-detect labels segments: against the given clusters as they are.
    static func label(_ segments: [TranscriptSegment], against diarization: DiarizationResult)
        -> (labeled: [LabeledSegment], speakerDatabase: [String: [Float]]) {
        // No second VAD pass (P5). These segments already passed the speech/quality gate when the
        // recording was transcribed; gating them again against a fresh speech map dropped text that
        // had survived once, and a relabel must never lose words. A full-coverage map (every moment
        // is speech) filters nothing but keeps the "low diarizer quality → Unknown" step, which a
        // nil map would switch off along with the gate.
        let horizon = (segments.map(\.end).max() ?? 0) + 1
        let result = StreamLabeling.withDiarization(
            segments: segments,
            diarizationResult: diarization,
            speechMap: [SpeechRegion(start: 0, end: horizon, probability: 1)],
            // Gate off, quality on: with a threshold of 0 the map never filters anything — a
            // zero-length segment included — while low diarizer quality still reads "Unknown".
            vadSpeechThreshold: 0,
            // nil, not the config value: `speakerCountIsUserStated: true` disables absorption
            // outright, so passing a share would imply a knob that has no effect on this path.
            // The user's answer is authoritative: absorption exists to second-guess a count nobody
            // supplied.
            minSpeakerShare: nil,
            speakerCountIsUserStated: true)
        return (result.labeled, result.speakerDatabase)
    }

    /// What the echo check found on the diarizer's raw clusters.
    private struct EchoCheck {
        /// `EchoDeduplicator`'s result over the candidates, in their order, followed by the other
        /// channel's segments.
        let result: EchoDeduplicator.DeduplicationResult
        /// Per candidate, the raw cluster it falls in, as the check labelled it ("Local Speaker 2").
        let rawLabels: [String]
        /// The raw clusters judged echo, by that label. "Local Unknown" can be one: the speech no
        /// turn covers is judged as a group, like any cluster.
        let echoLabels: Set<String>
        /// The same clusters by the diarizer's own IDs — what the count enforcement keeps.
        let clusterIDs: Set<String>

        func isInEchoCluster(_ candidate: Int) -> Bool { echoLabels.contains(rawLabels[candidate]) }
    }

    /// Run `EchoDeduplicator` on the mic channel as the diarizer's RAW clusters split it, against
    /// the other channel's unflagged segments.
    ///
    /// Only for the mic channel: the deduplicator judges local clusters against remote speech —
    /// "is this the other side's voice through the speakers?" — and has no answer to the reverse.
    ///
    /// nil when the labelling is not one segment in, one out. At re-detect there are no word
    /// timings, so nothing is split and it always is; if that ever stops holding the verdicts could
    /// not be put back on the right lines, so the check stands down and the re-detect goes on
    /// without it — a relabel must never lose or misplace words.
    private static func echoCheck(
        on candidates: [Candidate], raw: DiarizationResult, transcript: [[String: Any]], labeling: Labeling
    ) -> EchoCheck? {
        var (local, speakerDatabase) = labeling(candidates.map(\.segment), raw)
        guard local.count == candidates.count else {
            Logger.transcription.error(
                "Re-diarize: the echo check is skipped — labelling the raw clusters returned \(local.count, privacy: .public) segments for \(candidates.count, privacy: .public)")
            return nil
        }
        for i in local.indices { local[i].source = "local" }
        SpeakerAssignment.tagWithSourcePrefix(&local)
        let remote = transcript.compactMap { dict -> LabeledSegment? in
            guard dict["source"] as? String == "remote", !TranscriptAssembler.isFlagged(dict),
                  let start = dict["start"] as? Double,
                  let end = dict["end"] as? Double,
                  let text = dict["text"] as? String else { return nil }
            return LabeledSegment(
                start: start, end: end,
                speaker: dict["speaker"] as? String ?? labelPrefix(for: "remote") + SpeakerAssignment.unknownSpeaker,
                text: text, source: "remote")
        }
        // The raw clusters' embeddings are passed as evidence. The transcript holds none for the
        // other channel, so no voice similarity is recorded; it decides nothing either way.
        let result = EchoDeduplicator.deduplicate(
            segments: local + remote, localSpeakerDatabase: speakerDatabase, remoteSpeakerDatabase: [:])
        let echoLabels = Set(result.clusters.filter(\.isEcho).map(\.label))
        let clusterIDs = SpeakerAssignment.buildSpeakerMap(from: raw.segments)
            .filter { echoLabels.contains(labelPrefix(for: "local") + $0.value) }.keys
        return EchoCheck(result: result, rawLabels: local.map(\.speaker), echoLabels: echoLabels, clusterIDs: Set(clusterIDs))
    }

    /// The longest a single chunk can plausibly be, and the most recorded-gap time the bound will
    /// ever allow — a cap that still honours a real multi-day gap, but keeps a corrupt value from
    /// turning into gigabytes of padding.
    static let maxChunkSeconds: Double = 86_400
    static let maxGapTotalSeconds: Double = 7 * 86_400

    /// The latest wall-clock offset this recording's timeline can reach: every chunk's length, plus
    /// its recorded gaps, plus one chunk of slack.
    ///
    /// - A chunk whose file cannot be read counts with its cached length (when that is a real one),
    ///   else as one chunk — an unreadable file must not shrink the bound.
    /// - The recorded gaps count in full (a real overnight gap can exceed a day) but their TOTAL is
    ///   capped at the recording's wall-clock span (latest offset + that chunk's length), and at
    ///   `maxGapTotalSeconds` — a pile of corrupt gaps cannot widen the bound without limit.
    static func timelineBound(fileLengths: [TimeInterval?], cachedDurations: [Double], gapSeconds: [Double], offsets: [Double]?) -> Double {
        func real(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value > 0, value <= maxChunkSeconds else { return nil }
            return value
        }
        let cached = cachedDurations.count == fileLengths.count ? cachedDurations : []
        let known = fileLengths.indices.map { real(fileLengths[$0]) ?? real(cached.indices.contains($0) ? cached[$0] : nil) }
        let oneChunk = known.compactMap { $0 }.max() ?? 0
        let lengths = known.map { $0 ?? oneChunk }
        let gapTotal = gapSeconds.filter { $0.isFinite && $0 >= 0 }.reduce(0, +)
        var gapCap = maxGapTotalSeconds
        if let offsets, offsets.count == lengths.count, !offsets.isEmpty, offsets.allSatisfy(\.isFinite) {
            gapCap = min(gapCap, zip(offsets, lengths).map { $0 + $1 }.max() ?? gapCap)
        }
        return lengths.reduce(0, +) + min(gapTotal, max(0, gapCap)) + oneChunk
    }

    /// `<transcript>.json.bak` next to the transcript: the transcript before its first re-detect.
    /// Deliberately not `.json`, so a folder scan never reads it as a second meeting (#152).
    static func backupURL(for transcript: URL) -> URL {
        transcript.appendingPathExtension("bak")
    }

    /// What a chunk file can contribute to one channel's audio.
    enum ChannelRole: Equatable {
        /// A stereo archive: split it and take the wanted side.
        case needsSplit
        /// A mono fallback WAV that already IS the wanted channel.
        case useDirectly
        /// A mono fallback WAV holding the other channel — it contributes nothing here.
        case skip
    }

    /// Decide a chunk's role for the requested channel.
    ///
    /// The three-way distinction matters because a WAV fallback holds exactly ONE channel and the
    /// filename says which (#183). Treating "not a stereo archive" as "system audio" skipped mic
    /// WAVs for local requests; treating "not system-only" as "stereo" sent a mono mic WAV to
    /// `splitChannels`. Both are wrong for a mic-only recording — which is precisely the kind the
    /// speaker-count control exists to fix.
    static func channelRole(of chunk: URL, wantsLocal: Bool) -> ChannelRole {
        if SpeakerSampleLocator.isLocalOnly(chunk) { return wantsLocal ? .useDirectly : .skip }
        if SpeakerSampleLocator.isSystemOnly(chunk) { return wantsLocal ? .skip : .useDirectly }
        return .needsSplit
    }

    /// What `decodeChannelAudio` hands back: either pre-decoded samples for the diarizer, or a
    /// path for it to decode itself.
    ///
    /// Never returned from a `public` API — `private` keeps it out of the module's internal
    /// namespace and signals that intent to future readers.
    private enum DecodedChannelAudio {
        case samples([Float])
        case path(URL)
    }

    /// A skipped chunk's length: the cached `chunk_durations` entry when it is usable (> 0 — 0 is the
    /// "unreadable at archive time" sentinel), else read from the file itself. Refused only when
    /// neither can say.
    private static func skippedChunkDuration(index: Int, of total: Int, cached: [Double], fileLength: TimeInterval?) throws -> Double {
        if index < cached.count, cached[index].isFinite, cached[index] > 0 { return cached[index] }
        if let fileLength, fileLength > 0 { return fileLength }
        throw RediarizeError.chunkDurationUnknown(chunk: index + 1, of: total)
    }

    /// Decode the requested channel to mono Float samples at the diarizer target rate
    /// (16 kHz), concatenating chunks in THAT domain when needed — about 3x smaller than the
    /// 48kHz stereo Int16 source (matches `AudioDecode`'s own "3x smaller" note below), and it
    /// lets the caller skip the old file-based concatenation step
    /// entirely (#204). A stereo chunk is split down to just the wanted side first
    /// (`AudioSourceResolver.splitChannel`), so neither the decode nor the write ever touches the
    /// unwanted side.
    ///
    /// `.legacyDualStream` is a single file, so there's nothing to concatenate and therefore no
    /// decode-reuse benefit to justify pre-decoding it into an extra in-memory copy — that case
    /// hands back the path instead and lets the diarizer stream it itself, same as before #204.
    ///
    /// Every listed chunk must exist, and a chunk that holds only the OTHER channel (`.skip`)
    /// contributes silence of its `chunkDurations` length — dropping either shifted every later
    /// chunk's timeline, so the new labels landed on the wrong words (P5). Both are refused rather
    /// than guessed.
    private static func decodeChannelAudio(
        layout: AudioLayout,
        source: String,
        chunkDurations: [Double],
        chunkOffsets: [Double]?,
        hasCaptureGaps: Bool,
        gapSeconds: [Double],
        scratchDirectory: URL,
        onProgress: (@Sendable (Progress) -> Void)?
    ) async throws -> DecodedChannelAudio {
        let wantsLocal = source == "local"

        switch layout {
        case .unavailable:
            throw RediarizeError.noAudioForChannel(source)

        case .legacyDualStream(let remote, let local):
            guard let url = wantsLocal ? local : remote,
                  FileManager.default.fileExists(atPath: url.path)
            else { throw RediarizeError.noAudioForChannel(source) }
            return .path(url)

        case .chunkedArchives(let chunks):
            // No silent filtering: a missing chunk's audio would vanish from the middle of the
            // timeline and every later chunk would slide earlier by its length. When NONE is left
            // (the storage quota evicted the recording's audio), the recording simply has no audio.
            let missing = chunks.indices.filter { !FileManager.default.fileExists(atPath: chunks[$0].path) }
            if missing.count == chunks.count { throw RediarizeError.noAudioForChannel(source) }
            if let first = missing.first { throw RediarizeError.chunkMissing(chunk: first + 1, of: chunks.count) }
            // A channel no chunk carries (the remote side of a mic-only recording) has no audio at
            // all — say so before padding anything.
            guard chunks.contains(where: { channelRole(of: $0, wantsLocal: wantsLocal) != .skip }) else {
                throw RediarizeError.noAudioForChannel(source)
            }
            // Every offset must be one this recording could have: finite, ≥ 0, and within its AUDIO —
            // the chunk files' real lengths, plus its recorded gaps, plus one chunk of slack. Not the
            // words: a recording can run long after the last one (nobody pressed Stop). A corrupted
            // value would otherwise trap (`Int(1e300)`) or allocate gigabytes of silence.
            let fileLengths = SpeakerSampleLocator.durations(of: chunks)
            let bound = timelineBound(
                fileLengths: fileLengths, cachedDurations: chunkDurations, gapSeconds: gapSeconds,
                offsets: chunkOffsets.flatMap { $0.count == chunks.count ? $0 : nil })
            func plausible(_ value: Double) -> Bool { value.isFinite && value >= 0 && value <= bound }
            // Each chunk goes at the wall-clock offset the transcript used for it, so labels land on
            // the right words across a relaunch or sleep gap — in OFFSET order, not list order (a
            // chunk re-indexed after a collision can be listed out of time order), so the offsets
            // never decrease. Without recorded offsets the chunks are laid end to end — correct only
            // when nothing is missing between them.
            let offsets = chunkOffsets.flatMap { $0.count == chunks.count ? $0 : nil }
            if let offsets, !offsets.allSatisfy(plausible) { throw RediarizeError.chunkTimingImplausible }
            if offsets == nil, hasCaptureGaps, chunks.count > 1 { throw RediarizeError.timelineUnknown }
            let order = offsets.map { o in chunks.indices.sorted { (o[$0], $0) < (o[$1], $1) } } ?? Array(chunks.indices)
            // Cached lengths are trusted only when they line up one-to-one with the chunks.
            let cachedDurations = chunkDurations.count == chunks.count ? chunkDurations : []
            var combined: [Float] = []
            for (position, index) in order.enumerated() {
                let chunk = chunks[index]
                // Per-iteration: decoding one chunk is itself slow, so a cancel during chunk 2 of
                // 10 should not wait for the remaining eight.
                try Task.checkCancellation()
                let role = channelRole(of: chunk, wantsLocal: wantsLocal)
                // Reported AFTER this chunk is done (index + 1), not before: reporting before
                // meant the bar topped out at (N-1)/N and never reached 1.0 before the phase
                // switched to .detectingSpeakers — visibly "snapping" past the last chunk.
                //
                // Not reported for a `.skip` chunk: padding it with silence is not decode work.
                defer {
                    if role != .skip {
                        onProgress?(Progress(phase: .decodingAudio, fraction: Double(position + 1) / Double(chunks.count)))
                    }
                }
                if let offsets {
                    let target = Int((offsets[index] * AudioDecode.targetSampleRate).rounded())
                    if combined.count < target {
                        combined.append(contentsOf: [Float](repeating: 0, count: target - combined.count))
                    }
                }
                let decodedChunk: [Float]
                switch role {
                case .skip:
                    // This chunk holds only the other channel. With offsets the next chunk's offset
                    // re-aligns the timeline; without, it contributes silence of its own length.
                    if offsets != nil { continue }
                    // A cached length beyond the audio is corrupt: the file's own length wins.
                    let duration = try skippedChunkDuration(index: index, of: chunks.count,
                                                            cached: cachedDurations.map { plausible($0) ? $0 : 0 },
                                                            fileLength: fileLengths[index])
                    decodedChunk = [Float](repeating: 0, count: Int(duration * AudioDecode.targetSampleRate))
                case .useDirectly:
                    decodedChunk = try AudioDecode.mono16kHzFloat(contentsOf: chunk)
                case .needsSplit:
                    let channel: AudioSourceResolver.Channel = wantsLocal ? .local : .remote
                    let split = try await AudioSourceResolver.splitChannel(
                        stereoAac: chunk, outputDirectory: scratchDirectory, channel: channel)
                    defer { try? FileManager.default.removeItem(at: split) }
                    decodedChunk = try AudioDecode.mono16kHzFloat(contentsOf: split)
                }
                // `combined` accumulates every chunk in the recording — on a 90-minute call at
                // 16kHz that's tens of millions of floats, and Swift's array growth doubles on
                // each reallocation, so the final grow briefly touches ~2x the steady-state size.
                // The first chunk's own length is the best estimate available here (chunk
                // durations can be absent for chunks that are decoded, not padded), so use it to
                // size the rest in one shot rather than free-growing through log2(chunkCount)
                // reallocations. Chunks differ in length (the last is usually short), so this is an
                // estimate — over- or under-shooting only costs capacity or one extra grow.
                if combined.isEmpty {
                    combined.reserveCapacity(decodedChunk.count * chunks.count)
                }
                combined.append(contentsOf: decodedChunk)
            }
            guard !combined.isEmpty else { throw RediarizeError.noAudioForChannel(source) }
            return .samples(combined)
        }
    }
}

/// Decodes audio to mono Float32 samples at 16 kHz — the format the diarizer and VAD both want.
///
/// Deliberately NOT a call to FluidAudio's own `AudioConverter`, which does exactly this: that
/// class's bare name collides with `TranscriberCore.AudioConverter` (an unrelated 48kHz/Int16
/// capture-pipeline type in this same module, which always wins unqualified lookup), and the
/// FluidAudio package separately ships a top-level `public struct FluidAudio`, so even the
/// module-qualified spelling `FluidAudio.AudioConverter` resolves to a (nonexistent) member of
/// THAT struct rather than the class. Neither collision has a source-level workaround, so this
/// mirrors FluidAudio's own implementation instead (read at the file's native format in
/// chunks, mix to mono Float32 if needed, then one `AVAudioConverter` pass to 16 kHz) — the same
/// system `AVAudioConverter` API, called with the same target format, so the result matches what
/// FluidAudio's own converter would have produced for the same file.
///
/// Not streaming end-to-end: the whole file is read into `monoSamples` at its NATIVE rate first,
/// then resampled to 16 kHz in one pass — so a chunk's peak memory is roughly 2x its native-rate
/// decoded size (the native-rate buffer plus `resample`'s same-size input copy and smaller output
/// buffer, briefly coexisting). For a 5-minute 48 kHz chunk that's tens of MB, not gigabytes, and
/// each chunk is freed before the next one is decoded (`decodeChannelAudio`'s loop), so this
/// doesn't accumulate across a long recording — just worth naming so a future reader doesn't
/// wonder why this isn't reading in 16kHz-sized pieces throughout.
enum AudioDecode {
    static let targetSampleRate: Double = 16000

    enum DecodeError: Error {
        case bufferAllocationFailed
        case formatCreationFailed
        case converterCreationFailed
        case conversionFailed(Error?)
    }

    /// A one-shot latch for an `AVAudioConverterInputBlock`'s "have I already handed out the
    /// buffer" check.
    ///
    /// Not a bare `var` captured by the closure: `AVAudioConverterInputBlock` is
    /// `@escaping @Sendable`, and Swift 6's strict-concurrency checking flags a mutable capture
    /// of a non-Sendable local inside a `@Sendable` closure as a potential data race — even though
    /// the converter calls this block synchronously on the calling thread, so there's no actual
    /// race. This project isn't built under strict concurrency today, so it isn't a current build
    /// error, but a reference type marked `@unchecked Sendable` (its true safety comes from
    /// AVAudioConverter's documented synchronous, single-threaded callback contract, not from
    /// anything the compiler can verify) sidesteps the check now rather than leaving it as a
    /// surprise refactor whenever that mode is turned on.
    private final class InputProvidedOnce: @unchecked Sendable {
        var provided = false
    }

    static func mono16kHzFloat(contentsOf url: URL) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let chunkSize = max(4096, Int(format.sampleRate))
        var monoSamples: [Float] = []
        // Capacity at the file's NATIVE sample rate — the size of THIS intermediate buffer, not
        // the smaller post-resample result (3x smaller for a 48kHz source going to 16kHz).
        monoSamples.reserveCapacity(Int(audioFile.length))

        while audioFile.framePosition < audioFile.length {
            let remaining = Int(audioFile.length - audioFile.framePosition)
            let framesToRead = AVAudioFrameCount(min(chunkSize, remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                throw DecodeError.bufferAllocationFailed
            }
            try audioFile.read(into: buffer)
            if buffer.frameLength == 0 { break }
            monoSamples.append(contentsOf: try monoFloat32(from: buffer))
        }

        guard format.sampleRate != targetSampleRate else { return monoSamples }
        return try resample(monoSamples, from: format.sampleRate, to: targetSampleRate)
    }

    /// Extract mono Float32 samples from a buffer, mixing channels down if the source isn't
    /// already mono (our chunk files always are, by construction — this is a defensive fallback).
    private static func monoFloat32(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        let format = buffer.format
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return [] }

        if format.channelCount == 1, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved {
            guard let channelData = buffer.floatChannelData else { return [] }
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false
        ) else { throw DecodeError.formatCreationFailed }
        guard let converter = AVAudioConverter(from: format, to: monoFormat) else {
            throw DecodeError.converterCreationFailed
        }

        let gate = InputProvidedOnce()
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if gate.provided {
                status.pointee = .endOfStream
                return nil
            }
            gate.provided = true
            status.pointee = .haveData
            return buffer
        }

        // Same reasoning as `resample`'s loop below: a single `convert()` call isn't guaranteed
        // to flush every frame even though the sample rate is unchanged here (no resampling
        // filter latency expected for a same-rate channel mixdown, but nothing in the API
        // contract promises that), so this drains the same way rather than trusting one call.
        var monoSamples: [Float] = []
        monoSamples.reserveCapacity(frameCount)
        while true {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity) else {
                throw DecodeError.bufferAllocationFailed
            }
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
            guard status != .error else { throw DecodeError.conversionFailed(error) }
            if outputBuffer.frameLength > 0, let channelData = outputBuffer.floatChannelData {
                monoSamples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
            }
            if status == .endOfStream { break }
            if status == .inputRanDry, outputBuffer.frameLength == 0 { break }
        }
        return monoSamples
    }

    private static func resample(_ samples: [Float], from inputRate: Double, to outputRate: Double) throws -> [Float] {
        guard !samples.isEmpty else { return [] }

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false
        ) else { throw DecodeError.formatCreationFailed }
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw DecodeError.bufferAllocationFailed
        }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = inputBuffer.floatChannelData else {
            throw DecodeError.bufferAllocationFailed
        }
        samples.withUnsafeBufferPointer { src in
            channelData[0].update(from: src.baseAddress!, count: samples.count)
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false
        ) else { throw DecodeError.formatCreationFailed }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw DecodeError.converterCreationFailed
        }
        // Generous headroom over the exact ratio, so a single `convert()` call below has room to
        // hold the whole result without needing a second call JUST because the buffer filled up.
        let estimatedFrames = Double(samples.count) * outputRate / inputRate
        let capacity = AVAudioFrameCount(estimatedFrames.rounded(.up)) + 4096

        let gate = InputProvidedOnce()
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if gate.provided {
                status.pointee = .endOfStream
                return nil
            }
            gate.provided = true
            status.pointee = .haveData
            return inputBuffer
        }

        // A single `convert()` call is NOT guaranteed to flush every frame even with headroom to
        // spare: a resampling filter with nonzero internal latency (typical for a non-integer
        // ratio SRC, e.g. a 44.1kHz source) can return `.inputRanDry` after the input block
        // signals `.endOfStream`, while still holding a few trailing frames it hasn't emitted yet
        // — those only come out on a FOLLOW-UP call. Looping until the converter itself reports
        // `.endOfStream` (fully drained) means those trailing frames are never silently dropped.
        // The 48kHz→16kHz integer-ratio case this app actually exercises likely drains in one
        // pass, but nothing here guarantees that, and a silently-shortened decode is exactly the
        // kind of divergence from FluidAudio's own converter this whole type exists to avoid.
        var outputSamples: [Float] = []
        outputSamples.reserveCapacity(Int(capacity))
        // Only the FIRST call needs a buffer sized for the whole result — every call after that
        // is draining a resampling filter's internal latency, typically a few hundred frames at
        // most, so allocating another `capacity`-sized buffer (which can be tens of MB for a long
        // chunk) on each pass would just be discarded unread. A small fixed drain size keeps that
        // allocation cheap without changing the loop's correctness.
        let drainCapacity: AVAudioFrameCount = 4096
        var isFirstPass = true
        while true {
            let bufferCapacity = isFirstPass ? capacity : drainCapacity
            isFirstPass = false
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: bufferCapacity) else {
                throw DecodeError.bufferAllocationFailed
            }
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
            guard status != .error else { throw DecodeError.conversionFailed(error) }
            if outputBuffer.frameLength > 0, let channelData = outputBuffer.floatChannelData {
                outputSamples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
            }
            if status == .endOfStream { break }
            // `.inputRanDry` with nothing new produced means there was nothing left to flush
            // either — without this the loop would spin forever on a converter that never
            // reports `.endOfStream` once its own input block has signalled end-of-input.
            if status == .inputRanDry, outputBuffer.frameLength == 0 { break }
        }
        return outputSamples
    }
}
