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
        public let speakerCount: Int
        public let segmentsRelabeled: Int
    }

    /// A coarse phase report for a running `rediarize`, so a caller can show more than a bare
    /// spinner on a call that can take minutes (#203). `fraction`, when present, is 0...1 within
    /// the CURRENT phase — chunk-splitting is trivially countable (N of M chunks), and the
    /// diarizer/VAD backend also reports its own chunk progress during `detectingSpeakers`.
    public struct Progress: Sendable, Equatable {
        public enum Phase: Sendable, Equatable {
            /// Decoding the channel's audio to mono samples (the old "splitting + concatenating").
            case decodingAudio
            /// Running the diarizer (and VAD) over the decoded samples.
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

        public var errorDescription: String? {
            switch self {
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
    public static func rediarize(
        transcript url: URL,
        source: String,
        speakerCount: Int,
        diarizer: any DiarizationProvider,
        vadSpeechThreshold: Double = 0.5,
        scratchDirectory: URL = FileManager.default.temporaryDirectory,
        onProgress: (@Sendable (Progress) -> Void)? = nil
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

        // Decode ONCE, at the target format (16 kHz mono Float), and share the same buffer with
        // both the diarizer and VAD below (#204) — the old path decoded the channel's audio up to
        // four separate times (split, concatenate, diarizer's own decode, VAD's own decode).
        //
        // `.legacyDualStream` is a single file with nothing to concatenate, so there is no
        // decode-reuse to be had there: our own `AudioDecode` pass would just add a full extra
        // in-memory copy (~3x the file's decoded size, once for the native-rate read and again
        // for the resample) on top of what the diarizer and VAD already hold internally. Handing
        // them the path instead lets them stream it with FluidAudio's own decoder, matching the
        // pre-#204 memory profile for this case — and, as a side effect, keeps the `AudioDecode`
        // reimplementation (see its doc comment) out of the picture entirely for single-file
        // recordings, which is most of them.
        onProgress?(Progress(phase: .decodingAudio))
        let decoded = try await decodeChannelAudio(
            layout: layout, source: source, scratchDirectory: scratchDirectory,
            onProgress: onProgress)

        // The user's answer is authoritative: force the count AND skip minority absorption, which
        // exists to second-guess a count nobody supplied.
        // Decoding the channel can be the slowest phase on a multi-chunk recording; without a
        // check here a cancel during that work goes unnoticed until a full diarize has also run.
        try Task.checkCancellation()
        onProgress?(Progress(phase: .detectingSpeakers))
        let raw: DiarizationResult
        let speechMap: [SpeechRegion]?
        switch decoded {
        case .samples(let samples):
            raw = try await diarizer.diarize(
                audio: samples, numSpeakers: speakerCount,
                progress: { processed, total in
                    guard total > 0 else { return }
                    onProgress?(Progress(phase: .detectingSpeakers, fraction: Double(processed) / Double(total)))
                })
            // Same samples the diarizer just used — no second decode of the same audio.
            speechMap = try? await VadSpeechMap().analyze(samples: samples)
        case .path(let audioURL):
            // No pre-decoded buffer to share here (see the comment above) — each backend decodes
            // its own copy, same as before #204 for this layout. No per-chunk progress fraction is
            // available on this route either, but the coarser phase indicator still applies.
            raw = try await diarizer.diarize(audioPath: audioURL, numSpeakers: speakerCount)
            speechMap = try? await VadSpeechMap().analyze(audioPath: audioURL)
        }
        // The diarizer's "forced" count is a target, not a ceiling — asking for 1 on an 82-minute
        // call still returned 2 (#201). Enforce it here, where the clusters and their embeddings
        // are both in hand, rather than hoping the clusterer honours the request.
        let diarization = SpeakerCountEnforcer.enforce(raw, to: speakerCount)
        try Task.checkCancellation()

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
            // nil, not the config value: `speakerCountIsUserStated: true` disables absorption
            // outright, so passing a share would imply a knob that has no effect on this path.
            minSpeakerShare: nil,
            speakerCountIsUserStated: true)

        var labeled = result.labeled
        // `mergeRelabeled` replaces the channel WHOLESALE, so an empty relabeling would delete every
        // segment this channel had. That is never the right outcome for a transcript that demonstrably
        // contained speech a moment ago: it means diarization or VAD returned nothing, and losing the
        // words is far worse than leaving the speaker labels as they were.
        guard !labeled.isEmpty || transcriptSegments.isEmpty else {
            Logger.transcription.error(
                "Re-diarize produced no labels for \(source, privacy: .public) from \(transcriptSegments.count, privacy: .public) segments — refusing to write")
            throw RediarizeError.producedNoLabels(source)
        }
        // Before the source prefix goes on, while labels are still raw: a stated count of 1 means
        // every word on this channel belongs to that one person, including the ones the assigner
        // could not tie to a diarization turn.
        labeled = SpeakerCountEnforcer.foldUnattributed(labeled, statedCount: speakerCount)
        for i in labeled.indices { labeled[i].source = source }
        SpeakerAssignment.tagWithSourcePrefix(&labeled)

        json["segments"] = mergeRelabeled(into: rawSegments, source: source, relabeled: labeled)
        // The channel's names go, they are not carried over — see `clearingChannelNames`. The
        // dialog warns before reaching here, so this is never a surprise.
        metadata = clearingChannelNames(in: metadata, source: source)
        // Persist what the diarizer actually PRODUCED, not what was requested. They diverge — on
        // 2026-09-02 a request for 2 could yield 1 — and a stored request would misreport the
        // transcript's own contents to anything reading it back, including the stepper's pre-fill.
        // "Unknown" is an absence of attribution, not a person: counting it told the stepper there
        // were 2 speakers on a channel holding one speaker plus some unattributable backchannels.
        // Built from `labelPrefix(for:)` so the channel-prefix format lives in one place. Note this
        // is a runtime string comparison, NOT a compile-time guarantee: if `tagWithSourcePrefix`
        // ever stops using "<Prefix><Unknown>", this silently over-counts again, so the two must
        // change together.
        let unattributed = labelPrefix(for: source) + SpeakerAssignment.unknownSpeaker
        let found = Set(labeled.map { $0.speaker }).subtracting([unattributed]).count
        metadata["speaker_count_\(source)"] = found
        json["metadata"] = metadata

        // Last check before the only irreversible step. Cancelling after diarization has run just
        // wastes the work; cancelling after this leaves a transcript the user asked us not to write.
        try Task.checkCancellation()
        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
        Logger.transcription.info(
            "Re-diarized \(source, privacy: .public) at \(speakerCount, privacy: .public) speakers: \(found, privacy: .public) label(s) across \(labeled.count, privacy: .public) segments")
        return Outcome(speakerCount: found, segmentsRelabeled: labeled.count)
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

    /// What `decodeChannelAudio` hands back: either pre-decoded samples ready to share between
    /// the diarizer and VAD, or a path for them to decode themselves.
    ///
    /// Never returned from a `public` API — `private` keeps it out of the module's internal
    /// namespace and signals that intent to future readers.
    private enum DecodedChannelAudio {
        case samples([Float])
        case path(URL)
    }

    /// Decode the requested channel to mono Float samples at the diarizer/VAD target rate
    /// (16 kHz), concatenating chunks in THAT domain when needed — about 6x smaller than the
    /// 48kHz stereo source, and it lets the caller skip the old file-based concatenation step
    /// entirely (#204). A stereo chunk is split down to just the wanted side first
    /// (`AudioSourceResolver.splitChannel`), so neither the decode nor the write ever touches the
    /// unwanted side.
    ///
    /// `.legacyDualStream` is a single file, so there's nothing to concatenate and therefore no
    /// decode-reuse benefit to justify pre-decoding it into an extra in-memory copy — that case
    /// hands back the path instead and lets the diarizer/VAD stream it themselves, same as before
    /// #204.
    private static func decodeChannelAudio(
        layout: AudioLayout,
        source: String,
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
            let existing = chunks.filter { FileManager.default.fileExists(atPath: $0.path) }
            var combined: [Float] = []
            for (index, chunk) in existing.enumerated() {
                // Per-iteration: decoding one chunk is itself slow, so a cancel during chunk 2 of
                // 10 should not wait for the remaining eight.
                try Task.checkCancellation()
                // Reported AFTER this chunk is done (index + 1), not before: reporting before
                // meant the bar topped out at (N-1)/N and never reached 1.0 before the phase
                // switched to .detectingSpeakers — visibly "snapping" past the last chunk. `defer`
                // so a `.skip` chunk (which `continue`s early) still advances the fraction.
                defer { onProgress?(Progress(phase: .decodingAudio, fraction: Double(index + 1) / Double(existing.count))) }
                switch channelRole(of: chunk, wantsLocal: wantsLocal) {
                case .skip:
                    continue
                case .useDirectly:
                    combined.append(contentsOf: try AudioDecode.mono16kHzFloat(contentsOf: chunk))
                case .needsSplit:
                    let channel: AudioSourceResolver.Channel = wantsLocal ? .local : .remote
                    let split = try await AudioSourceResolver.splitChannel(
                        stereoAac: chunk, outputDirectory: scratchDirectory, channel: channel)
                    defer { try? FileManager.default.removeItem(at: split) }
                    combined.append(contentsOf: try AudioDecode.mono16kHzFloat(contentsOf: split))
                }
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
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity) else {
            throw DecodeError.bufferAllocationFailed
        }

        var provided = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if provided {
                status.pointee = .endOfStream
                return nil
            }
            provided = true
            status.pointee = .haveData
            return buffer
        }
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error else { throw DecodeError.conversionFailed(error) }
        guard let channelData = outputBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
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
        // Generous headroom over the exact ratio: a converter that under-allocates truncates
        // trailing audio rather than erroring, which would silently shorten every decode.
        let estimatedFrames = Double(samples.count) * outputRate / inputRate
        let capacity = AVAudioFrameCount(estimatedFrames.rounded(.up)) + 4096
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw DecodeError.bufferAllocationFailed
        }

        var provided = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if provided {
                status.pointee = .endOfStream
                return nil
            }
            provided = true
            status.pointee = .haveData
            return inputBuffer
        }
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error else { throw DecodeError.conversionFailed(error) }
        guard let channelData = outputBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }
}
