import Foundation
import os

public struct TranscriptionResult {
    public let jsonPath: URL

    public init(jsonPath: URL) {
        self.jsonPath = jsonPath
    }
}

@MainActor
public final class TranscriptionRunner {
    public enum RunnerError: LocalizedError {
        case engineNotReady(String)
        case engineUnavailable(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .engineNotReady(let name):
                return "Engine '\(name)' is not ready. It may need to download a model first."
            case .engineUnavailable(let name):
                return "Engine '\(name)' is not available on this version of macOS."
            case .failed(let msg):
                return msg
            }
        }
    }

    private var transcriber: (any TranscriptionEngine)?
    private var lastEngineID: EngineID?
    private var diarizer: (any DiarizationProvider)? = FluidAudioDiarizer()
    /// False once `disableDiarization()` turns diarization off, so config changes never clobber
    /// that explicit choice.
    private var diarizerIsDefault = true
    /// The settings the current default diarizer was built with. Rebuilding it on every job would
    /// discard the actor's cached OfflineDiarizerManager and reload the ML models each recording.
    private var diarizerSettings: (threshold: Double?, maxSpeakers: Int?, excludeOverlap: Bool)?
    private let vadSpeechMap = VadSpeechMap()

    public private(set) var chunkRotator: ChunkRotator?
    public private(set) var chunkProcessor: ChunkProcessor?

    /// Test seam: `setupChunkedPipeline` throws before creating the processor.
    var failSetupForTesting = false
    /// Test seam: `finalize` sleeps this long before doing anything.
    var finalizeDelayForTesting: Duration?
    /// Where the transcript's looks at its folder run — which chunk files are there, the leftover WAVs, the mic file —
    /// off the main actor, bounded (L review 158). The coordinator hands over its own; tests inject one that hangs.
    public var folderReads: FolderReads = .shared
    /// The bound on one such look, in awake seconds; a folder that does not answer throws `FolderNotAnswering`.
    public var folderReadSeconds: Double = 15
    /// The bound on the transcript's writes (L review 185), in awake seconds: longer than a look — a slow share writes a
    /// long meeting's record — but never unbounded. Past it the write is not waited for: `FolderNotAnswering`, and nothing
    /// is claimed.
    public var folderWriteSeconds: Double = 30
    private enum SetupFailure: Error { case forTesting }

    private let wavHeaderSize = 44
    private var detectedLanguages: [String] = []

    public init() {}

    public func run(
        systemAudio: URL,
        micAudio: URL?,
        outputDirectory: URL,
        config: Config,
        provenance: CaptureProvenance? = nil
    ) async throws -> TranscriptionResult {
        let startTime = ContinuousClock.now
        detectedLanguages = []
        applyDiarizerConfig(config)

        let engineID = config.engine
        if transcriber == nil || lastEngineID != engineID {
            Logger.transcription.info("Creating engine: \(engineID.descriptor.displayName, privacy: .public)")
            transcriber = try createEngine(for: engineID, config: config)
            lastEngineID = engineID
        }

        guard let transcriber = transcriber else {
            throw RunnerError.failed("Failed to initialize transcription engine")
        }

        let isDualStream = micAudio != nil
        let segments: [(system: URL, mic: URL)]
        if let micAudio {
            segments = Self.discoverSegments(systemAudio: systemAudio, micAudio: micAudio)
        } else {
            // No mic — create tuples with system-only URLs (mic will be skipped below)
            segments = Self.discoverSegments(systemAudio: systemAudio, micAudio: systemAudio)
        }
        // Repair any orphaned segment whose header was never finalized (writer killed
        // mid-recording) so the recovered PCM is decodable — the chunked path repairs in
        // ChunkProcessor, this is the single-file / crash-recovery / CLI path (#85).
        repairSegmentHeaders(segments)
        var allSegments: [LabeledSegment] = []
        var audioPaths: [URL] = []
        // Captured from a single-segment embedding (length == dim) before any accumulation,
        // so EchoDeduplicator can pool multi-segment embeddings without inferring the dim.
        var embeddingDim = 0
        // #93: every segment that actually contributed audio, so each (not just the base pair)
        // is archived to its own AAC and reflected in the transcript's audio_paths.
        var contributingPairs: [AudioArchiver.SegmentPair] = []
        // Each per-segment WAV starts at its own file-relative t=0 (#135 H2): segment 2's
        // "minute 2" is not the same instant as segment 1's "minute 2". Collected here, per
        // segment, so a cumulative offset can be added to every timestamp below before merge —
        // segment 0 keeps offset 0, so single-file behaviour is unchanged.
        var perSegmentSystem: [[LabeledSegment]] = []
        var perSegmentMic: [[LabeledSegment]] = []
        // Each segment is diarized independently, so segment 1's "Speaker 1" and segment 2's
        // "Speaker 1" are unrelated raw labels (#135 H3). Kept per-segment (never merged with
        // `existing + new` — that concatenated two different people's embeddings under one key)
        // so `reconcileRecoverySegments` can reconcile them into one global namespace below.
        var perSegmentRemoteDb: [[String: [Float]]] = []
        var perSegmentLocalDb: [[String: [Float]]] = []

        for (index, segmentPair) in segments.enumerated() {
            if index > 0 {
                Logger.transcription.info("Transcribing recovery segment \(index + 1)")
            }

            let systemResult = try await transcribeStream(
                audioPath: segmentPair.system,
                source: "remote",
                transcriber: transcriber,
                label: "system\(index > 0 ? "-\(index + 1)" : "")",
                audioSource: .system,
                config: config
            )
            perSegmentSystem.append(systemResult.segments)
            if embeddingDim == 0 {
                embeddingDim = systemResult.speakerDatabase.values.first(where: { !$0.isEmpty })?.count ?? 0
            }
            perSegmentRemoteDb.append(systemResult.speakerDatabase)
            audioPaths.append(segmentPair.system)

            var segmentMic: URL?
            var micSegments: [LabeledSegment] = []
            var micSpeakerDb: [String: [Float]] = [:]
            if isDualStream {
                let micPath = segmentPair.mic
                // Off the main actor, bounded (L review 158).
                guard let micThere = await folderReads.read("transcript: mic file", folder: micPath.deletingLastPathComponent().path,
                                                            key: micPath.path, seconds: folderReadSeconds, { FileManager.default.fileExists(atPath: micPath.path) })
                else { throw FolderNotAnswering() }
                if micThere {
                    let micResult = try await transcribeStream(
                        audioPath: micPath,
                        source: "local",
                        transcriber: transcriber,
                        label: "mic\(index > 0 ? "-\(index + 1)" : "")",
                        audioSource: .microphone,
                        config: config
                    )
                    micSegments = micResult.segments
                    micSpeakerDb = micResult.speakerDatabase
                    audioPaths.append(micPath)
                    segmentMic = micPath
                }
            }
            perSegmentMic.append(micSegments)
            perSegmentLocalDb.append(micSpeakerDb)

            // #93: record this segment for archival if it carried real audio (system payload
            // past the WAV header, or a mic file existed). Skips header-only orphans.
            let sysSize = (try? FileManager.default.attributesOfItem(atPath: segmentPair.system.path)[.size] as? Int) ?? 0
            if sysSize > wavHeaderSize || segmentMic != nil {
                contributingPairs.append(AudioArchiver.SegmentPair(system: segmentPair.system, mic: segmentMic))
            }
        }

        // Reconcile each channel's per-segment speaker labels into one global namespace (#135
        // H3), reusing SpeakerReconciler's cosine matching exactly as finalize() does across
        // chunks — never a hand-rolled comparator. Each channel is its own namespace (mirrors
        // how finalize() reconciles Local/Remote separately for dual-stream): a mic speaker never
        // merges with a system speaker even if their embeddings happen to be similar.
        let remoteMapping = Self.reconcileRecoverySegments(databases: perSegmentRemoteDb, threshold: 0.65)
        let localMapping = isDualStream
            ? Self.reconcileRecoverySegments(databases: perSegmentLocalDb, threshold: 0.65)
            : [:]

        // Global speaker databases keyed by the RECONCILED label, built from the per-segment
        // databases above — one representative embedding per global speaker (the first segment
        // it appears in), never the old `existing + new` concatenation of two different people's
        // vectors under a shared per-segment label.
        var remoteSpeakerDb: [String: [Float]] = [:]
        for (index, db) in perSegmentRemoteDb.enumerated() {
            for (localLabel, embedding) in db {
                let globalLabel = remoteMapping["\(index):\(localLabel)"] ?? localLabel
                if remoteSpeakerDb[globalLabel] == nil {
                    remoteSpeakerDb[globalLabel] = embedding
                }
            }
        }
        var localSpeakerDb: [String: [Float]] = [:]
        for (index, db) in perSegmentLocalDb.enumerated() {
            for (localLabel, embedding) in db {
                let globalLabel = localMapping["\(index):\(localLabel)"] ?? localLabel
                if localSpeakerDb[globalLabel] == nil {
                    localSpeakerDb[globalLabel] = embedding
                }
            }
        }

        // Each segment's physical duration: prefer the actual WAV length on disk (accurate even
        // when ASR/VAD trims trailing silence from the transcript) — falling back to that
        // segment's own transcript max `end` only when the WAV can't be read (corrupt/missing
        // even after header repair above), since some duration beats leaving later segments
        // un-offset entirely. When BOTH are unavailable (unreadable WAV *and* the engine returned
        // no segments, e.g. a silent chunk) fall back to the configured chunk length rather than
        // 0: a zero would give the next segment this segment's own offset — collapsing timestamps
        // across the boundary, exactly what no offset logic would do — whereas the chunk length
        // keeps offsets monotonic (over-shooting a truncated final chunk is harmless; collapsing
        // is not).
        let chunkLengthFallback = Double(config.validatedChunkDuration) * 60
        let segmentDurations: [Double] = zip(segments, zip(perSegmentSystem, perSegmentMic)).map { pair, streams in
            let (system, mic) = streams
            if let firstDuration = SpeakerSampleLocator.durations(of: [pair.system]).first, let physical = firstDuration {
                return physical
            }
            Logger.transcription.warning("Recovery segment: could not read physical WAV duration for \(pair.system.lastPathComponent, privacy: .sensitive); falling back to transcript end (then configured chunk length) for the offset of the next segment")
            return (system + mic).map(\.end).max() ?? chunkLengthFallback
        }
        let segmentOffsets = Self.segmentStartOffsets(durations: segmentDurations)

        for (index, offset) in segmentOffsets.enumerated() {
            var systemSegs = perSegmentSystem[index]
            var micSegs = perSegmentMic[index]
            // Relabel with the globally-reconciled speaker (#135 H3) before merging segments
            // across segments — otherwise segment 1's "Speaker 1" and segment 2's "Speaker 1"
            // (unrelated people, both diarized locally as "Speaker 1") would collide in the
            // merged transcript. A label with no mapping entry (e.g. "Unknown", which carries no
            // embedding) is left as-is.
            for i in systemSegs.indices {
                if let global = remoteMapping["\(index):\(systemSegs[i].speaker)"] {
                    systemSegs[i].speaker = global
                }
            }
            for i in micSegs.indices {
                if let global = localMapping["\(index):\(micSegs[i].speaker)"] {
                    micSegs[i].speaker = global
                }
            }
            if offset > 0 {
                for i in systemSegs.indices {
                    systemSegs[i].start += offset
                    systemSegs[i].end += offset
                }
                for i in micSegs.indices {
                    micSegs[i].start += offset
                    micSegs[i].end += offset
                }
            }
            allSegments.append(contentsOf: systemSegs)
            allSegments.append(contentsOf: micSegs)
        }

        if isDualStream && !allSegments.isEmpty {
            SpeakerAssignment.resolveUnknownsWithinSource(&allSegments, sourceSpeakerCounts: [
                "local": localSpeakerDb.count,
                "remote": remoteSpeakerDb.count,
            ])
            SpeakerAssignment.tagWithSourcePrefix(&allSegments)
        }

        allSegments.sort { $0.start < $1.start }
        Logger.transcription.info("Total segments after merge: \(allSegments.count, privacy: .public)")

        // Echo dedup (remove mic bleed of remote speaker)
        var echoRemoved = 0
        if isDualStream {
            let dedupResult = EchoDeduplicator.deduplicate(
                segments: allSegments,
                localSpeakerDatabase: localSpeakerDb,
                remoteSpeakerDatabase: remoteSpeakerDb,
                temporalThreshold: config.echoTemporalThreshold,
                textThreshold: config.echoTextThreshold,
                embeddingThreshold: config.echoEmbeddingThreshold,
                embeddingDim: embeddingDim > 0 ? embeddingDim : nil
            )
            allSegments = dedupResult.segments
            echoRemoved = dedupResult.flaggedCount
        }

        let uniqueLanguages = Set(detectedLanguages)
        let detectedLanguage: String
        switch uniqueLanguages.count {
        case 0: detectedLanguage = "auto"
        case 1: detectedLanguage = uniqueLanguages.first!
        default: detectedLanguage = "multilingual"
        }

        let json = TranscriptAssembler.assemble(
            segments: allSegments,
            audioPaths: audioPaths,
            outputFormat: config.outputFormat,
            language: detectedLanguage,
            numSpeakers: nil,
            diarization: diarizer != nil,
            dualStream: isDualStream,
            echoSegmentsRemoved: echoRemoved,
            provenance: provenance,
            // No in-memory session start here (CLI / crash-recovery / single-file path), so
            // use the source audio's creation time as the recording-start stamp (#49).
            recordedAt: (try? systemAudio.resourceValues(forKeys: [.creationDateKey]).creationDate)
        )

        let baseName = systemAudio.deletingPathExtension().lastPathComponent
        let jsonPath = outputDirectory.appendingPathComponent(baseName + ".json")
        try TranscriptAssembler.write(json, to: jsonPath)

        do {
            try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)
        } catch {
            Logger.files.error("Failed to write format file: \(error, privacy: .private)")
        }

        // #93: archive EVERY contributing segment to its own stereo AAC (L=mic, R=system),
        // not just the base pair — a crash-recovered recording has multiple segments and the
        // pre-#93 code silently dropped all but the first. archiveAll is per-segment isolated:
        // a failed segment keeps its WAV rather than aborting the whole archive.
        if isDualStream && !contributingPairs.isEmpty {
            let archived = await AudioArchiver.archiveAll(
                pairs: contributingPairs,
                outputDirectory: outputDirectory,
                bitrateKbps: config.archiveBitrateKbps,
                preserveSourceWAV: config.preserveSourceWAV ?? false
            )
            TranscriptAssembler.reconcileAudioPaths(in: jsonPath, to: archived)
            Logger.files.info("Archived \(archived.count, privacy: .public) segment(s)")

            do {
                try StorageManager.enforceQuota(
                    in: outputDirectory,
                    limitHours: config.audioArchiveLimitHours,
                    bitrateKbps: config.archiveBitrateKbps,
                    protectedFiles: archived   // every file the transcript lists (round 7 item 1)
                )
            } catch {
                Logger.files.error("Quota enforcement failed: \(error, privacy: .private)")
            }
        }

        let elapsed = ContinuousClock.now - startTime
        Logger.transcription.info("Transcription pipeline complete — \(elapsed.components.seconds)s, output: \(jsonPath.lastPathComponent, privacy: .sensitive)")

        return TranscriptionResult(jsonPath: jsonPath)
    }

    /// Finalize a chunked recording session: reconcile speakers, merge chunks, write transcript.
    public func finalize(
        sessionState: SessionState,
        outputDirectory: URL,
        config: Config
    ) async throws -> TranscriptionResult {
        if let d = finalizeDelayForTesting { try await Task.sleep(for: d) }
        let startTime = ContinuousClock.now

        // 1. Speaker reconciliation — chunks must be in recording order so the reconciler's
        // greedy cosine matching builds reference embeddings chronologically. (#56)
        let sortedChunks = sessionState.chunks.sorted { $0.index < $1.index }
        // Dual-stream chunks carry `Local/Remote Speaker N` segment labels; the reconciler must
        // reconcile each channel in its own prefixed namespace so its output keys match those labels
        // (otherwise the remap is inert — the #64/#71 bug).
        //
        // Read the flag the WRITER persisted rather than re-deriving it here. Inferring it from
        // "does any chunk contain a local segment" could disagree with the per-chunk decision that
        // actually produced the labels — and when they disagreed, the reconciler's keys matched
        // nothing, the remap silently fell back to the identity, and chunk-local speaker numbering
        // was laundered into the global namespace.
        let chunksAreDualStream = sortedChunks.contains(where: \.isDualStream)
        Logger.transcription.info("Reconciling speakers across \(sortedChunks.count) chunks (dual-stream: \(chunksAreDualStream), cosine threshold: 0.65)")
        let speakerMapping = SpeakerReconciler.reconcile(
            chunks: sortedChunks,
            isDualStream: chunksAreDualStream,
            threshold: 0.65
        )

        // 2. Merge chunks
        let mergeResult = TranscriptMerger.merge(
            chunks: sortedChunks,
            speakerMapping: speakerMapping,
            meetingStart: sessionState.meetingStart
        )

        // 3. Convert MergedSegments to LabeledSegments for the assembler.
        //
        // This loop used to be a hand-rolled duplicate of TranscriptMerger.merge — so the merger
        // shipped nothing while carrying all the tests, and the code that actually produced every
        // transcript had none. Any fix applied to the tested merger would pass CI and change
        // nothing at runtime. Consume the merger instead, so the tests guard the real path.
        for (chunkIndex, labels) in mergeResult.unmappedLabels.sorted(by: { $0.key < $1.key }) {
            // Never silent: a miss means the reconciler's namespace and the chunk's labels disagree,
            // so the remap fell back to the identity and this chunk's speaker numbering may be wrong.
            Logger.transcription.error(
                "Speaker remap MISS in chunk \(chunkIndex, privacy: .public): labels \(labels.joined(separator: ", "), privacy: .private) are not in the reconciler's mapping. Speaker identity for this chunk may be wrong."
            )
        }

        var allSegments: [LabeledSegment] = mergeResult.segments.map { seg in
            LabeledSegment(
                start: seg.elapsed,
                end: seg.elapsedEnd,
                speaker: seg.speaker,
                text: seg.text,
                source: seg.source,
                confidence: seg.qualityScore,
                filtered: seg.filtered,
                echo: seg.echo,
                duplicate: seg.duplicate
            )
        }

        allSegments.sort { $0.start < $1.start }

        // 4. Dual-stream tagging
        // The capture-time flag the chunk writer persisted (P8, §7.2) — never re-derived from "did a
        // local segment survive": a dual-stream meeting where you said nothing is still dual-stream.
        let isDualStream = chunksAreDualStream
        if isDualStream {
            SpeakerAssignment.tagWithSourcePrefix(&allSegments)
        }

        // 5. Audio paths from chunks — must be in index order so AudioConcatenator
        // stitches them chronologically. (#56)
        let chunkAudioPaths = sortedChunks.map {
            outputDirectory.appendingPathComponent($0.audioPath)
        }

        // 4b. WAVs left next to an archived, registered chunk — a crash after the session.json write and
        // before their deletion (R2a M7). Never those the user keeps (preserve_source_wav), never an
        // ASR-failed chunk's (they are for re-transcription), never a chunk whose audio IS the WAV.
        // With which chunk files are there (5b) — and, for a re-run whose chunks an earlier finalize merged, the merged
        // file's length, the surviving chunks' and that finalize's merged-audio block: one look at the folder, off the main
        // actor, bounded (L reviews 158, 185) — a folder that does not answer is never finalized blind.
        let mergedURL = outputDirectory.appendingPathComponent("\(sessionState.sessionId).m4a")
        let transcriptURL = outputDirectory.appendingPathComponent(sessionState.sessionId + ".json")
        let removeLeftovers = !(config.preserveSourceWAV ?? false), leftoverChunks = sortedChunks
        let finalizingId = sessionState.sessionId
        guard let look = await folderReads.read("transcript: chunk files", folder: outputDirectory.path,
                                                key: outputDirectory.path + "#finalize:" + sessionState.sessionId, seconds: folderReadSeconds, {
            // Its own guard (L review 197): a session already finalized — its transcript verifies — is never finalized again
            // over it, whatever a gate upstream could or could not look at. Its leftovers are cleaned up (R2), and that is all.
            if CrashRecoveryPlanner.isFinalized(outputDirectory: outputDirectory, sessionId: finalizingId), TranscriptAssembler.verifies(transcriptURL) {
                CrashRecoveryPlanner.cleanupFinalized(outputDirectory: outputDirectory, sessionId: finalizingId)
                return FinalizeLook(present: [], alreadyFinalized: true)
            }
            if removeLeftovers { Self.removeLeftoverWAVs(of: leftoverChunks, in: outputDirectory) }
            return Self.lookBeforeFinalize(chunkAudioPaths: chunkAudioPaths, mergedURL: mergedURL, transcriptURL: transcriptURL)
        }) else { throw FolderNotAnswering() }
        if look.alreadyFinalized {
            Logger.state.error("A finalize found its session already finalized — its transcript is kept as it is, never written over")
            throw SessionAlreadyFinalized(transcript: transcriptURL.lastPathComponent)
        }
        let present = look.present

        // 5b. Concatenate chunk audio files into a single archive (if enabled and more than 1 chunk).
        // Each chunk carries its start time so a gap (crash restart, sleep) is kept as silence and the
        // merged audio stays on the transcript's wall-clock timeline (P9).
        let audioPaths: [URL]
        var mergedAudio: [String: Any]?
        var finalizeIssues: [SessionIssue] = []
        // Where the transcript placed each audio file on its wall-clock timeline (seconds from the
        // meeting start, as TranscriptMerger does) — re-detect rebuilds the same timeline from it.
        let perChunkOffsets = sortedChunks.map { $0.startTime.timeIntervalSince(sessionState.meetingStart) }
        var chunkOffsets = perChunkOffsets
        // A finalize RE-RUN after the first run merged the chunks and deleted them: the surviving
        // `<session>.m4a` is the recording's audio — list it, say so, and let the quota protect it.
        // A chunk whose own file still exists is NOT in it (a rebuild ingested it after the merge):
        // it is listed too, in time order with its offset, so every segment has audio behind it
        // (round 6 item 1). Not re-merged: the merged file is the only copy of the chunks it holds.
        let sourcesGone = present.contains(false)
        let mergedSeconds = look.mergedSeconds
        if chunkAudioPaths.count > 1, sourcesGone, mergedSeconds > 0 {
            // The merged file starts at the earliest chunk. A chunk is outside it only when it ENDS
            // past the merged file's end — never merely because its own file survived: with
            // preserve_source_wav on, the merged chunks' files survive too (round 7 item 2). The
            // merge keeps every chunk within one gap threshold of its wall-clock offset (sub-second
            // gaps are not padded), so a chunk inside it ends no later than the merged end plus that
            // threshold; one after it ends a whole chunk later (round 8 item 3: a tiny final chunk
            // was listed twice when measured from its start).
            let mergedOffset = perChunkOffsets.min() ?? 0
            let mergedEnd = mergedOffset + mergedSeconds + AudioConcatenator.gapThresholdSeconds
            let alongside = zip(zip(chunkAudioPaths, perChunkOffsets), zip(present, look.chunkSeconds))
                .filter { $0.1.0 && $0.0.1 + $0.1.1 > mergedEnd }.map(\.0)
            let listed = ([(mergedURL, mergedOffset)] + alongside).sorted { $0.1 < $1.1 }
            Logger.files.info("Chunk audio already merged into \(mergedURL.lastPathComponent, privacy: .sensitive) by an earlier finalize — using it, with \(alongside.count, privacy: .public) chunk file(s) not in it")
            audioPaths = listed.map(\.0)
            chunkOffsets = listed.map(\.1)
            var previous = look.previousMergedAudio ?? [:]
            previous["reused_existing"] = true
            if !alongside.isEmpty { previous["chunks_not_in_merge"] = alongside.count }
            mergedAudio = previous
        } else if config.mergeChunkedAudio && chunkAudioPaths.count > 1 {
            do {
                let concatResult = try await AudioConcatenator.concatenate(
                    chunks: sortedChunks.map {
                        ChunkAudio(url: outputDirectory.appendingPathComponent($0.audioPath), startTime: $0.startTime)
                    },
                    outputDirectory: outputDirectory,
                    outputName: sessionState.sessionId,
                    deleteSources: !(config.preserveSourceWAV ?? false)
                )
                audioPaths = [concatResult.outputPath]
                // The merged file starts at the earliest chunk and carries its gaps as silence.
                chunkOffsets = [perChunkOffsets.min() ?? 0]
                mergedAudio = [
                    "passthrough": concatResult.usedPassthrough,
                    "gaps_inserted_seconds": concatResult.gapsInsertedSeconds,
                ]
                Logger.files.info(
                    "Concatenated \(chunkAudioPaths.count, privacy: .public) chunks → \(concatResult.outputPath.lastPathComponent, privacy: .sensitive) (passthrough: \(concatResult.usedPassthrough, privacy: .public))"
                )
            } catch AudioConcatenatorError.implausibleTiming(let why) {
                // Refused before anything was written: the chunk files are the audio, and the record
                // says why they were not merged (round 5), with the reason (round 7 item 3).
                Logger.files.error("Audio not merged — implausible chunk timing (\(why, privacy: .public)); keeping separate files")
                audioPaths = chunkAudioPaths
                finalizeIssues.append(SessionIssue(chunk: nil, issue: ChunkIssue(code: .mergeSkippedImplausibleTiming, track: nil, count: nil, detail: why)))
            } catch {
                // concatenate() only deletes sources after a verified successful export,
                // so on throw the chunk files are still intact. The error can name files: private.
                Logger.files.error("Audio concatenation failed, keeping separate files: \(error, privacy: .private)")
                audioPaths = chunkAudioPaths
            }
        } else {
            audioPaths = chunkAudioPaths
        }

        // 6. Language detection
        let languages = Set(allSegments.compactMap(\.language))
        let detectedLanguage: String
        switch languages.count {
        case 0: detectedLanguage = "auto"
        case 1: detectedLanguage = languages.first!
        default: detectedLanguage = "multilingual"
        }

        // 6b. Storage quota enforcement, before the record is written so it can say what the quota
        // could not do. Never a file backing this record: every listed audio file, every chunk file,
        // and every archive of the session in the folder (rounds 7-8 item 1). Protecting only the
        // last listed file let a rebuild's quota pass delete the merged file — the only copy of the
        // earlier chunks. With the lengths the record lists: on the folder's queue, bounded — never on the main actor
        // (L review 185).
        let limitHours = config.audioArchiveLimitHours, bitrateKbps = config.archiveBitrateKbps, sessionId = sessionState.sessionId
        let protectedFiles = audioPaths + chunkAudioPaths + [mergedURL], listedAudio = audioPaths
        guard let measured = await folderReads.read("transcript: quota and lengths", folder: outputDirectory.path,
                                                    key: outputDirectory.path + "#finalize-measure:" + sessionId, seconds: folderReadSeconds, {
            Self.quotaAndLengths(in: outputDirectory, sessionId: sessionId, limitHours: limitHours, bitrateKbps: bitrateKbps,
                                 protectedFiles: protectedFiles, listedAudio: listedAudio)
        }) else { throw FolderNotAnswering() }
        if let overrun = measured.overrunBytes, overrun > 0,
           !sessionState.issues.contains(where: { $0.issue.code == .quotaExceededByCurrentSession }) {
            finalizeIssues.append(SessionIssue(chunk: nil, issue: ChunkIssue(
                code: .quotaExceededByCurrentSession, track: nil, count: nil, detail: "\(overrun) bytes over the quota")))
        }

        // 7. Assemble JSON
        let totalEchoRemoved = sessionState.chunks.reduce(0) { $0 + $1.echoSegmentsRemoved }
        let processingIssues = Self.processingIssueDictionaries(chunks: sortedChunks, sessionIssues: sessionState.issues + finalizeIssues)
        let json = TranscriptAssembler.assemble(
            segments: allSegments,
            audioPaths: audioPaths,
            outputFormat: config.outputFormat,
            language: detectedLanguage,
            numSpeakers: nil,
            // Diarization happened only if a diarizer ran AND no chunk's diarization failed (§7.2).
            diarization: diarizer != nil && !processingIssues.contains { $0["code"] as? String == ChunkIssue.Code.diarizationFailed.rawValue },
            dualStream: isDualStream,
            echoSegmentsRemoved: totalEchoRemoved,
            provenance: sessionState.provenance,
            // The wall-clock time the meeting actually began (#49).
            recordedAt: sessionState.meetingStart,
            captureGaps: sessionState.gaps,
            processingIssues: processingIssues,
            mergedAudio: mergedAudio,
            chunkDurations: measured.lengths,
            chunkOffsets: chunkOffsets
        )

        // 7b–10. The record's writes — the transcript, its finalized marker, the format file, the progress file's delete —
        // on the folder's queue, bounded, never on the main actor (L review 185): a share that stops answering mid-write
        // leaves the UI on "Finishing…", responsive. Past the bound nothing is claimed: `FolderNotAnswering`, and the
        // caller keeps the session for when the folder answers. The write may still land then — the finalized marker
        // it leaves is what the next pass finds.
        let data = try TranscriptAssembler.encode(json)
        let jsonPath = transcriptURL
        guard let written = await folderReads.read("transcript: write", folder: outputDirectory.path,
                                                   key: outputDirectory.path + "#finalize-write:" + sessionId, seconds: folderWriteSeconds, {
            Result { try Self.writeRecord(data, to: jsonPath, sessionId: sessionId, in: outputDirectory) }
        }) else {
            Logger.files.error("The transcript's write did not finish within \(self.folderWriteSeconds, privacy: .public) s — the recording folder is not answering")
            throw FolderNotAnswering()
        }
        try written.get()

        let elapsed = ContinuousClock.now - startTime
        Logger.transcription.info("Chunked pipeline finalized — \(elapsed.components.seconds)s, \(mergeResult.chunkCount) chunks, output: \(jsonPath.lastPathComponent, privacy: .sensitive)")

        return TranscriptionResult(jsonPath: jsonPath)
    }

    /// What `finalize` reads of the folder before it merges (L reviews 158, 185): which chunk files are there and — only
    /// for a re-run whose chunks an earlier finalize merged and deleted — the merged file's length, each surviving
    /// chunk's, and that finalize's `merged_audio` block. Blocking file work: only through `folderReads`.
    struct FinalizeLook {
        var present: [Bool]
        /// The session was already finalized, its transcript verifies (L review 197): nothing more is looked at or written.
        var alreadyFinalized = false
        var mergedSeconds: Double = 0
        /// Per chunk, its length when its file is there (0 otherwise).
        var chunkSeconds: [Double] = []
        var previousMergedAudio: [String: Any]?
    }

    nonisolated static func lookBeforeFinalize(chunkAudioPaths: [URL], mergedURL: URL, transcriptURL: URL) -> FinalizeLook {
        let present = chunkAudioPaths.map { FileManager.default.fileExists(atPath: $0.path) }
        guard chunkAudioPaths.count > 1, present.contains(false) else { return FinalizeLook(present: present) }
        let mergedSeconds = TranscriptAssembler.duration(of: mergedURL)
        guard mergedSeconds > 0 else { return FinalizeLook(present: present) }
        return FinalizeLook(present: present, mergedSeconds: mergedSeconds,
                            chunkSeconds: zip(chunkAudioPaths, present).map { $1 ? TranscriptAssembler.duration(of: $0) : 0 },
                            previousMergedAudio: previousMergedAudio(transcriptAt: transcriptURL))
    }

    /// The quota pass and the lengths of the audio the record lists (L review 185): `overrunBytes` nil when the quota pass
    /// failed (logged). Blocking file work: only through `folderReads`.
    nonisolated static func quotaAndLengths(in directory: URL, sessionId: String, limitHours: Int, bitrateKbps: Int,
                                            protectedFiles: [URL], listedAudio: [URL]) -> (overrunBytes: Int?, lengths: [Double]) {
        var overrun: Int?
        do {
            overrun = try StorageManager.enforceQuotaReport(
                in: directory, limitHours: limitHours, bitrateKbps: bitrateKbps,
                protectedFiles: protectedFiles + CrashRecoveryPlanner.sessionArchives(outputDirectory: directory, sessionId: sessionId)
            ).protectedOverrunBytes
        } catch {
            Logger.files.error("Quota enforcement failed: \(error, privacy: .private)")
        }
        return (overrun, listedAudio.map(TranscriptAssembler.duration(of:)))
    }

    /// The record's writes, in order (L review 185): stray temporaries swept, the transcript written durably, then —
    /// durably: this session is finished, so a lingering recovery file never re-finalizes over it (R2a item 12) — its
    /// marker (a failure leaves the transcript itself as the weaker marker), the format file, and the progress file's
    /// delete. Blocking file work: only through `folderReads`.
    nonisolated static func writeRecord(_ data: Data, to jsonPath: URL, sessionId: String, in directory: URL) throws {
        SessionState.sweepTemporaries(directory: directory, sessionId: sessionId)
        try TranscriptAssembler.write(data: data, to: jsonPath)
        do {
            try SessionState.markFinalized(directory: directory, sessionId: sessionId, transcript: jsonPath.lastPathComponent)
        } catch {
            Logger.state.error("Could not mark the session finalized: \(error, privacy: .private)")
        }
        do {
            try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)
        } catch {
            Logger.files.error("Failed to write format file: \(error, privacy: .private)")
        }
        SessionState.delete(directory: directory, sessionId: sessionId)
    }

    /// See step 4b of `finalize`.
    nonisolated static func removeLeftoverWAVs(of chunks: [ProcessedChunk], in directory: URL) {
        let fm = FileManager.default
        for chunk in chunks where chunk.audioPath.hasSuffix(".m4a") && !chunk.issues.contains(where: { $0.code == .asrFailed }) {
            guard fm.fileExists(atPath: directory.appendingPathComponent(chunk.audioPath).path) else { continue }
            let base = (chunk.audioPath as NSString).deletingPathExtension
            for name in [base + ".wav", base + "_mic.wav"] {
                let url = directory.appendingPathComponent(name)
                guard fm.fileExists(atPath: url.path) else { continue }
                do {
                    try fm.removeItem(at: url)
                    Logger.files.info("Removed a leftover WAV of archived chunk \(chunk.index, privacy: .public)")
                } catch {
                    Logger.files.error("Could not remove a leftover WAV of chunk \(chunk.index, privacy: .public): \(error, privacy: .private)")
                }
            }
        }
    }

    /// The `merged_audio` block of a transcript an earlier finalize wrote, if any.
    private nonisolated static func previousMergedAudio(transcriptAt url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (json["metadata"] as? [String: Any])?["merged_audio"] as? [String: Any]
    }

    /// Flatten per-chunk issues and session-level issues into the `metadata.processing_issues`
    /// shape `{chunk, code, track?, count?}` — optional fields omitted, never written as null.
    static func processingIssueDictionaries(chunks: [ProcessedChunk], sessionIssues: [SessionIssue]) -> [[String: Any]] {
        func dictionary(chunk: Int?, issue: ChunkIssue) -> [String: Any] {
            var d: [String: Any] = ["code": issue.code.rawValue]
            if let chunk { d["chunk"] = chunk }
            if let track = issue.track { d["track"] = track }
            if let count = issue.count { d["count"] = count }
            if let detail = issue.detail { d["detail"] = detail }
            return d
        }
        return chunks.flatMap { c in c.issues.map { dictionary(chunk: c.index, issue: $0) } }
            + sessionIssues.map { dictionary(chunk: $0.chunk, issue: $0.issue) }
    }

    // MARK: - Chunked Pipeline

    /// Ensures the cached transcription engine + diarizer for `config` are ready — creating or
    /// rebuilding them as needed. This is the single source of truth for how the chunked pipeline
    /// picks its engine/diarizer from `config` (mirrors what `setupChunkedPipeline` used to do
    /// inline); crash recovery (`ChunkedSessionRecovery`) calls this too, so a recovered session is
    /// transcribed with the exact same engine construction as a live recording — never a second,
    /// diverging init path (#135).
    public func prepareEngine(config: Config) throws -> (transcriber: any TranscriptionEngine, diarizer: (any DiarizationProvider)?) {
        let engineID = config.engine
        if transcriber == nil || lastEngineID != engineID {
            Logger.transcription.info("Creating engine: \(engineID.descriptor.displayName, privacy: .public)")
            transcriber = try createEngine(for: engineID, config: config)
            lastEngineID = engineID
        }
        applyDiarizerConfig(config)

        guard let transcriber else {
            throw RunnerError.failed("Failed to initialize transcription engine")
        }
        return (transcriber, diarizer)
    }

    /// Set up the chunked recording pipeline for a NEW session. `firstChunkIndex` is the index of
    /// the chunk being recorded now (0 for a fresh recording).
    public func setupChunkedPipeline(
        captureClient: any ChunkRotationClient,
        outputDirectory: URL,
        sessionBaseName: String,
        config: Config,
        firstChunkIndex: Int = 0
    ) throws {
        try setupPipeline(captureClient: captureClient, outputDirectory: outputDirectory, sessionBaseName: sessionBaseName,
                          config: config, seededState: nil, firstChunkIndex: firstChunkIndex)
    }

    /// Set up the chunked pipeline RESUMING a persisted session after a relaunch (L7): its chunks,
    /// id and `meetingStart` carry over so completed chunks are not re-done. `firstChunkIndex` is
    /// required here — the index the capture restarted at (the relaunch plan's) — because a resume
    /// that restarted at an index the session already holds lost every word after it. An index at
    /// or below the seeded maximum is clamped to max + 1 (logged `.error`).
    ///
    /// The rotator is still anchored at the CURRENT time — the monotonic clock behind it cannot be
    /// persisted, so a resume re-anchors at resume time rather than at the seeded `meetingStart`.
    public func setupChunkedPipeline(
        captureClient: any ChunkRotationClient,
        outputDirectory: URL,
        sessionBaseName: String,
        config: Config,
        seededState: SessionState,
        firstChunkIndex: Int
    ) throws {
        try setupPipeline(captureClient: captureClient, outputDirectory: outputDirectory, sessionBaseName: sessionBaseName,
                          config: config, seededState: seededState, firstChunkIndex: firstChunkIndex)
    }

    private func setupPipeline(
        captureClient: any ChunkRotationClient,
        outputDirectory: URL,
        sessionBaseName: String,
        config: Config,
        seededState: SessionState?,
        firstChunkIndex: Int
    ) throws {
        if failSetupForTesting { throw SetupFailure.forTesting }
        let (transcriber, diarizer) = try prepareEngine(config: config)

        let fresh = SessionState(
            sessionId: sessionBaseName,
            meetingStart: Date(),
            engine: config.engine.rawValue,
            chunkDurationMinutes: config.validatedChunkDuration,
            chunks: []
        )
        var sessionState = seededState ?? fresh
        // A seed from ANOTHER session is refused (C-I5): accepted, it kept the other id, so this
        // recording finalized as the other's `<id>.json`, merged into the other's `<id>.m4a` and
        // took the other meeting's chunks into its record. This session continues from its OWN state
        // when that is on disk (R2a M3: never an empty overwrite of it), else starts fresh; the
        // refusal is recorded as a problem. The seed's own file is untouched and stays recoverable
        // under its id. An engine change between crash and resume (a Settings change) is recorded as
        // information only, and still seeds.
        if let seededState, seededState.sessionId != sessionBaseName {
            let own = SessionState.read(directory: outputDirectory, sessionId: sessionBaseName)
            Logger.state.error(
                "Seeded session \(seededState.sessionId, privacy: .sensitive) does not match \(sessionBaseName, privacy: .sensitive) — not seeding; continuing from \(own == nil ? "a fresh state" : "this session's own state", privacy: .public)"
            )
            sessionState = own ?? fresh
            sessionState.issues.append(SessionIssue(chunk: nil, issue: ChunkIssue(code: .seedMismatch, track: nil, count: nil)))
        } else if let seededState, seededState.engine != config.engine.rawValue {
            Logger.state.info(
                "Seeded session was transcribed with \(seededState.engine, privacy: .public); resuming with \(config.engine.rawValue, privacy: .public)"
            )
            sessionState.issues.append(SessionIssue(chunk: nil, issue: ChunkIssue(code: .seedEngineChanged, track: nil, count: nil)))
        }

        var startIndex = firstChunkIndex
        if let seededMax = sessionState.chunks.map(\.index).max(), startIndex <= seededMax {
            Logger.state.error(
                "Resume asked to start at chunk \(firstChunkIndex, privacy: .public), but the session already holds chunk \(seededMax, privacy: .public) — starting at \(seededMax + 1, privacy: .public)"
            )
            startIndex = seededMax + 1
        }

        let processor = ChunkProcessor(
            config: config,
            outputDirectory: outputDirectory,
            sessionState: sessionState,
            transcriber: transcriber,
            diarizer: diarizer
        )
        self.chunkProcessor = processor

        let rotator = ChunkRotator(
            captureClient: captureClient,
            outputDirectory: outputDirectory.path,
            sessionBaseName: sessionBaseName,
            chunkDurationMinutes: config.validatedChunkDuration,
            startIndex: startIndex,
            startTime: Date()
        ) { [weak processor] chunk in
            processor?.processChunk(chunk)
        }
        self.chunkRotator = rotator
    }

    /// Record a period with no capture (relaunch, sleep) into the live session; returns once it is
    /// persisted to session.json (or its write failure is reported). `finalize` stamps it into the
    /// transcript.
    public func recordCaptureGap(_ gap: CaptureGap) async {
        guard let processor = chunkProcessor else {
            Logger.state.error("Capture gap (\(gap.reason, privacy: .public), \(gap.seconds, privacy: .public)s) not recorded: no chunk pipeline is running")
            return
        }
        await processor.appendGap(gap)
    }

    public func startChunkRotation() {
        chunkRotator?.start()
    }

    public func stopChunkRotation() {
        chunkRotator?.stop()
    }

    public func teardownChunkedPipeline() {
        chunkRotator = nil
        chunkProcessor = nil
    }

    public func disableDiarization() {
        self.diarizer = nil
        self.diarizerIsDefault = false
    }

    /// Rebuild the default diarizer from config so clustering tuning actually reaches FluidAudio.
    /// The diarizer is constructed at init, before any config exists, so this must run per-job.
    private func applyDiarizerConfig(_ config: Config) {
        guard diarizerIsDefault else { return }
        let wanted = (
            threshold: config.diarizationClusteringThreshold,
            maxSpeakers: config.diarizationMaxSpeakers,
            excludeOverlap: config.resolvedDiarizationExcludeOverlap
        )
        // Only rebuild when the settings actually changed — a fresh actor drops its cached
        // OfflineDiarizerManager, so an unconditional rebuild reloads the models every recording.
        if let current = diarizerSettings,
           current.threshold == wanted.threshold,
           current.maxSpeakers == wanted.maxSpeakers,
           current.excludeOverlap == wanted.excludeOverlap,
           diarizer != nil {
            return
        }
        diarizer = FluidAudioDiarizer(
            clusteringThreshold: wanted.threshold,
            maxSpeakers: wanted.maxSpeakers,
            excludeOverlap: wanted.excludeOverlap
        )
        diarizerSettings = wanted
    }

    /// Cumulative start offset for each segment in a multi-segment recovery/CLI run, given each
    /// segment's own physical duration in seconds. Segment 0 always starts at offset 0 (so a
    /// single-segment run is unaffected); segment k's offset is the sum of every prior segment's
    /// duration — turning each segment's file-relative timestamps into absolute ones once added
    /// to that segment's own `start`/`end` (#135 H2).
    public nonisolated static func segmentStartOffsets(durations: [Double]) -> [Double] {
        var acc = 0.0
        return durations.map { d in
            defer { acc += d }
            return acc
        }
    }

    /// Reconcile ONE channel's per-segment speaker databases (each segment diarized
    /// independently, so a raw label like "Speaker 1" in segment 0 and "Speaker 1" in segment 1
    /// are unrelated — they may be the same person or two different people) into a single global
    /// namespace, via `SpeakerReconciler`'s cosine-similarity matching (not a hand-rolled
    /// comparator — reuses the exact same greedy-match logic `finalize()` uses across chunks).
    ///
    /// `databases[i]` is segment `i`'s speaker database (friendly label → embedding). Each segment
    /// is wrapped in a throwaway `ProcessedChunk` (index = segment index) purely so
    /// `SpeakerReconciler.reconcile` — whose public API is chunk-shaped — can run its per-chunk
    /// greedy matching over them in recording order; no other `ProcessedChunk` field is read by
    /// the single-namespace (`isDualStream: false`) reconciliation path this uses.
    ///
    /// - Returns: `["<segmentIndex>:<localLabel>": "<globalLabel>"]` — namespaced by segment so
    ///   the same raw label reused across segments never collides in the output.
    public nonisolated static func reconcileRecoverySegments(
        databases: [[String: [Float]]],
        threshold: Double
    ) -> [String: String] {
        let stubChunks = databases.enumerated().map { index, db in
            ProcessedChunk(
                index: index,
                startTime: Date(timeIntervalSince1970: 0),
                audioPath: "",
                segments: [],
                speakerDatabase: db
            )
        }
        let perChunkMapping = SpeakerReconciler.reconcile(
            chunks: stubChunks,
            isDualStream: false,
            threshold: Float(threshold)
        )
        var flattened: [String: String] = [:]
        for (segmentIndex, mapping) in perChunkMapping {
            for (localLabel, globalLabel) in mapping {
                flattened["\(segmentIndex):\(localLabel)"] = globalLabel
            }
        }
        return flattened
    }

    // MARK: - Private

    static func discoverSegments(
        systemAudio: URL,
        micAudio: URL
    ) -> [(system: URL, mic: URL)] {
        TranscriberCore.discoverSegments(systemAudio: systemAudio, micAudio: micAudio)
    }

    private func createEngine(for id: EngineID, config: Config) throws -> any TranscriptionEngine {
        guard id.descriptor.isAvailableOnThisOS else {
            throw RunnerError.engineUnavailable(id.descriptor.displayName)
        }

        switch id {
        case .speechAnalyzer:
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                return SpeechAnalyzerEngine()
            }
            #endif
            throw RunnerError.engineUnavailable("SpeechAnalyzer requires macOS 26")

        case .fluidAudio:
            return FluidAudioEngine()
        }
    }

    private struct StreamResult {
        let segments: [LabeledSegment]
        let speakerDatabase: [String: [Float]]
    }

    private func transcribeStream(
        audioPath: URL,
        source: String,
        transcriber: any TranscriptionEngine,
        label: String,
        audioSource: AudioSourceType,
        config: Config
    ) async throws -> StreamResult {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioPath.path)[.size] as? Int) ?? 0
        if fileSize <= wavHeaderSize {
            Logger.transcription.info("Skipping empty \(label, privacy: .public) audio (\(fileSize) bytes)")
            return StreamResult(segments: [], speakerDatabase: [:])
        }

        Logger.transcription.info("Transcribing \(label, privacy: .public) audio: \(audioPath.lastPathComponent, privacy: .sensitive) (\(fileSize) bytes)")

        let rawSegments = try await transcriber.transcribe(audioPath: audioPath, language: nil, audioSource: audioSource)
        // This path has no chunk issues (the CLI `run()` semantics are a non-goal, §13): log the counts.
        let dedup = SpeakerAssignment.deduplicate(rawSegments)
        let segments = dedup.segments
        if !dedup.duplicates.isEmpty || dedup.zeroLength > 0 {
            Logger.transcription.info("\(label.capitalized, privacy: .public): flagged \(dedup.duplicates.count, privacy: .public) abutting repeat(s), dropped \(dedup.zeroLength, privacy: .public) zero-length segment(s)")
        }

        // Capture detected language from engine output
        if let lang = segments.lazy.compactMap(\.language).first {
            detectedLanguages.append(lang)
        }

        var labeled: [LabeledSegment]
        var speakerDatabase: [String: [Float]] = [:]
        if let diarizer = diarizer {
            // Run VAD concurrently with diarization (both read the same audio file)
            async let diarizedResult = diarizer.diarize(audioPath: audioPath, numSpeakers: nil)
            async let speechMapResult = vadSpeechMap.analyze(audioPath: audioPath)

            let diarizationResult = try await diarizedResult
            // analyze() returns [SpeechRegion]? — flatten the try? double-optional
            let speechMap: [SpeechRegion]? = (try? await speechMapResult) ?? nil

            let result = StreamLabeling.withDiarization(
                segments: segments,
                diarizationResult: diarizationResult,
                speechMap: speechMap,
                vadSpeechThreshold: config.vadSpeechThreshold ?? 0.5,
                minSpeakerShare: config.resolvedDiarizationMinSpeakerShare
            )
            labeled = result.labeled
            speakerDatabase = result.speakerDatabase
        } else {
            labeled = StreamLabeling.singleSpeaker(segments, speaker: "Speaker 1")
        }
        labeled = SpeakerAssignment.reattachDuplicates(dedup.duplicates, to: labeled)

        for i in labeled.indices {
            labeled[i].source = source
        }

        Logger.transcription.info("\(label.capitalized, privacy: .public) transcription: \(labeled.count) segments")
        return StreamResult(segments: labeled, speakerDatabase: speakerDatabase)
    }
}
