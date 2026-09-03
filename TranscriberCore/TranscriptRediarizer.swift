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
    /// when a speaker change lands mid-segment — measured 73 → 84 segments on `150633-Paul
    /// feedback` — so the target source is replaced wholesale rather than patched in place.
    public static func mergeRelabeled(
        into segments: [[String: Any]],
        source: String,
        relabeled: [LabeledSegment]
    ) -> [[String: Any]] {
        var kept = segments.filter { ($0["source"] as? String) != source }
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
            return dict
        })
        return kept.sorted { ($0["start"] as? Double ?? 0) < ($1["start"] as? Double ?? 0) }
    }

    /// Drop `speaker_names` entries for labels the re-diarization no longer produces.
    ///
    /// A stale entry is not merely untidy: speaker numbering is positional, so "Local Speaker 3"
    /// surviving a run that yields two local speakers would either apply a name to nobody or —
    /// if a later run produces three again — attach an old name to a different person.
    /// Only the re-diarized channel is pruned; the other channel's names are none of our business.
    public static func prunedSpeakerNames(
        _ names: [String: String],
        source: String,
        survivingLabels: Set<String>
    ) -> [String: String] {
        let prefix = source == "local" ? "Local " : "Remote "
        return names.filter { !$0.key.hasPrefix(prefix) || survivingLabels.contains($0.key) }
    }

    // MARK: - Orchestration

    public struct Outcome: Sendable {
        public let speakerCount: Int
        public let segmentsRelabeled: Int
    }

    public enum RediarizeError: LocalizedError {
        case unreadableTranscript
        case noAudioForChannel(String)
        case invalidSpeakerCount(Int)

        public var errorDescription: String? {
            switch self {
            case .unreadableTranscript: return "Could not read the transcript."
            case .noAudioForChannel(let c): return "No \(c) audio is available for this recording."
            case .invalidSpeakerCount(let n): return "\(n) is not a valid number of speakers."
            }
        }
    }

    /// Re-diarize one channel at `speakerCount` and rewrite the transcript in place.
    ///
    /// **Relabels only — it does not re-run ASR.** The words stay exactly as recorded; only speaker
    /// attribution changes. Re-transcribing would produce marginally better turn boundaries (word
    /// timings let #120 split a segment where a speaker change lands mid-sentence), but silently
    /// rewriting what was *said* to fix who said it is the wrong trade for a record people rely on.
    public static func rediarize(
        transcript url: URL,
        source: String,
        speakerCount: Int,
        diarizer: any DiarizationProvider,
        vadSpeechThreshold: Double = 0.5,
        scratchDirectory: URL = FileManager.default.temporaryDirectory
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

        let (channelAudio, isTemporary) = try await resolveChannelAudio(
            layout: layout, source: source, scratchDirectory: scratchDirectory)
        defer { if isTemporary { try? FileManager.default.removeItem(at: channelAudio) } }

        // The user's answer is authoritative: force the count AND skip minority absorption, which
        // exists to second-guess a count nobody supplied.
        let diarization = try await diarizer.diarize(audioPath: channelAudio, numSpeakers: speakerCount)
        let speechMap = try? await VadSpeechMap().analyze(audioPath: channelAudio)

        let transcriptSegments = rawSegments
            .filter { ($0["source"] as? String) == source }
            .compactMap { dict -> TranscriptSegment? in
                guard let start = dict["start"] as? Double,
                      let end = dict["end"] as? Double,
                      let text = dict["text"] as? String else { return nil }
                return TranscriptSegment(
                    start: start, end: end, text: text,
                    language: dict["language"] as? String,
                    confidence: (dict["confidence"] as? Double).map(Float.init))
            }

        let result = StreamLabeling.withDiarization(
            segments: transcriptSegments,
            diarizationResult: diarization,
            speechMap: speechMap,
            vadSpeechThreshold: vadSpeechThreshold,
            speakerCountIsUserStated: true)

        var labeled = result.labeled
        for i in labeled.indices { labeled[i].source = source }
        SpeakerAssignment.tagWithSourcePrefix(&labeled)

        json["segments"] = mergeRelabeled(into: rawSegments, source: source, relabeled: labeled)
        if let names = metadata["speaker_names"] as? [String: String] {
            metadata["speaker_names"] = prunedSpeakerNames(
                names, source: source, survivingLabels: Set(labeled.map { $0.speaker }))
        }
        // Persist what the diarizer actually PRODUCED, not what was requested. They diverge — on
        // 2026-09-02 a request for 2 could yield 1 — and a stored request would misreport the
        // transcript's own contents to anything reading it back, including the stepper's pre-fill.
        let found = Set(labeled.map { $0.speaker }).count
        metadata["speaker_count_\(source)"] = found
        json["metadata"] = metadata

        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
        Logger.transcription.info(
            "Re-diarized \(source, privacy: .public) at \(speakerCount, privacy: .public) speakers: \(found, privacy: .public) label(s) across \(labeled.count, privacy: .public) segments")
        return Outcome(speakerCount: found, segmentsRelabeled: labeled.count)
    }

    /// What a chunk file can contribute to one channel's audio.
    public enum ChannelRole: Equatable {
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
    public static func channelRole(of chunk: URL, wantsLocal: Bool) -> ChannelRole {
        if SpeakerSampleLocator.isLocalOnly(chunk) { return wantsLocal ? .useDirectly : .skip }
        if SpeakerSampleLocator.isSystemOnly(chunk) { return wantsLocal ? .skip : .useDirectly }
        return .needsSplit
    }

    /// Produce a mono file holding just the requested channel, concatenating chunks when needed.
    /// Returns `isTemporary: true` when the caller must clean the file up.
    private static func resolveChannelAudio(
        layout: AudioLayout,
        source: String,
        scratchDirectory: URL
    ) async throws -> (URL, Bool) {
        let wantsLocal = source == "local"
        switch layout {
        case .unavailable:
            throw RediarizeError.noAudioForChannel(source)

        case .legacyDualStream(let remote, let local):
            guard let url = wantsLocal ? local : remote,
                  FileManager.default.fileExists(atPath: url.path)
            else { throw RediarizeError.noAudioForChannel(source) }
            return (url, false)

        case .chunkedArchives(let chunks):
            var channels: [URL] = []
            // Every split file we create is a temp file we own. A throw from splitChannels on a
            // later chunk, or from concatenate after the loop, used to leave the ones already
            // produced behind — and on a multi-chunk recording those are hundreds of MB.
            var temporaries: [URL] = []
            var handedOff = false
            defer {
                if !handedOff {
                    for t in temporaries { try? FileManager.default.removeItem(at: t) }
                }
            }
            for chunk in chunks where FileManager.default.fileExists(atPath: chunk.path) {
                switch channelRole(of: chunk, wantsLocal: wantsLocal) {
                case .skip:
                    continue
                case .useDirectly:
                    channels.append(chunk)
                case .needsSplit:
                    let split = try await AudioSourceResolver.splitChannels(
                        stereoAac: chunk, outputDirectory: scratchDirectory)
                    let wanted = wantsLocal ? split.local : split.remote
                    channels.append(wanted)
                    temporaries.append(wanted)
                    try? FileManager.default.removeItem(at: wantsLocal ? split.remote : split.local)
                }
            }
            guard !channels.isEmpty else { throw RediarizeError.noAudioForChannel(source) }
            if channels.count == 1 {
                // A single chunk needs no concatenation. Only a SPLIT file is ours to delete; an
                // original mono fallback WAV must survive, so hand back whether it is temporary.
                let single = channels[0]
                let isTemporary = temporaries.contains(single)
                handedOff = isTemporary
                return (single, isTemporary)
            }
            // Diarize the whole timeline at once rather than per chunk: one clustering pass over
            // every chunk needs no cross-chunk reconciliation and cannot disagree with itself.
            let joined = try await AudioConcatenator.concatenate(
                sources: channels, outputDirectory: scratchDirectory,
                outputName: "rediarize-\(source)")
            for t in temporaries { try? FileManager.default.removeItem(at: t) }
            temporaries = []
            handedOff = true
            return (joined.outputPath, true)
        }
    }
}
