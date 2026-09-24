import Foundation
import AVFoundation
import os

/// Processes finalized chunks in the background: transcribe both streams,
/// diarize, VAD, speaker assignment, archive to AAC, and persist to session.json.
///
/// The class is `@MainActor` so the `inFlightTasks` bookkeeping is serialized without a lock (#52).
/// The heavy per-chunk work (`processChunkAsync` / `transcribeStream`) is `nonisolated` so the ML
/// transcription, diarization, VAD and AAC encoding run off the main actor — only enqueueing and
/// awaiting tasks touches the main actor. Immutable dependencies are `nonisolated let` so the
/// off-actor work can read them without hopping back to the main actor.
@MainActor
public final class ChunkProcessor {
    private nonisolated let config: Config
    private nonisolated let outputDirectory: URL
    private nonisolated let transcriber: any TranscriptionEngine
    private nonisolated let diarizer: (any DiarizationProvider)?
    private nonisolated let vadSpeechMap = VadSpeechMap()
    private nonisolated let stateStore: StateStore
    private nonisolated let wavHeaderSize = 44
    private nonisolated let taskPriority: TaskPriority
    private var inFlightTasks: [Task<Void, Never>] = []
    /// Every chunk index this processor has accepted. An index is claimed once and never released:
    /// the orphan re-ingested by crash recovery and the same index arriving again from the rotator
    /// must not produce two chunks (L6/L7, scan B P3.2). A lock, not main-actor state, because
    /// `processLastChunk` is `nonisolated`.
    private nonisolated let claimedIndices = OSAllocatedUnfairLock<Set<Int>>(initialState: [])

    /// Called on the main actor with the chunk index when session.json could not be written after
    /// that chunk — the coordinator raises `sessionWriteFailed` (L10). The failure is also recorded
    /// in `SessionState.issues`, so the next successful write persists it.
    public var onSessionWriteFailure: ((Int) -> Void)?

    /// Actor-isolated mutable session state — replaces NSLock.
    private actor StateStore {
        var sessionState: SessionState

        init(sessionState: SessionState) {
            self.sessionState = sessionState
        }

        func appendChunk(_ chunk: ProcessedChunk) -> SessionState {
            sessionState.chunks.append(chunk)
            return sessionState
        }

        func noteSessionWriteFailure(chunkIndex: Int) -> SessionState {
            sessionState.issues.append(SessionIssue(
                chunk: chunkIndex, issue: ChunkIssue(code: .sessionWriteFailed, track: nil, count: nil)
            ))
            return sessionState
        }

        func appendGap(_ gap: CaptureGap) -> SessionState {
            sessionState.gaps.append(gap)
            return sessionState
        }

        func getSessionState() -> SessionState {
            sessionState
        }
    }

    public init(
        config: Config,
        outputDirectory: URL,
        sessionState: SessionState,
        transcriber: any TranscriptionEngine,
        diarizer: (any DiarizationProvider)?
    ) {
        self.config = config
        self.outputDirectory = outputDirectory
        self.stateStore = StateStore(sessionState: sessionState)
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.taskPriority = switch config.resolvedQos {
        case .userInteractive: .high
        case .userInitiated: .medium
        case .background: .background
        default: .utility
        }
    }

    /// Process a finalized chunk in the background (non-blocking).
    public func processChunk(_ chunk: ChunkRotator.FinalizedChunk) {
        guard claim(chunk.index) else { return }
        let priority = taskPriority
        let task = Task(priority: priority) {
            await self.processChunkAsync(chunk)
        }
        inFlightTasks.append(task)
    }

    /// Process a chunk synchronously (inline `await`, no `inFlightTasks` enqueue). Called once at
    /// end-of-recording for the final chunk, and once per orphan chunk during crash recovery
    /// (`ChunkedSessionRecovery`, which awaits each orphan in turn rather than firing them
    /// concurrently). `nonisolated` so the heavy work (ASR, diarization, AAC encoding) runs off the
    /// main actor even when awaited from `@MainActor`.
    public nonisolated func processLastChunk(_ chunk: ChunkRotator.FinalizedChunk) async {
        guard claim(chunk.index) else { return }
        await processChunkAsync(chunk)
    }

    /// Claim a chunk index for processing; false (logged) when it was already claimed.
    private nonisolated func claim(_ index: Int) -> Bool {
        let claimed = claimedIndices.withLock { $0.insert(index).inserted }
        if !claimed {
            Logger.transcription.info("Chunk \(index, privacy: .public) already processed or in flight — skipping the duplicate")
        }
        return claimed
    }

    /// Wait for all background chunk processing to complete before merging.
    public func awaitAllProcessed() async {
        for task in inFlightTasks {
            await task.value
        }
        inFlightTasks.removeAll()
    }

    /// Actor-isolated access to current session state.
    public func getSessionState() async -> SessionState {
        await stateStore.getSessionState()
    }

    /// A period during which nothing was recorded (relaunch, sleep). Persisted with the session so a
    /// later relaunch and the final transcript both see it (§7.2 metadata.capture.gaps).
    public nonisolated func appendGap(_ gap: CaptureGap) async {
        let snapshot = await stateStore.appendGap(gap)
        do { try SessionState.write(snapshot, directory: outputDirectory) }
        catch { Logger.state.error("Failed to write session.json after a capture gap: \(error, privacy: .public)") }
    }

    // MARK: - Private

    private nonisolated func processChunkAsync(_ chunk: ChunkRotator.FinalizedChunk) async {
        // A seeded session (relaunch, L7) already holds its settled chunks: never re-do one.
        if await stateStore.getSessionState().chunks.contains(where: { $0.index == chunk.index }) {
            Logger.transcription.info("Chunk \(chunk.index, privacy: .public) is already in the session — skipping the duplicate")
            return
        }
        let startTime = ContinuousClock.now
        Logger.transcription.info(
            "Chunk \(chunk.index, privacy: .public) processing started (qos: \(self.config.chunkProcessingQos, privacy: .public))"
        )

        // 1. Transcribe + diarize system audio
        let systemURL = URL(fileURLWithPath: chunk.systemPath)
        let systemResult = await transcribeStream(
            audioPath: systemURL, source: "remote", audioSource: .system, label: "chunk-\(chunk.index)-system"
        )

        // 2. Transcribe mic audio (skip if file missing or empty)
        let micURL = URL(fileURLWithPath: chunk.micPath)
        // Dual-stream is a property of the CAPTURE, not of whether the user spoke. Deriving it from
        // `!micResult.segments.isEmpty` meant a chunk the user sat through in silence skipped source
        // prefixing while its siblings kept it — so the reconciler's `Remote Speaker N` keys matched
        // nothing there, its mapping fell back to the identity, and its chunk-local numbering was
        // laundered into the global namespace, swapping speakers for the rest of the meeting.
        let hasDualStream = FileManager.default.fileExists(atPath: chunk.micPath)
        let micResult: StreamResult
        if hasDualStream {
            micResult = await transcribeStream(
                audioPath: micURL, source: "local", audioSource: .microphone, label: "chunk-\(chunk.index)-mic"
            )
        } else {
            micResult = StreamResult(segments: [], speakerDatabase: [:])
        }
        var issues = systemResult.issues + micResult.issues

        // 3. Merge segments
        var allSegments = systemResult.segments + micResult.segments
        if hasDualStream && !allSegments.isEmpty {
            // Resolve within-source Unknowns to the single speaker of that channel BEFORE prefixing,
            // so a 1-party call / your own mic doesn't fragment into `Remote Speaker 1` + `Unknown` (#71).
            // The diarizer's per-channel speaker count (speakerDatabase.count) gates the collapse.
            SpeakerAssignment.resolveUnknownsWithinSource(&allSegments, sourceSpeakerCounts: [
                "local": micResult.speakerDatabase.count,
                "remote": systemResult.speakerDatabase.count,
            ])
            SpeakerAssignment.tagWithSourcePrefix(&allSegments)
        }
        allSegments.sort { $0.start < $1.start }

        // 3b. Remove echo segments (mic bleed of remote speaker)
        var echoRemoved = 0
        if hasDualStream {
            let dedupResult = EchoDeduplicator.deduplicate(
                segments: allSegments,
                localSpeakerDatabase: micResult.speakerDatabase,
                remoteSpeakerDatabase: systemResult.speakerDatabase,
                temporalThreshold: config.echoTemporalThreshold,
                textThreshold: config.echoTextThreshold,
                embeddingThreshold: config.echoEmbeddingThreshold
            )
            allSegments = dedupResult.segments
            echoRemoved = dedupResult.flaggedCount
            if echoRemoved > 0 {
                issues.append(ChunkIssue(code: .echoFlagged, track: "local", count: echoRemoved))
            }
        }

        // 4. Convert to ProcessedChunk.Segment
        let chunkSegments = allSegments.map { seg in
            ProcessedChunk.Segment(
                start: seg.start,
                end: seg.end,
                text: seg.text,
                speaker: seg.speaker,
                source: seg.source,
                qualityScore: seg.confidence,
                filtered: seg.filtered,
                echo: seg.echo
            )
        }

        // 5. Speaker databases from both streams (used for cross-chunk reconciliation, #64)
        let speakerDatabase = systemResult.speakerDatabase
        // Local stream: only present when diarization ran on the mic stream.
        let localSpeakerDatabase = hasDualStream ? micResult.speakerDatabase : [:]

        // 6. Archive WAV(s) → AAC (store filename only for session.json portability).
        //
        // WAV is only a transient crash-resiliency format: every chunk must flush to .m4a in the
        // success path so no lossless WAV is left behind wasting space — regardless of stream count
        // or chunk count (#59). The mic WAV is archived whenever it exists on disk (not gated on
        // hasDualStream, which is segment-based) so a mic file that produced no segments is still
        // consumed instead of orphaned. The ONLY time a WAV survives is a genuine archive failure:
        // deleting a WAV that has no .m4a replacement would be real data loss.
        var audioPath = systemURL.lastPathComponent
        let micFileExists = FileManager.default.fileExists(atPath: chunk.micPath)
        // An ASR-failed chunk keeps its WAV(s) next to the .m4a so it can be re-transcribed (P3):
        // the AAC is lossy, and the words it failed to yield exist nowhere else.
        let preserveSourceWAV = (config.preserveSourceWAV ?? false) || issues.contains { $0.code == .asrFailed }
        var archivePath: URL?
        do {
            let archiveResult: AudioArchiveResult
            if micFileExists {
                archiveResult = try await AudioArchiver.archive(
                    systemAudio: systemURL,
                    micAudio: micURL,
                    outputDirectory: outputDirectory,
                    bitrateKbps: config.archiveBitrateKbps,
                    preserveSourceWAV: preserveSourceWAV
                )
            } else {
                archiveResult = try await AudioArchiver.archiveSystemOnly(
                    systemAudio: systemURL,
                    outputDirectory: outputDirectory,
                    bitrateKbps: config.archiveBitrateKbps,
                    preserveSourceWAV: preserveSourceWAV
                )
            }
            audioPath = archiveResult.archivePath.lastPathComponent
            archivePath = archiveResult.archivePath
            Logger.files.info("Chunk \(chunk.index, privacy: .public) archived: \(archiveResult.archivePath.lastPathComponent, privacy: .sensitive)")
        } catch {
            // Archive failed — keep the WAV(s) as a last-resort fallback. Record whichever one
            // actually holds audio: on a speakerphone recording the system WAV is an empty header
            // and the mic WAV holds every word, and pointing the transcript at the empty one left
            // the real audio referenced nowhere (#183).
            audioPath = AudioArchiver.fallbackAudioName(
                systemName: systemURL.lastPathComponent,
                systemHasFrames: Self.hasAudioFrames(systemURL),
                micName: micFileExists ? micURL.lastPathComponent : nil,
                micHasFrames: micFileExists && Self.hasAudioFrames(micURL)
            )
            Logger.files.error("Chunk \(chunk.index, privacy: .public) archival failed, keeping WAV(s) — transcript will reference \(audioPath, privacy: .sensitive): \(error, privacy: .public)")
            issues.append(ChunkIssue(code: .archiveFailed, track: nil, count: nil))
        }

        // Enforce the storage quota (P13). Outside the archive `catch`: a quota failure used to land
        // there and relabel an archived chunk as "archival failed", pointing the transcript at WAVs
        // that were already deleted. No archive, no quota pass. Scope stays the day folder (#224).
        if let archivePath {
            do {
                try StorageManager.enforceQuota(
                    in: outputDirectory,
                    limitHours: config.audioArchiveLimitHours,
                    bitrateKbps: config.archiveBitrateKbps,
                    protectedFile: archivePath
                )
            } catch {
                Logger.files.error("Chunk \(chunk.index, privacy: .public) quota enforcement failed: \(error, privacy: .public)")
            }
        }

        // 7. Create ProcessedChunk
        let processed = ProcessedChunk(
            index: chunk.index,
            startTime: chunk.startTime,
            audioPath: audioPath,
            segments: chunkSegments,
            speakerDatabase: speakerDatabase,
            localSpeakerDatabase: localSpeakerDatabase,
            echoSegmentsRemoved: echoRemoved,
            isDualStream: hasDualStream,
            issues: issues
        )

        // 8. Actor-isolated append + persist
        let snapshot = await stateStore.appendChunk(processed)

        do {
            try SessionState.write(snapshot, directory: outputDirectory)
        } catch {
            Logger.state.error("Failed to write session.json for chunk \(chunk.index, privacy: .public): \(error, privacy: .public)")
            // Recorded in memory so the next successful write persists it, and reported so the
            // coordinator can tell the user now — a session that cannot be saved is not recoverable.
            _ = await stateStore.noteSessionWriteFailure(chunkIndex: chunk.index)
            await MainActor.run { self.onSessionWriteFailure?(chunk.index) }
        }

        let elapsed = ContinuousClock.now - startTime
        Logger.transcription.info(
            "Chunk \(chunk.index, privacy: .public) processing complete — \(elapsed.components.seconds, privacy: .public)s, \(chunkSegments.count, privacy: .public) segments"
        )
    }

    /// Result from transcribing a single stream, including speaker database if diarized.
    private struct StreamResult {
        let segments: [LabeledSegment]
        let speakerDatabase: [String: [Float]]
        var issues: [ChunkIssue] = []
    }

    /// Whether a WAV holds any audio at all. A capture that opened a file and never wrote a frame
    /// leaves a valid header with zero frames — readable, nominally 16 kHz, and completely empty.
    private nonisolated static func hasAudioFrames(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0
    }

    /// Transcribe a single audio stream, with optional diarization + VAD.
    private nonisolated func transcribeStream(
        audioPath: URL,
        source: String,
        audioSource: AudioSourceType,
        label: String
    ) async -> StreamResult {
        // Recover crash-orphaned WAVs: a writer killed before finalize() leaves a
        // header that underreports the payload, so the file reads as empty/short.
        // Rebuild the size fields from the real length before reading the audio.
        WavFileWriter.repairHeader(path: audioPath.path)

        // Skip empty files (WAV header only)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioPath.path)[.size] as? Int) ?? 0
        if fileSize <= wavHeaderSize {
            Logger.transcription.info("Skipping empty \(label, privacy: .public) audio (\(fileSize) bytes)")
            return StreamResult(segments: [], speakerDatabase: [:],
                                issues: [ChunkIssue(code: .streamEmpty, track: source, count: nil)])
        }

        Logger.transcription.info("Transcribing \(label, privacy: .public): \(audioPath.lastPathComponent, privacy: .sensitive) (\(fileSize) bytes)")

        var segments: [TranscriptSegment]
        do {
            segments = try await transcriber.transcribe(audioPath: audioPath, language: nil, audioSource: audioSource)
        } catch {
            Logger.transcription.error("Transcription failed for \(label, privacy: .public): \(error, privacy: .public)")
            return StreamResult(segments: [], speakerDatabase: [:],
                                issues: [ChunkIssue(code: .asrFailed, track: source, count: nil)])
        }

        var issues: [ChunkIssue] = []
        let dedup = SpeakerAssignment.deduplicate(segments)
        segments = dedup.segments
        if dedup.dropped > 0 {
            issues.append(ChunkIssue(code: .duplicatesDropped, track: source, count: dedup.dropped))
        }
        var labeled: [LabeledSegment]
        var speakerDatabase: [String: [Float]] = [:]
        if let diarizer {
            do {
                // Run diarization + VAD concurrently
                async let diarizedResult = diarizer.diarize(audioPath: audioPath, numSpeakers: nil)
                async let speechMapResult = vadSpeechMap.analyze(audioPath: audioPath)

                let diarizationResult = try await diarizedResult
                let speechMap: [SpeechRegion]? = (try? await speechMapResult) ?? nil
                if speechMap == nil {
                    // No VAD (model not cached, or it threw): the quality gate ran without a speech map.
                    issues.append(ChunkIssue(code: .vadUnavailable, track: source, count: nil))
                }

                let result = StreamLabeling.withDiarization(
                    segments: segments,
                    diarizationResult: diarizationResult,
                    speechMap: speechMap,
                    vadSpeechThreshold: config.vadSpeechThreshold ?? 0.5,
                    minSpeakerShare: config.resolvedDiarizationMinSpeakerShare
                )
                labeled = result.labeled
                speakerDatabase = result.speakerDatabase
                let filteredCount = labeled.filter(\.filtered).count
                if filteredCount > 0 {
                    issues.append(ChunkIssue(code: .segmentsFiltered, track: source, count: filteredCount))
                }
                if result.absorbed > 0 {
                    issues.append(ChunkIssue(code: .clustersAbsorbed, track: source, count: result.absorbed))
                }
            } catch {
                Logger.transcription.error("Diarization failed for \(label, privacy: .public): \(error, privacy: .public)")
                issues.append(ChunkIssue(code: .diarizationFailed, track: source, count: nil))
                // Label "Unknown", never "Speaker 1". Asserting a specific identity we do not have
                // is worse than admitting we don't know: with an empty speakerDatabase the
                // reconciler skips this chunk entirely, so a fabricated "Speaker 1" fuses with the
                // seed chunk's real Speaker 1 and every voice in this chunk is attributed to that
                // person. "Unknown" is already handled downstream by tagWithSourcePrefix.
                labeled = StreamLabeling.singleSpeaker(segments, speaker: SpeakerAssignment.unknownSpeaker)
            }
        } else {
            labeled = StreamLabeling.singleSpeaker(segments, speaker: "Speaker 1")
        }

        for i in labeled.indices {
            labeled[i].source = source
        }

        Logger.transcription.info("\(label.capitalized, privacy: .public) transcription: \(labeled.count) segments")
        return StreamResult(segments: labeled, speakerDatabase: speakerDatabase, issues: issues)
    }
}
