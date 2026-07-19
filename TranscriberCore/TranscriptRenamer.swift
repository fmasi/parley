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
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = json["segments"] as? [[String: Any]]
        else {
            throw RenameError.invalidJSON
        }

        // Resolve the recording's audio layout. `audio_paths` is [chunk0, chunk1, ...] for a
        // chunked recording — NOT [system, mic] — so samples must be mapped onto the chunk that
        // actually contains them (#132).
        let metadata = json["metadata"] as? [String: Any]
        let audioPaths = (metadata?["audio_paths"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
        let layout = SpeakerSampleLocator.classify(audioPaths: audioPaths)
        let chunkDurations = SpeakerSampleLocator.durations(for: layout)

        // Collect every segment once — sample ranking needs the OTHER speakers too, to tell
        // clean speech from crosstalk.
        var allCandidates: [SpeakerSampleSelector.Candidate] = []
        var segmentCounts: [String: Int] = [:]
        var orderedIds: [String] = []

        for seg in segments {
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
                    chunkDurations: chunkDurations
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
    /// Keying trap (latent, benign today): `speaker_names` is keyed by whatever label was
    /// current at rename time (original → renamed), so re-renaming an already-renamed speaker
    /// accumulates entries and can leave a stale original → intermediate key. Nothing in the
    /// codebase reads `speaker_names` back — it is write-only — but if a reader is ever added,
    /// resolve chains (or prune superseded keys) first.
    @discardableResult
    public static func applyRenames(_ mapping: [String: String], jsonPath: URL) -> Bool {
        guard let data = try? Data(contentsOf: jsonPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var segments = json["segments"] as? [[String: Any]]
        else {
            Logger.files.error("Rename: cannot read transcript \(jsonPath.lastPathComponent, privacy: .private)")
            return false
        }

        for i in segments.indices {
            if let speaker = segments[i]["speaker"] as? String,
               let newName = mapping[speaker] {
                segments[i]["speaker"] = newName
            }
        }
        json["segments"] = segments

        var metadata = json["metadata"] as? [String: Any] ?? [:]
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
            try updatedData.write(to: jsonPath, options: .atomic)
            return true
        } catch {
            Logger.files.error("Rename: failed to write \(jsonPath.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
