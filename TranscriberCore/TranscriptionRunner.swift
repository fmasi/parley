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
    /// False once a caller injects its own provider (tests, disableDiarization), so config
    /// changes never clobber an explicitly-set diarizer.
    private var diarizerIsDefault = true
    /// The settings the current default diarizer was built with. Rebuilding it on every job would
    /// discard the actor's cached OfflineDiarizerManager and reload the ML models each recording.
    private var diarizerSettings: (threshold: Double?, maxSpeakers: Int?, excludeOverlap: Bool)?
    private let vadSpeechMap = VadSpeechMap()

    public private(set) var chunkRotator: ChunkRotator?
    public private(set) var chunkProcessor: ChunkProcessor?

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
                if FileManager.default.fileExists(atPath: micPath.path) {
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
            if let physical = SpeakerSampleLocator.durations(of: [pair.system]).first.flatMap({ $0 }) {
                return physical
            }
            Logger.transcription.warning("Recovery segment: could not read physical WAV duration for \(pair.system.lastPathComponent, privacy: .private); falling back to transcript end (then configured chunk length) for the offset of the next segment")
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
            echoRemoved = dedupResult.removedCount
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
            Logger.files.error("Failed to write format file: \(error, privacy: .public)")
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
                    protectedFile: archived.last
                )
            } catch {
                Logger.files.error("Quota enforcement failed: \(error, privacy: .public)")
            }
        }

        let elapsed = ContinuousClock.now - startTime
        Logger.transcription.info("Transcription pipeline complete — \(elapsed.components.seconds)s, output: \(jsonPath.lastPathComponent, privacy: .private)")

        return TranscriptionResult(jsonPath: jsonPath)
    }

    /// Finalize a chunked recording session: reconcile speakers, merge chunks, write transcript.
    public func finalize(
        sessionState: SessionState,
        outputDirectory: URL,
        config: Config
    ) async throws -> TranscriptionResult {
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
                "Speaker remap MISS in chunk \(chunkIndex, privacy: .public): labels \(labels.joined(separator: ", "), privacy: .public) are not in the reconciler's mapping. Speaker identity for this chunk may be wrong."
            )
        }

        var allSegments: [LabeledSegment] = mergeResult.segments.map { seg in
            LabeledSegment(
                start: seg.elapsed,
                end: seg.elapsedEnd,
                speaker: seg.speaker,
                text: seg.text,
                source: seg.source,
                confidence: seg.qualityScore
            )
        }

        allSegments.sort { $0.start < $1.start }

        // 4. Dual-stream tagging
        let isDualStream = allSegments.contains { $0.source == "local" }
        if isDualStream {
            SpeakerAssignment.tagWithSourcePrefix(&allSegments)
        }

        // 5. Audio paths from chunks — must be in index order so AudioConcatenator
        // stitches them chronologically. (#56)
        let chunkAudioPaths = sortedChunks.map {
            outputDirectory.appendingPathComponent($0.audioPath)
        }

        // 5b. Concatenate chunk audio files into a single archive (if enabled and more than 1 chunk)
        let audioPaths: [URL]
        if config.mergeChunkedAudio && chunkAudioPaths.count > 1 {
            do {
                let concatResult = try await AudioConcatenator.concatenate(
                    sources: chunkAudioPaths,
                    outputDirectory: outputDirectory,
                    outputName: sessionState.sessionId
                )
                audioPaths = [concatResult.outputPath]
                Logger.files.info(
                    "Concatenated \(chunkAudioPaths.count, privacy: .public) chunks → \(concatResult.outputPath.lastPathComponent, privacy: .private) (passthrough: \(concatResult.usedPassthrough, privacy: .public))"
                )
            } catch {
                // concatenate() only deletes sources after a verified successful export,
                // so on throw the chunk files are still intact.
                Logger.files.error("Audio concatenation failed (\(type(of: error), privacy: .public)), keeping separate files: \(error, privacy: .public)")
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

        // 7. Assemble JSON
        let totalEchoRemoved = sessionState.chunks.reduce(0) { $0 + $1.echoSegmentsRemoved }
        let json = TranscriptAssembler.assemble(
            segments: allSegments,
            audioPaths: audioPaths,
            outputFormat: config.outputFormat,
            language: detectedLanguage,
            numSpeakers: nil,
            diarization: true,
            dualStream: isDualStream,
            echoSegmentsRemoved: totalEchoRemoved,
            provenance: sessionState.provenance,
            // The wall-clock time the meeting actually began (#49).
            recordedAt: sessionState.meetingStart
        )

        let baseName = sessionState.sessionId
        let jsonPath = outputDirectory.appendingPathComponent(baseName + ".json")
        try TranscriptAssembler.write(json, to: jsonPath)

        // 8. Write format file
        do {
            try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)
        } catch {
            Logger.files.error("Failed to write format file: \(error, privacy: .public)")
        }

        // 9. Storage quota enforcement
        do {
            try StorageManager.enforceQuota(
                in: outputDirectory,
                limitHours: config.audioArchiveLimitHours,
                bitrateKbps: config.archiveBitrateKbps,
                protectedFile: audioPaths.last
            )
        } catch {
            Logger.files.error("Quota enforcement failed: \(error, privacy: .public)")
        }

        // 10. Clean up session.json
        SessionState.delete(directory: outputDirectory)

        let elapsed = ContinuousClock.now - startTime
        Logger.transcription.info("Chunked pipeline finalized — \(elapsed.components.seconds)s, \(mergeResult.chunkCount) chunks, output: \(jsonPath.lastPathComponent, privacy: .private)")

        return TranscriptionResult(jsonPath: jsonPath)
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

    /// Set up chunked recording pipeline.
    public func setupChunkedPipeline(
        captureClient: any ChunkRotationClient,
        outputDirectory: URL,
        sessionBaseName: String,
        config: Config
    ) throws {
        let (transcriber, diarizer) = try prepareEngine(config: config)

        let sessionState = SessionState(
            sessionId: sessionBaseName,
            meetingStart: Date(),
            engine: config.engine.rawValue,
            chunkDurationMinutes: config.validatedChunkDuration,
            chunks: []
        )

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
            startTime: Date()
        ) { [weak processor] chunk in
            processor?.processChunk(chunk)
        }
        self.chunkRotator = rotator
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

    public func setDiarizer(_ provider: any DiarizationProvider) {
        self.diarizer = provider
        self.diarizerIsDefault = false
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

        Logger.transcription.info("Transcribing \(label, privacy: .public) audio: \(audioPath.lastPathComponent, privacy: .private) (\(fileSize) bytes)")

        let segments = try await transcriber.transcribe(audioPath: audioPath, language: nil, audioSource: audioSource)

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
            let diarizedSegments = diarizationResult.segments
            // analyze() returns [SpeechRegion]? — flatten the try? double-optional
            let speechMap: [SpeechRegion]? = (try? await speechMapResult) ?? nil

            labeled = SpeakerAssignment.assign(
                transcriptSegments: segments,
                diarizationSegments: diarizedSegments,
                speechMap: speechMap,
                vadSpeechThreshold: config.vadSpeechThreshold ?? 0.5
            )
            // Remap DB keys from raw IDs ("S2") to friendly names ("Speaker 1")
            let dbKeyMap = SpeakerAssignment.buildSpeakerMap(from: diarizedSegments)
            speakerDatabase = SpeakerAssignment.remapDatabaseKeys(
                diarizationResult.speakerDatabase, using: dbKeyMap
            )
        } else {
            labeled = segments.map { seg in
                LabeledSegment(
                    start: seg.start,
                    end: seg.end,
                    speaker: "Speaker 1",
                    text: seg.text.trimmingCharacters(in: .whitespaces),
                    source: "",
                    confidence: seg.confidence,
                    language: seg.language
                )
            }
        }

        for i in labeled.indices {
            labeled[i].source = source
        }

        Logger.transcription.info("\(label.capitalized, privacy: .public) transcription: \(labeled.count) segments")
        return StreamResult(segments: labeled, speakerDatabase: speakerDatabase)
    }
}
