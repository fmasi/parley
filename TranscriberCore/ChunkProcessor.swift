import Foundation
import AVFoundation
import os

/// Processes finalized chunks in the background: transcribe both streams,
/// diarize, VAD, speaker assignment, archive to AAC, and persist to session.json.
///
/// The class is `@MainActor` so the per-chunk bookkeeping (`sourceByIndex`, `tasksByIndex`) is
/// serialized without a lock (#52).
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
    /// The recording file (base name, e.g. `meeting-0`) behind every chunk index this processor
    /// knows: the seeded session's settled chunks plus every chunk scheduled here. An index is never
    /// released. The same index from the SAME file again is a true duplicate (the orphan re-ingested
    /// by crash recovery, or the rotator repeating itself) and is skipped; the same index from a
    /// DIFFERENT file is a collision, and that audio is processed under a fresh index (L6/L7).
    private var sourceByIndex: [Int: String]
    /// The task processing each chunk scheduled here, so a duplicate can await the original and
    /// `awaitAllProcessed` covers every chunk, the last one included.
    private var tasksByIndex: [Int: Task<Void, Never>] = [:]
    /// Bookkeeping tasks (a duplicate's issue being recorded) that `awaitAllProcessed` also awaits.
    private var bookkeepingTasks: [Task<Void, Never>] = []

    /// Called on the main actor when session.json could not be written: with the chunk index after
    /// a chunk, nil after a session-level change (a capture gap). The coordinator raises
    /// `sessionWriteFailed` (L10). The failure is also recorded in `SessionState.issues`, so the
    /// next successful write persists it.
    public var onSessionWriteFailure: ((_ chunkIndex: Int?) -> Void)?
    /// Called on the main actor after every successful session.json write (chunk or gap), the mirror
    /// of `onSessionWriteFailure`: the coordinator clears its sticky `sessionWriteFailed` alarm.
    public var onSessionWriteSucceeded: (() -> Void)?

    /// Actor-isolated mutable session state — replaces NSLock. It also owns every session.json
    /// write, so writes are serialized: a snapshot taken before another chunk's append can never be
    /// renamed over the newer one (B-M11).
    private actor StateStore {
        var sessionState: SessionState
        let directory: URL
        private var failWritesForTesting = false

        init(sessionState: SessionState, directory: URL) {
            self.sessionState = sessionState
            self.directory = directory
        }

        func appendChunk(_ chunk: ProcessedChunk) {
            sessionState.chunks.append(chunk)
        }

        func noteIssue(_ issue: SessionIssue) {
            sessionState.issues.append(issue)
        }

        func noteSessionWriteFailure(chunkIndex: Int?) {
            sessionState.issues.append(SessionIssue(
                chunk: chunkIndex, issue: ChunkIssue(code: .sessionWriteFailed, track: nil, count: nil)
            ))
        }

        func appendGap(_ gap: CaptureGap) {
            sessionState.gaps.append(gap)
        }

        func getSessionState() -> SessionState {
            sessionState
        }

        /// Write the current state. When the folder's session.json belonged to another recording,
        /// it was moved aside (never overwritten); that is recorded here and written with the state.
        func persist() throws {
            if failWritesForTesting { throw CocoaError(.fileWriteUnknown) }
            if try SessionState.write(sessionState, directory: directory) != nil {
                sessionState.issues.append(SessionIssue(
                    chunk: nil, issue: ChunkIssue(code: .sessionFileDisplaced, track: nil, count: nil)
                ))
                try SessionState.write(sessionState, directory: directory)
            }
        }

        func setFailWritesForTesting() { failWritesForTesting = true }
    }

    /// Test seam: every later session.json write fails.
    func failSessionWritesForTesting() async {
        await stateStore.setFailWritesForTesting()
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
        self.stateStore = StateStore(sessionState: sessionState, directory: outputDirectory)
        self.sourceByIndex = Dictionary(
            sessionState.chunks.map { ($0.index, Self.sourceBaseName(ofFile: $0.audioPath)) },
            uniquingKeysWith: { first, _ in first }
        )
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
        schedule(chunk, priority: taskPriority)
    }

    /// Process a chunk and return when it is done. Called once at end-of-recording for the final
    /// chunk, and once per orphan chunk during crash recovery (`ChunkedSessionRecovery`, which
    /// awaits each orphan in turn rather than firing them concurrently). The heavy work (ASR,
    /// diarization, AAC encoding) runs off the main actor. A duplicate of a chunk still being
    /// processed waits for the original instead of returning early.
    public nonisolated func processLastChunk(_ chunk: ChunkRotator.FinalizedChunk) async {
        let priority = Task.currentPriority
        let task = await schedule(chunk, priority: priority)
        await task?.value
    }

    /// Wait for all chunk processing to complete before merging — including any chunk scheduled
    /// while waiting (a rotation reply that lands late): the task set is re-read until it stops
    /// growing (B-I3). Tasks are never removed, so the count tells whether any were added.
    public func awaitAllProcessed() async {
        var awaited = 0
        while tasksByIndex.count + bookkeepingTasks.count > awaited {
            awaited = tasksByIndex.count + bookkeepingTasks.count
            for task in Array(tasksByIndex.values) + bookkeepingTasks {
                await task.value
            }
        }
    }

    /// Start processing `chunk`, or return the task already processing it. nil for a duplicate of a
    /// chunk that was settled before this processor existed (seeded) — nothing to wait for.
    @discardableResult
    private func schedule(_ chunk: ChunkRotator.FinalizedChunk, priority: TaskPriority) -> Task<Void, Never>? {
        let source = Self.sourceBaseName(ofFile: URL(fileURLWithPath: chunk.systemPath).lastPathComponent)
        var chunk = chunk
        var extraIssues: [ChunkIssue] = []
        // The same file again — under its own index, or under another one (a collided chunk that was
        // re-indexed, then re-ingested by a relaunch orphan scan) — is a duplicate.
        if let knownIndex = sourceByIndex.first(where: { $0.value == source })?.key {
            guard knownIndex != chunk.index else {
                Logger.transcription.info("Chunk \(chunk.index, privacy: .public) already processed or in flight — skipping the duplicate")
                return tasksByIndex[knownIndex]
            }
            // The same file under ANOTHER index means something upstream re-named it: skipped (the
            // audio is already in), but never quietly — logged and recorded on the session.
            Logger.transcription.error(
                "Chunk \(chunk.index, privacy: .public) is \(source, privacy: .private), already processed or in flight as chunk \(knownIndex, privacy: .public) — skipping the duplicate"
            )
            let issue = SessionIssue(chunk: knownIndex, issue: ChunkIssue(code: .duplicateSourceOtherIndex, track: nil, count: chunk.index))
            let original = tasksByIndex[knownIndex]
            let store = stateStore
            let noted = Task {
                await store.noteIssue(issue)
                await original?.value
            }
            bookkeepingTasks.append(noted)
            return noted
        }
        if let known = sourceByIndex[chunk.index] {
            // Never skip audio because its index is taken: that silently dropped every word
            // recorded after a resume. Process it under a fresh index and say so.
            let fresh = (sourceByIndex.keys.max() ?? chunk.index) + 1
            Logger.transcription.error(
                "Chunk index \(chunk.index, privacy: .public) is already held by \(known, privacy: .private); \(source, privacy: .private) is a different recording file — processing it as chunk \(fresh, privacy: .public)"
            )
            extraIssues.append(ChunkIssue(code: .chunkIndexCollision, track: nil, count: chunk.index))
            chunk = ChunkRotator.FinalizedChunk(
                index: fresh, systemPath: chunk.systemPath, micPath: chunk.micPath, startTime: chunk.startTime
            )
        }
        sourceByIndex[chunk.index] = source
        let scheduled = chunk
        let issues = extraIssues
        let task = Task(priority: priority) {
            await self.processChunkAsync(scheduled, extraIssues: issues)
        }
        tasksByIndex[chunk.index] = task
        return task
    }

    /// The recording file a chunk came from, as its base name: `meeting-0.wav`, `meeting-0.m4a` and
    /// `meeting-0_mic.wav` are all `meeting-0`.
    nonisolated static func sourceBaseName(ofFile name: String) -> String {
        var base = (URL(fileURLWithPath: name).lastPathComponent as NSString).deletingPathExtension
        if base.hasSuffix("_mic") { base.removeLast(4) }
        return base
    }

    /// Actor-isolated access to current session state.
    public func getSessionState() async -> SessionState {
        await stateStore.getSessionState()
    }

    /// A period during which nothing was recorded (relaunch, sleep). Persisted with the session so a
    /// later relaunch and the final transcript both see it (§7.2 metadata.capture.gaps).
    public nonisolated func appendGap(_ gap: CaptureGap) async {
        await stateStore.appendGap(gap)
        // Same path as a chunk's write: a failure is recorded and reported (nil = session-level).
        _ = await persist(chunkIndex: nil, context: "after a capture gap")
    }

    /// Write session.json and tell the coordinator either way: `onSessionWriteSucceeded`, or
    /// `onSessionWriteFailure` with the failure recorded in the session's issues so the next
    /// successful write persists it — a session that cannot be saved is not recoverable.
    private nonisolated func persist(chunkIndex: Int?, context: String) async -> Bool {
        do {
            try await stateStore.persist()
            await MainActor.run { self.onSessionWriteSucceeded?() }
            return true
        } catch {
            Logger.state.error("Failed to write session.json \(context, privacy: .public): \(error, privacy: .private)")
            await stateStore.noteSessionWriteFailure(chunkIndex: chunkIndex)
            await MainActor.run { self.onSessionWriteFailure?(chunkIndex) }
            return false
        }
    }

    // MARK: - Private

    private nonisolated func processChunkAsync(_ chunk: ChunkRotator.FinalizedChunk, extraIssues: [ChunkIssue] = []) async {
        let startTime = ContinuousClock.now
        Logger.transcription.info(
            "Chunk \(chunk.index, privacy: .public) processing started (qos: \(self.config.chunkProcessingQos, privacy: .public))"
        )

        // 0. A chunk whose WAVs are gone but whose .m4a exists — archived, then the process died
        //    before session.json got it (C-I4, in a build that deleted the WAVs first). The archive is
        //    the only copy: its words are recognised from scratch WAVs split out of it, and it stays
        //    the chunk's audio as-is (never re-encoded over itself).
        var systemURL = URL(fileURLWithPath: chunk.systemPath)
        var micURL = URL(fileURLWithPath: chunk.micPath)
        var existingArchive: URL?
        var scratch: URL?
        var archiveIssues: [ChunkIssue] = []
        if let archive = Self.archiveOnlyChunk(chunk) {
            existingArchive = archive
            if let split = await splitArchive(archive, chunkIndex: chunk.index) {
                archiveIssues.append(ChunkIssue(code: .transcribedFromArchive, track: nil, count: nil))
                scratch = split.directory
                systemURL = split.system
                micURL = split.mic ?? split.directory.appendingPathComponent("absent_mic.wav")
            }
        }
        defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }

        // 1. Transcribe + diarize system audio
        let systemResult = await transcribeStream(
            audioPath: systemURL, source: "remote", audioSource: .system, label: "chunk-\(chunk.index)-system"
        )

        // 2. Transcribe mic audio (skip if file missing or empty)
        // Dual-stream is a property of the CAPTURE, not of whether the user spoke. Deriving it from
        // `!micResult.segments.isEmpty` meant a chunk the user sat through in silence skipped source
        // prefixing while its siblings kept it — so the reconciler's `Remote Speaker N` keys matched
        // nothing there, its mapping fell back to the identity, and its chunk-local numbering was
        // laundered into the global namespace, swapping speakers for the rest of the meeting.
        let hasDualStream = FileManager.default.fileExists(atPath: micURL.path)
        let micResult: StreamResult
        if hasDualStream {
            micResult = await transcribeStream(
                audioPath: micURL, source: "local", audioSource: .microphone, label: "chunk-\(chunk.index)-mic"
            )
        } else {
            micResult = StreamResult(segments: [], speakerDatabase: [:])
        }
        var issues = extraIssues + archiveIssues + systemResult.issues + micResult.issues

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
                echo: seg.echo,
                duplicate: seg.duplicate
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
        //
        // The archiver never deletes here: the WAVs go only once session.json holds this chunk with
        // its .m4a (step 8, C-I4). Deleted first, a crash before the write lost the chunk.
        var audioPath = systemURL.lastPathComponent
        let micFileExists = FileManager.default.fileExists(atPath: micURL.path)
        // An ASR-failed chunk keeps its WAV(s) next to the .m4a so it can be re-transcribed (P3):
        // the AAC is lossy, and the words it failed to yield exist nowhere else.
        let preserveSourceWAV = (config.preserveSourceWAV ?? false) || issues.contains { $0.code == .asrFailed }
        var archivePath: URL?
        if let existingArchive {
            audioPath = existingArchive.lastPathComponent
            archivePath = existingArchive
        } else {
            do {
                let archiveResult: AudioArchiveResult
                if micFileExists {
                    archiveResult = try await AudioArchiver.archive(
                        systemAudio: systemURL,
                        micAudio: micURL,
                        outputDirectory: outputDirectory,
                        bitrateKbps: config.archiveBitrateKbps,
                        preserveSourceWAV: true
                    )
                } else {
                    archiveResult = try await AudioArchiver.archiveSystemOnly(
                        systemAudio: systemURL,
                        outputDirectory: outputDirectory,
                        bitrateKbps: config.archiveBitrateKbps,
                        preserveSourceWAV: true
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
                Logger.files.error("Chunk \(chunk.index, privacy: .public) archival failed, keeping WAV(s) — transcript will reference \(audioPath, privacy: .sensitive): \(error, privacy: .private)")
                issues.append(ChunkIssue(code: .archiveFailed, track: nil, count: nil))
            }
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
                Logger.files.error("Chunk \(chunk.index, privacy: .public) quota enforcement failed: \(error, privacy: .private)")
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

        // 8. Actor-isolated append + persist; only then may the source WAVs go (C-I4). A chunk that
        //    could not be persisted keeps them: they are what a relaunch's orphan scan finds.
        await stateStore.appendChunk(processed)
        let persisted = await persist(chunkIndex: chunk.index, context: "for chunk \(chunk.index)")
        if existingArchive == nil, archivePath != nil {
            if !persisted {
                Logger.files.error("Chunk \(chunk.index, privacy: .public) is not in session.json — keeping its WAV(s) so a relaunch can still recover it")
            } else if preserveSourceWAV {
                Logger.files.info("Chunk \(chunk.index, privacy: .public): keeping source WAV(s) next to the archive")
            } else {
                // Every success path of the archiver consumed both files (an empty header included).
                try? FileManager.default.removeItem(at: systemURL)
                if micFileExists { try? FileManager.default.removeItem(at: micURL) }
            }
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

    /// The chunk's `.m4a` when it is the only artefact left: neither WAV exists, the archive does.
    /// A caller that names the archive itself as the system path gets it back too — archiving it
    /// again would remove the source as "stale output" before encoding it.
    nonisolated static func archiveOnlyChunk(_ chunk: ChunkRotator.FinalizedChunk) -> URL? {
        let system = URL(fileURLWithPath: chunk.systemPath)
        let fm = FileManager.default
        if system.pathExtension == "m4a" { return fm.fileExists(atPath: system.path) ? system : nil }
        guard !fm.fileExists(atPath: system.path), !fm.fileExists(atPath: chunk.micPath) else { return nil }
        let archive = system.deletingPathExtension().appendingPathExtension("m4a")
        return fm.fileExists(atPath: archive.path) ? archive : nil
    }

    /// Split an archived chunk (L = mic, R = system) into scratch WAVs outside the output folder.
    /// The mic side is kept only when this chunk was dual-stream: like the session's other chunks
    /// when it has any (so the reconciler's namespaces agree), else when the mic channel holds any
    /// non-zero sample. nil when the archive can't be read — the chunk is then recorded with its
    /// system stream missing, never dropped.
    private nonisolated func splitArchive(_ archive: URL, chunkIndex: Int) async -> (directory: URL, system: URL, mic: URL?)? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parley-archive-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let split = try await AudioSourceResolver.splitChannels(stereoAac: archive, outputDirectory: directory)
            let siblings = await stateStore.getSessionState().chunks
            let dual = siblings.isEmpty ? Self.hasSignal(split.local) : siblings.contains(where: \.isDualStream)
            if !dual { try? FileManager.default.removeItem(at: split.local) }
            Logger.transcription.error("Chunk \(chunkIndex, privacy: .public) has no WAVs, only its archive — transcribing it from \(archive.lastPathComponent, privacy: .sensitive)")
            return (directory, split.remote, dual ? split.local : nil)
        } catch {
            Logger.transcription.error("Chunk \(chunkIndex, privacy: .public): its archive could not be read: \(error, privacy: .private)")
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    /// Whether a WAV holds any non-zero sample (stops at the first one).
    private nonisolated static func hasSignal(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)
        else { return false }
        while (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 {
            guard let samples = buffer.int16ChannelData?[0] else { return false }
            if UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)).contains(where: { $0 != 0 }) { return true }
        }
        return false
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

        // A WAV that does not exist is not an idle side: something lost or never wrote it.
        guard FileManager.default.fileExists(atPath: audioPath.path) else {
            Logger.transcription.error("Missing \(label, privacy: .public) audio file: \(audioPath.lastPathComponent, privacy: .sensitive)")
            return StreamResult(segments: [], speakerDatabase: [:],
                                issues: [ChunkIssue(code: .streamMissing, track: source, count: nil)])
        }

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
            Logger.transcription.error("Transcription failed for \(label, privacy: .public): \(error, privacy: .private)")
            return StreamResult(segments: [], speakerDatabase: [:],
                                issues: [ChunkIssue(code: .asrFailed, track: source, count: nil)])
        }

        var issues: [ChunkIssue] = []
        let dedup = SpeakerAssignment.deduplicate(segments)
        segments = dedup.segments
        if !dedup.duplicates.isEmpty {
            issues.append(ChunkIssue(code: .duplicatesFlagged, track: source, count: dedup.duplicates.count))
        }
        if dedup.zeroLength > 0 {
            issues.append(ChunkIssue(code: .zeroLengthDropped, track: source, count: dedup.zeroLength))
        }
        var labeled: [LabeledSegment]
        var speakerDatabase: [String: [Float]] = [:]
        if let diarizer {
            do {
                // Run diarization + VAD concurrently
                async let diarizedResult = diarizer.diarize(audioPath: audioPath, numSpeakers: nil)
                async let speechMapResult = vadSpeechMap.analyze(audioPath: audioPath)

                let diarizationResult = try await diarizedResult
                // No speech map either way means the quality gate ran without one. A model that is not
                // cached is informational; VAD throwing is a real failure and is filed as one.
                let speechMap: [SpeechRegion]?
                do {
                    speechMap = try await speechMapResult
                    if speechMap == nil {
                        issues.append(ChunkIssue(code: .vadUnavailable, track: source, count: nil))
                    }
                } catch {
                    Logger.transcription.error("VAD failed for \(label, privacy: .public): \(error, privacy: .private)")
                    speechMap = nil
                    issues.append(ChunkIssue(code: .vadFailed, track: source, count: nil))
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
                Logger.transcription.error("Diarization failed for \(label, privacy: .public): \(error, privacy: .private)")
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
        // The repeats go back in flagged — kept in the record, hidden when read (P2).
        labeled = SpeakerAssignment.reattachDuplicates(dedup.duplicates, to: labeled)

        for i in labeled.indices {
            labeled[i].source = source
        }

        Logger.transcription.info("\(label.capitalized, privacy: .public) transcription: \(labeled.count) segments")
        return StreamResult(segments: labeled, speakerDatabase: speakerDatabase, issues: issues)
    }
}
