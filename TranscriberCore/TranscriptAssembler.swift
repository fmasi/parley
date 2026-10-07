import AVFoundation
import Foundation
import os

public enum TranscriptAssembler {
    /// `metadata.transcript_written_at` (L review 220): when finalize wrote the transcript, to the millisecond — the fixed
    /// reference late audio is judged from, never moved by a later rewrite (a rename, the disclosure's stamp).
    public static let writtenAtKey = "transcript_written_at"

    private static func writtenAtFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    static func formatWrittenAt(_ date: Date) -> String { writtenAtFormatter().string(from: date) }

    /// The stamp's time; nil when it is not one.
    public static func parseWrittenAt(_ stamp: String) -> Date? { writtenAtFormatter().date(from: stamp) }

    /// `metadata.echo_segments_flagged`: how many local segments carry `echo: true`. They are kept
    /// in `segments`; nothing is removed. Written only when above 0.
    static func stampEchoFlagged(_ count: Int, in metadata: inout [String: Any]) {
        guard count > 0 else { return }
        metadata["echo_segments_flagged"] = count
        // The key's name before #231, still written for one release for readers of older builds.
        metadata["echo_segments_removed"] = count
    }

    public static func assemble(
        segments: [LabeledSegment],
        audioPaths: [URL],
        outputFormat: String,
        language: String,
        numSpeakers: Int?,
        diarization: Bool,
        dualStream: Bool,
        echoSegmentsFlagged: Int = 0,
        echoClusters: [[String: Any]]? = nil,
        provenance: CaptureProvenance? = nil,
        recordedAt: Date? = nil,
        captureGaps: [CaptureGap] = [],
        processingIssues: [[String: Any]]? = nil,
        mergedAudio: [String: Any]? = nil,
        chunkDurations: [Double]? = nil,
        chunkOffsets: [Double]? = nil,
        writtenAt: Date? = nil
    ) -> [String: Any] {
        var metadata: [String: Any] = [
            "audio_files": audioPaths.map { $0.lastPathComponent },
            "audio_paths": audioPaths.map { $0.path },
            "output_format": outputFormat,
            "language": language,
            "num_speakers": numSpeakers.map { $0 as Any } ?? ("auto" as Any),
            "diarization": diarization,
            // The capture-time flag (§7.2): a mic stream was captured next to the remote one. It says
            // nothing about whether the remote side delivered audio — `capture.remote.status` is the
            // authority for that (C-M3).
            "dual_stream": dualStream,
            "software_version": AppVersion.gitDescription,
        ]
        // Recording-start wall-clock time (#49): the canonical date of the meeting. Stamped
        // here so summaries (and any downstream consumer) date the record by when it was
        // recorded, not when it was later transcribed/summarized. ISO8601 for stable parsing.
        if let recordedAt {
            metadata["recorded_at"] = ISO8601DateFormatter().string(from: recordedAt)
        }
        stampEchoFlagged(echoSegmentsFlagged, in: &metadata)
        // Why each local cluster was or was not judged to be echo (#242): numbers and labels only,
        // `EchoDeduplicator.ClusterVerdict.metadataDictionary`. nil = echo dedup did not run (no mic
        // stream), and the key is left out; an empty list = it ran and found no local speech.
        if let echoClusters {
            metadata["echo_clusters"] = echoClusters
        }
        // Capture provenance (#95): a compact, always-present stamp of how this recording was
        // captured — engine, formats, and how many route changes / retries / recoveries occurred.
        if let provenance {
            let provenanceDictionary = provenance.asMetadataDictionary()
            metadata["capture_provenance"] = provenanceDictionary
            // How much of each side was captured (§7.2 `metadata.capture.remote/local`). Taken from
            // the provenance dictionary so the status here is exactly the one stamped there,
            // including its fail-closed fallback when a stored status is missing or unreadable.
            var capture = metadata["capture"] as? [String: Any] ?? [:]
            if let remote = provenanceDictionary["remote_coverage"] { capture["remote"] = remote }
            if let local = provenanceDictionary["local_coverage"] { capture["local"] = local }
            if !capture.isEmpty { metadata["capture"] = capture }
        }
        // Periods with no capture (relaunch, sleep) — §7.2 `metadata.capture.gaps`. The `capture`
        // dictionary is created on demand: gaps must be stated even when no coverage was stamped.
        if !captureGaps.isEmpty {
            let formatter = ISO8601DateFormatter()
            var capture = metadata["capture"] as? [String: Any] ?? [:]
            capture["gaps"] = captureGaps.map { gap -> [String: Any] in
                [
                    "start": formatter.string(from: gap.start),
                    "end": formatter.string(from: gap.end),
                    "seconds": gap.seconds,
                    "reason": gap.reason,
                ]
            }
            metadata["capture"] = capture
        }
        // What went wrong or was removed while processing chunks (§7.2, P3): `{chunk?, code, track?,
        // count?}` per issue. The two counts cover only content-affecting codes — an idle side
        // (`stream_empty`) is not a processing problem. A tracked session always writes the key
        // (empty when clean); nil means the path does not track issues (CLI `run()`), and the key is
        // left out so absence is never read as "clean".
        if let processingIssues {
            metadata["processing_issues"] = processingIssues
            let counts = ChunkIssue.problemCounts(in: processingIssues)
            metadata["processing_issue_count"] = counts.issues
            metadata["processing_problem_chunks"] = counts.chunks
        }
        // How the chunks were merged into one file (§7.2): `{passthrough, gaps_inserted_seconds}`.
        if let mergedAudio {
            metadata["merged_audio"] = mergedAudio
        }
        // One entry per `audio_paths` element: each file's length (0 = unreadable) and the
        // wall-clock seconds from the meeting start at which the transcript placed it — what
        // re-detect needs to rebuild the same timeline (R6).
        if let chunkDurations { metadata["chunk_durations"] = chunkDurations }
        if let chunkOffsets { metadata["chunk_offsets"] = chunkOffsets }
        if let writtenAt { metadata[writtenAtKey] = formatWrittenAt(writtenAt) }
        // Disclosure (#138): the transcript testifies whether its contents left the machine.
        // A transcript is airgapped at assembly time — summaries are generated later (and only
        // on explicit user opt-in against a configured endpoint), so MeetingSummarizer updates
        // this block if/when a summary is run. Stamped explicitly (not by omission) so an absent
        // field is never mistaken for "not disclosed".
        metadata["disclosure"] = SummaryDisclosure.airgapped.asMetadataDictionary()

        // A non-finite number reaching `JSONSerialization` raises an uncatchable Objective-C exception:
        // every finalize of the session, and every retry, would crash (C-M17). The segment and its words
        // are kept; an unknown time is written as null — never an invented number — and flagged
        // `time_unknown`, so every reader skips it (R2b item 5); an unknown confidence is left out.
        let nonFinite = segments.filter { !$0.start.isFinite || !$0.end.isFinite || !($0.confidence?.isFinite ?? true) }.count
        if nonFinite > 0 {
            Logger.transcription.error("\(nonFinite, privacy: .public) segment(s) carried a non-finite time or confidence — written as unknown")
        }
        let segmentDicts: [[String: Any]] = segments.map { seg in
            var dict: [String: Any] = [
                "start": seg.start.isFinite ? seg.start : NSNull(),
                "end": seg.end.isFinite ? seg.end : NSNull(),
                "speaker": seg.speaker,
                "text": seg.text,
            ]
            if !seg.source.isEmpty {
                dict["source"] = seg.source
            }
            if let confidence = seg.confidence, confidence.isFinite {
                dict["confidence"] = confidence
            }
            if !seg.start.isFinite || !seg.end.isFinite { dict["time_unknown"] = true }
            if let language = seg.language {
                dict["language"] = language
            }
            // Written only when set, so an unflagged segment looks exactly as it always did.
            if seg.filtered { dict["filtered"] = true }
            if seg.echo { dict["echo"] = true }
            if seg.duplicate { dict["duplicate"] = true }
            return dict
        }

        Logger.transcription.debug("Assembled transcript: \(segments.count) segments, format: \(outputFormat, privacy: .public)")

        return [
            "metadata": metadata,
            "segments": segmentDicts,
        ]
    }

    /// Whether a transcript JSON segment is flagged `filtered` (failed the VAD/quality gate),
    /// `echo` (mic bleed) or `duplicate` (an abutting repeat), or has no usable time (`time_unknown`,
    /// or a start/end that is missing or non-finite). Flagged segments stay in the JSON record and
    /// are hidden from everything a person reads: TXT, SRT, the summary prompt and the rename
    /// samples (P2/P10/P11); re-detect keeps them untouched. A segment with no time is never shown at
    /// 00:00:00 — skipped, never 0 (R2b item 5).
    public static func isFlagged(_ segment: [String: Any]) -> Bool {
        segment["filtered"] as? Bool == true || segment["echo"] as? Bool == true
            || segment["duplicate"] as? Bool == true || !hasUsableTime(segment)
    }

    /// A finite `start` and `end`, and not flagged `time_unknown`.
    public static func hasUsableTime(_ segment: [String: Any]) -> Bool {
        guard segment["time_unknown"] as? Bool != true,
              let start = segment["start"] as? Double, let end = segment["end"] as? Double
        else { return false }
        return start.isFinite && end.isFinite
    }

    /// Atomic AND durable (round 3 item 2): the finalized marker written next vouches for this file,
    /// so it must be on the disk itself, not in a cache, before the marker is.
    public static func write(_ json: [String: Any], to path: URL) throws {
        try write(data: encode(json), to: path)
    }

    /// The transcript as its file holds it: encoding is CPU work, done where the record is built — the write goes to the
    /// folder's queue (L review 185).
    public static func encode(_ json: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    /// `write`, of an encoded transcript: atomic and durable.
    public static func write(data: Data, to path: URL) throws {
        try DurableFile.replace(path, with: data)
        Logger.files.info("JSON transcript written: \(path.lastPathComponent, privacy: .sensitive)")
    }

    /// Whether `url` holds a readable transcript: JSON with a `metadata` object and a `segments` list.
    public static func verifies(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["metadata"] is [String: Any] && json["segments"] is [[String: Any]]
    }

    /// Rewrite a transcript JSON's `audio_paths` / `audio_files` to reference every audio source
    /// that contributed to it, replacing the placeholder source-WAV paths written at assembly
    /// time (#93). No-op if the file is missing or unreadable.
    ///
    /// Also stamps `chunk_durations`, one entry per `paths` element, read here ONCE while
    /// archiving already has these files open — so a later O(chunks) `AVAudioFile` open per
    /// button press (re-detect, opening the rename dialog) can read this instead (#204).
    /// A chunk whose duration can't be read gets `0`, a sentinel `SpeakerSampleLocator` treats as
    /// "distrust the cache, re-read the file" rather than a real zero-length chunk.
    public static func reconcileAudioPaths(in jsonPath: URL, to paths: [URL]) {
        TranscriptWrites.exclusive(jsonPath) { reconcileAudioPathsUnlocked(in: jsonPath, to: paths) }
    }

    private static func reconcileAudioPathsUnlocked(in jsonPath: URL, to paths: [URL]) {
        guard let data = try? Data(contentsOf: jsonPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var metadata = json["metadata"] as? [String: Any]
        else { return }

        metadata["audio_paths"] = paths.map { $0.path }
        metadata["audio_files"] = paths.map { $0.lastPathComponent }
        metadata["chunk_durations"] = paths.map(Self.duration(of:))
        json["metadata"] = metadata

        guard let updated = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        // Durable (final review R-M9): on the `run()` path the source WAVs are already archived and deleted — a power loss
        // after an unsynced write would leave a transcript naming files that no longer exist.
        try? DurableFile.replace(jsonPath, with: updated)
        Logger.files.info("Reconciled audio paths in \(jsonPath.lastPathComponent, privacy: .sensitive) → \(paths.count) source(s)")
    }

    static func duration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0, file.length > 0
        else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
