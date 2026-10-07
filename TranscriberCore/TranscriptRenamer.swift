import Foundation
import os

/// One voice sample for a speaker in the rename UI/CLI: the quote to show, and — when the
/// audio is still on disk — where to play it from.
public struct SpeakerSample: Sendable {
    public let text: String
    /// Chunk file this sample lives in, already resolved — nil when no playable audio exists.
    public let audioFile: URL?
    /// Offsets WITHIN `audioFile`, not absolute transcript time (#132).
    public let start: TimeInterval
    public let end: TimeInterval
    /// Which channel of the stereo archive holds this speaker (L = local/mic, R = remote/system).
    /// Comes from the segment's `source`, not the display name — renaming a speaker must not
    /// change which channel we read.
    public let isLocal: Bool

    public init(text: String, audioFile: URL?, start: TimeInterval, end: TimeInterval, isLocal: Bool) {
        self.text = text
        self.audioFile = audioFile
        self.start = start
        self.end = end
        self.isLocal = isLocal
    }
}

/// Shared speaker-rename logic for a transcript JSON, used by both the CLI rename
/// (`CLIRename`) and the GUI rename dialog (`RenameWindowController`) so it lives once
/// and is testable from TranscriberTests.
public enum TranscriptRenamer {

    /// One renameable speaker: its transcript ID plus the samples to audition it by.
    public struct RenameableSpeaker: Sendable {
        public let id: String  // "Local Speaker 1", "Remote Speaker 1", etc.
        public let samples: [SpeakerSample]

        public init(id: String, samples: [SpeakerSample]) {
            self.id = id
            self.samples = samples
        }
    }

    public enum RenameError: LocalizedError, Equatable {
        case cannotRead
        case invalidJSON

        public var errorDescription: String? {
            switch self {
            case .cannotRead: return "Cannot read transcript file"
            case .invalidJSON: return "Invalid JSON transcript file"
            }
        }
    }

    /// Collect the speakers of a transcript JSON, each with up to `maxSamplesPerSpeaker`
    /// playable samples (best-first), in order of first appearance.
    ///
    /// Speakers with fewer than `minSegmentsPerSpeaker` non-empty segments are dropped —
    /// they're usually diarization artifacts — unless that would drop ALL speakers
    /// (e.g. short transcripts), in which case the unfiltered list is returned.
    ///
    /// A speaker whose samples cannot be resolved to playable audio (e.g. archives deleted
    /// by the storage quota) still gets text-only samples (`audioFile == nil`), so it stays
    /// renameable without offering a dead play button.
    ///
    /// A speaker whose segments are all zero/negative-duration yields an empty-samples entry —
    /// the CLI drops it, the GUI lists it sample-less (preserved behaviour).
    public static func collectSpeakerSamples(
        from jsonPath: URL,
        maxSamplesPerSpeaker: Int,
        minSegmentsPerSpeaker: Int = 1
    ) throws -> [RenameableSpeaker] {
        guard let data = try? Data(contentsOf: jsonPath) else {
            throw RenameError.cannotRead
        }
        // Checked here, not in the json-based overload below: THIS entry point's contract is "a
        // transcript JSON, or throw" — a dict with no `segments` key at all isn't a transcript, so
        // it stays an error here. The json-based overload has a looser contract (an already-parsed
        // transcript that just happens to have no segments IS valid, e.g. one #207 read alongside
        // metadata that also lacks any), so it degrades to `[]` instead.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["segments"] is [[String: Any]]
        else {
            throw RenameError.invalidJSON
        }
        return collectSpeakerSamples(
            json: json, maxSamplesPerSpeaker: maxSamplesPerSpeaker, minSegmentsPerSpeaker: minSegmentsPerSpeaker)
    }

    /// Same as `collectSpeakerSamples(from:...)`, but from an already-read-and-parsed transcript.
    ///
    /// Exists so a caller that ALSO needs `channelNames(in:source:)`-style metadata from the same
    /// transcript (`RenameWindowController`/`RenameDialog`, #207) can read and parse the file once
    /// and hand the same dictionary to both, instead of two independent `Data(contentsOf:)` round
    /// trips to what can be an iCloud-mounted, network-backed path. A missing `segments` array is
    /// not an error here — an empty transcript yields no speakers, not a throw — since the URL-based
    /// overload above already turned "not parseable at all" into `RenameError.invalidJSON` before
    /// reaching this point.
    public static func collectSpeakerSamples(
        json: [String: Any],
        maxSamplesPerSpeaker: Int,
        minSegmentsPerSpeaker: Int = 1
    ) -> [RenameableSpeaker] {
        guard let segments = json["segments"] as? [[String: Any]] else { return [] }

        // Resolve the recording's audio layout. `audio_paths` is [chunk0, chunk1, ...] for a
        // chunked recording — NOT [system, mic] — so samples must be mapped onto the chunk that
        // actually contains them (#132).
        let metadata = json["metadata"] as? [String: Any]
        let audioPaths = (metadata?["audio_paths"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
        let layout = SpeakerSampleLocator.classify(audioPaths: audioPaths)
        // Prefer durations already stamped in metadata (#204) over opening every chunk file.
        let cachedDurations = metadata?["chunk_durations"] as? [Double]
        let chunkDurations = SpeakerSampleLocator.durations(for: layout, cached: cachedDurations)
        // Where finalize placed each chunk on the wall-clock timeline: across a capture gap the
        // chunks are not end to end, and samples after the gap would otherwise play wrong audio.
        let chunkOffsets = metadata?["chunk_offsets"] as? [Double]

        // Collect every segment once — sample ranking needs the OTHER speakers too, to tell
        // clean speech from crosstalk.
        var allCandidates: [SpeakerSampleSelector.Candidate] = []
        var segmentCounts: [String: Int] = [:]
        var orderedIds: [String] = []

        // Flagged segments (VAD-filtered noise, mic-bleed echo) are never offered as a sample: an
        // echo is the OTHER side's voice, and auditioning it would name the wrong person (P10/P11).
        for seg in segments where !TranscriptAssembler.isFlagged(seg) {
            guard let speaker = seg["speaker"] as? String,
                  let text = seg["text"] as? String,
                  let start = seg["start"] as? Double,
                  let end = seg["end"] as? Double else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if segmentCounts[speaker] == nil { orderedIds.append(speaker) }
            segmentCounts[speaker, default: 0] += 1
            let source = seg["source"] as? String ?? "remote"
            allCandidates.append(SpeakerSampleSelector.Candidate(
                speaker: speaker, start: start, end: end, source: source, text: trimmed
            ))
        }

        // Filter out noise speakers (< minSegmentsPerSpeaker); fall back to the unfiltered list
        // if filtering would remove everyone.
        let filteredIds = orderedIds.filter { (segmentCounts[$0] ?? 0) >= minSegmentsPerSpeaker }
        let significantIds = filteredIds.isEmpty ? orderedIds : filteredIds

        return significantIds.map { speaker in
            // Isolated speech first, then longest — a sample exists to let a human recognise ONE
            // voice, and the longest segment is very often the one they were talked over in.
            let ranked = SpeakerSampleSelector.rank(speaker: speaker, allSegments: allCandidates)

            var samples: [SpeakerSample] = []
            for candidate in ranked where samples.count < maxSamplesPerSpeaker {
                guard let hit = SpeakerSampleLocator.locate(
                    source: candidate.source,
                    start: candidate.start,
                    end: candidate.end,
                    layout: layout,
                    chunkDurations: chunkDurations,
                    chunkOffsets: chunkOffsets
                ) else { continue }
                samples.append(SpeakerSample(
                    text: candidate.text,
                    audioFile: hit.url,
                    start: hit.start,
                    end: hit.end,
                    isLocal: hit.isLocal
                ))
            }

            // No playable audio at all: still offer the speaker for renaming, with sample text only.
            if samples.isEmpty {
                samples = ranked.prefix(maxSamplesPerSpeaker).map {
                    SpeakerSample(text: $0.text, audioFile: nil, start: 0, end: 0, isLocal: $0.source == "local")
                }
            }

            return RenameableSpeaker(id: speaker, samples: samples)
        }
    }

    /// Apply speaker renames to the transcript on disk: remap segment speakers, record the
    /// applied names in `metadata.speaker_names`, write back.
    ///
    /// The recorded names MERGE into any `speaker_names` left by a previous rename — replacing
    /// the map wholesale loses the earlier session's names (#162) — and identity renames
    /// (name unchanged) are filtered out rather than recorded.
    ///
    /// Returns false (and logs) on failure so callers can surface it: a silent no-op write is
    /// the silent-wrong-answer this product exists to avoid. The write is atomic, because by
    /// this point the source WAVs may be gone and this JSON is the only textual record of the
    /// meeting; a kill mid-write would truncate it.
    ///
    /// Keying trap: `speaker_names` is keyed by whatever label was current at rename time
    /// (original → renamed), so re-renaming an already-renamed speaker accumulates entries and can
    /// leave a stale original → intermediate key. A reader has to resolve chains:
    /// `EchoNotice.Findings` does, to find the row of a label `echo_clusters` still holds under its
    /// original name (#244). The other reader, `TranscriptRediarizer.channelNames`, only asks
    /// whether a channel has any name at all.
    @discardableResult
    public static func applyRenames(_ mapping: [String: String], jsonPath: URL) -> Bool {
        TranscriptWrites.exclusive(jsonPath) { applyRenamesUnlocked(mapping, jsonPath: jsonPath) }
    }

    private static func applyRenamesUnlocked(_ mapping: [String: String], jsonPath: URL) -> Bool {
        guard let data = try? Data(contentsOf: jsonPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var segments = json["segments"] as? [[String: Any]]
        else {
            Logger.files.error("Rename: cannot read transcript \(jsonPath.lastPathComponent, privacy: .sensitive)")
            return false
        }

        var metadata = json["metadata"] as? [String: Any] ?? [:]
        let rediarized = rediarizedChannels(in: metadata)
        for i in segments.indices where !keepsItsLabel(segments[i], rediarized: rediarized) {
            if let speaker = segments[i]["speaker"] as? String,
               let newName = mapping[speaker] {
                segments[i]["speaker"] = newName
            }
        }
        json["segments"] = segments

        var names = metadata["speaker_names"] as? [String: String] ?? [:]
        for (original, renamed) in mapping where original != renamed {
            names[original] = renamed
        }
        if !names.isEmpty {
            metadata["speaker_names"] = names
            json["metadata"] = metadata
        }

        do {
            let updatedData = try JSONSerialization.data(
                withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
            )
            try DurableFile.replace(jsonPath, with: updatedData)   // round 4 item 6
            return true
        } catch {
            Logger.files.error("Rename: failed to write \(jsonPath.lastPathComponent, privacy: .sensitive): \(error, privacy: .private)")
            return false
        }
    }

    /// The channels a re-detect has rewritten: `metadata.rediarized_channels`, plus any channel with
    /// a `speaker_count_<channel>` — builds before that list existed stamped only the count. nil when
    /// the list is there but is not a list of channels.
    private static func rediarizedChannels(in metadata: [String: Any]) -> Set<String>? {
        let counted = metadata.keys.filter { $0.hasPrefix("speaker_count_") }.map { String($0.dropFirst("speaker_count_".count)) }
        guard let recorded = metadata[TranscriptRediarizer.rediarizedChannelsKey] else { return Set(counted) }
        return (recorded as? [String]).map { Set($0).union(counted) }
    }

    /// Whether a rename leaves this segment's label alone (#245).
    ///
    /// A flagged segment (an echo, gate noise, a repeat, no usable time) is never given to a person
    /// by a re-detect. On a channel one has rewritten, an echo line of the mic channel carries its
    /// echo cluster's label or the unattributed one (#277), and every other flagged segment keeps the
    /// label an EARLIER diarization gave it, which can now belong to someone else: the rename must
    /// not reach any of them. On a channel that was never re-detected the label is still the
    /// pipeline's, and it is renamed like any other line — the JSON is the record, and it must not
    /// show two labels for one person.
    ///
    /// - Parameter rediarized: `rediarizedChannels(in:)`; nil = unreadable, and every flagged
    ///   segment keeps its label.
    private static func keepsItsLabel(_ segment: [String: Any], rediarized: Set<String>?) -> Bool {
        guard TranscriptAssembler.isFlagged(segment) else { return false }
        guard let rediarized else { return true }
        // No `source`: it cannot be shown to be on a channel that was left alone.
        guard let source = segment["source"] as? String else { return !rediarized.isEmpty }
        return rediarized.contains(source)
    }
}
