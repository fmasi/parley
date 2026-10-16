import AVFoundation
import os

// MARK: - Public types

/// One chunk's archived audio and the wall-clock time it started, so the merged file can keep the
/// transcript's timeline across a gap (a crash restart, sleep) instead of butting chunks together.
public struct ChunkAudio: Sendable {
    public let url: URL
    /// nil when unknown: no silence is inserted before this chunk.
    public let startTime: Date?

    public init(url: URL, startTime: Date?) {
        self.url = url
        self.startTime = startTime
    }
}

public struct AudioConcatenationResult: Sendable {
    public let outputPath: URL
    /// True if AVFoundation used passthrough (no re-encode). False if it fell back to AAC re-encode.
    public let usedPassthrough: Bool
    /// Total silence inserted between chunks to keep the wall-clock timeline (P9).
    public let gapsInsertedSeconds: Double

    public init(outputPath: URL, usedPassthrough: Bool, gapsInsertedSeconds: Double = 0) {
        self.outputPath = outputPath
        self.usedPassthrough = usedPassthrough
        self.gapsInsertedSeconds = gapsInsertedSeconds
    }
}

public enum AudioConcatenatorError: LocalizedError {
    case noSources
    case cannotLoadTrack(String)
    case exportFailed(String)
    /// Sources that are not all `.m4a` (file names). Refused: re-encoding a mono WAV fallback into a
    /// stereo merge put one track in BOTH channels, and deleting it destroyed the only lossless copy.
    case mixedSources([String])
    /// The chunks' start times would put implausible silence into the merge (round 5): a start that
    /// is not finite, earlier than the first chunk's, or gaps over `maxInsertedSilenceSeconds`.
    /// Refused before anything is written; the chunk files stay the recording's audio.
    case implausibleTiming(String)
    /// A step that touches the recording folder did not answer within its bound (L review 231): the merge is skipped — its
    /// sources untouched — and the chunk files are the recording's audio. The step, by name.
    case folderNotAnswering(String)

    public var errorDescription: String? {
        switch self {
        case .noSources: return "No source files provided"
        case .cannotLoadTrack(let msg): return "Cannot load audio track: \(msg)"
        case .exportFailed(let msg): return "Export failed: \(msg)"
        case .mixedSources(let names): return "Refusing to merge sources that are not all .m4a: \(names.joined(separator: ", "))"
        case .implausibleTiming(let why): return "Refusing to merge: \(why)"
        case .folderNotAnswering(let step): return "The recording folder did not answer (\(step)) — the chunks were not merged"
        }
    }
}

/// Where a merge's steps that touch the recording folder run (L reviews 231, 252) — building from the sources, removing and
/// checking the output, deleting the sources: the recording folder's own queue, bounded, never the Swift cooperative pool,
/// where a hung folder held a thread and left the finalize "Finishing…" forever. The export itself runs in AVFoundation,
/// under its own timeout. Inline by default: the merge's own tests.
public protocol MergeFileSteps: Sendable {
    /// `work` — BLOCKING file work (a status, a size, a decode, a removal) — and its value;
    /// `AudioConcatenatorError.folderNotAnswering(label)` when it did not answer within its bound.
    func run<T>(_ label: String, _ work: @escaping @Sendable () throws -> T) async throws -> T
    /// The same for AVFoundation's asynchronous loads ONLY (an asset's tracks, its duration): they suspend, never blocking a
    /// thread. Never blocking file work: that goes through `run` (L review 252).
    func runAsync<T>(_ label: String, _ work: @escaping @Sendable () async throws -> T) async throws -> T
}

/// Every step at once, where the merge runs.
public struct InlineMergeFileSteps: MergeFileSteps {
    public init() {}
    public func run<T>(_ label: String, _ work: @escaping @Sendable () throws -> T) async throws -> T { try work() }
    public func runAsync<T>(_ label: String, _ work: @escaping @Sendable () async throws -> T) async throws -> T { try await work() }
}

/// Every step on the recording folder's queue, within `seconds` of awake time (L review 231): a blocking step runs on the
/// queue's own thread. An asynchronous step's loads run in AVFoundation, suspending — only they ever run as a task (L review
/// 252) — while the queue waits for them, so the folder's other reads and writes stay in order behind the step.
public struct FolderMergeSteps: MergeFileSteps {
    let reads: FolderReads
    let folder: String
    let seconds: Double

    public init(reads: FolderReads, folder: String, seconds: Double) {
        self.reads = reads; self.folder = folder; self.seconds = seconds
    }

    public func run<T>(_ label: String, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        guard let result = await reads.read(label, folder: folder, key: folder + "#" + label, seconds: seconds, {
            StepResult(Result { try work() })
        }) else { throw AudioConcatenatorError.folderNotAnswering(label) }
        return try result.value.get()
    }

    public func runAsync<T>(_ label: String, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await run(label) {
            // The folder's queue waits for the loads — AVFoundation's asynchronous ones only, which suspend (L review 252).
            let box = StepBox<T>()
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
                done.signal()
            }
            done.wait()
            return try box.result!.get()
        }
    }

    private struct StepResult<T>: @unchecked Sendable {
        let value: Result<T, Error>
        init(_ value: Result<T, Error>) { self.value = value }
    }

    private final class StepBox<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }
}

// MARK: - AudioConcatenator

/// Stitches N stereo AAC .m4a files into a single .m4a using AVMutableComposition.
/// Attempts lossless passthrough export first; falls back to AAC re-encode if passthrough fails.
/// Single-source input is a no-op (returns the source path unchanged).
public enum AudioConcatenator {

    /// A wall-clock gap between two chunks longer than this is filled with silence (P9). Shorter
    /// differences are rotation jitter, not a hole in the recording.
    static let gapThresholdSeconds: Double = 1

    /// The most silence a merge will insert, one gap or all of them together. A recording gap of 12
    /// hours is already beyond any meeting; past it the timing is wrong (a clock step, a start
    /// estimated from a file date), and padding it wrote hours of silence until the export timed out.
    static let maxInsertedSilenceSeconds: Double = 12 * 3600

    private static func hours(_ seconds: Double) -> String {
        let h = seconds / 3600
        return h.rounded() == h ? String(Int(h)) : String(format: "%.1f", h)
    }

    /// "gap 13.2 h > 12 h bound"; in minutes when the hours would round to the bound itself (round 8
    /// item 4: never "12.0 h > 12 h").
    private static func overBound(_ what: String, _ seconds: Double) -> String {
        let shown = hours(seconds)
        if let value = Double(shown), value > maxInsertedSilenceSeconds / 3600 {
            return "\(what) \(shown) h > \(hours(maxInsertedSilenceSeconds)) h bound"
        }
        return "\(what) \(Int(seconds / 60)) min > \(Int(maxInsertedSilenceSeconds / 60)) min bound"
    }

    /// Why these start times can't be merged as a timeline, or nil when they can. `chunks` in the
    /// order they will be inserted; `durations` their lengths.
    static func implausibleTiming(_ chunks: [ChunkAudio], durations: [Double]) -> String? {
        guard let origin = chunks.first?.startTime else { return nil }
        var inserted = 0.0, total = 0.0
        for (chunk, duration) in zip(chunks, durations) {
            guard let start = chunk.startTime else { inserted += duration; continue }
            let offset = start.timeIntervalSince(origin)
            guard offset.isFinite else { return "a chunk's start time is not a real time" }
            guard offset >= -gapThresholdSeconds else { return "a chunk starts \(Int(-offset)) s before the first chunk" }
            let gap = offset - inserted
            if gap > gapThresholdSeconds {
                guard gap <= maxInsertedSilenceSeconds else { return overBound("gap", gap) }
                total += gap
                guard total <= maxInsertedSilenceSeconds else { return overBound("gaps totalling", total) }
                inserted += gap
            }
            inserted += duration
        }
        return nil
    }

    /// Concatenate `chunks` into a single .m4a at `outputDirectory/<outputName>.m4a`.
    ///
    /// Refuses anything but `.m4a` sources (`mixedSources`) and never deletes a source unless the
    /// merged output was verified to be as long as the sources plus the inserted gaps. Where a
    /// chunk's `startTime` is more than `gapThresholdSeconds` after the previous chunk's end, that
    /// much silence is inserted so the merged audio keeps the transcript's wall-clock timeline.
    ///
    /// - Parameter deleteSources: delete the chunk files after a verified merge (false honours
    ///   `preserve_source_wav`).
    /// - Parameter steps: where its blocking file steps run (L review 231): the finalize's folder queue, bounded. A step
    ///   that does not answer throws `folderNotAnswering` — the sources untouched, a late step never leaving a half merge.
    /// - Important: `chunks` must be provided in chronological order. This function inserts
    ///   them sequentially into the composition without sorting — callers are responsible for
    ///   ordering by chunk index (or recording time) before calling. (#56)
    public static func concatenate(
        chunks: [ChunkAudio],
        outputDirectory: URL,
        outputName: String,
        deleteSources: Bool,
        steps fileSteps: any MergeFileSteps = InlineMergeFileSteps()
    ) async throws -> AudioConcatenationResult {
        guard !chunks.isEmpty else { throw AudioConcatenatorError.noSources }
        // Wall-clock order when every chunk has a start time — the order the transcript's timestamps
        // use. A chunk re-indexed after a collision can have an index out of time order.
        let chunks = chunks.allSatisfy({ $0.startTime != nil })
            ? chunks.sorted { $0.startTime! < $1.startTime! }
            : chunks
        let sources = chunks.map(\.url)

        Logger.files.info("AudioConcatenator: stitching \(sources.count, privacy: .public) chunks → \(outputName, privacy: .sensitive).m4a")

        // Single source: nothing to stitch.
        if sources.count == 1 {
            return AudioConcatenationResult(outputPath: sources[0], usedPassthrough: true)
        }

        // A WAV here is an archive-failure fallback: a lossless, possibly mono file. Merging it
        // re-encodes it into both stereo channels, and deleting it afterwards destroys the only
        // lossless copy (P4). The separate files stay readable, so refusing loses nothing.
        guard sources.allSatisfy({ $0.pathExtension.lowercased() == "m4a" }) else {
            Logger.files.error("AudioConcatenator: refusing to merge — not every source is .m4a; keeping the chunk files")
            throw AudioConcatenatorError.mixedSources(sources.map(\.lastPathComponent))
        }

        // An existing output is NOT removed here: on a finalize re-run it can be the only copy left
        // (the chunk files were deleted by the first run), and a source that fails to load below
        // must leave it alone. `exportVerified` replaces it only once every source has loaded.
        let outputURL = outputDirectory.appendingPathComponent("\(outputName).m4a")

        let steps = Steps(runner: fileSteps)
        // Load every source first, and check the timeline they make before anything is inserted or
        // written: implausible timing is refused, the chunk files kept (round 5). On the folder's queue (L reviews 231, 252):
        // AVFoundation's loads as an asynchronous step, then the check and the composition that reads the sources' tracks.
        let found = try await steps.runAsync("merge: sources loads") { () -> Loaded in
            // The assets are kept alongside their tracks: a track whose asset is released can't be inserted.
            var loaded: [(asset: AVURLAsset, track: AVAssetTrack, duration: CMTime)] = []
            for chunk in chunks {
                let asset = AVURLAsset(url: chunk.url)
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                guard let track = tracks.first else {
                    throw AudioConcatenatorError.cannotLoadTrack(chunk.url.lastPathComponent)
                }
                loaded.append((asset, track, try await asset.load(.duration)))
            }
            return Loaded(sources: loaded)
        }
        let built = try await steps.run("merge: sources") { () -> Built in
            let loaded = found.sources
            let composition = AVMutableComposition()
            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw AudioConcatenatorError.exportFailed("Cannot add composition track")
            }
            if let why = implausibleTiming(chunks, durations: loaded.map(\.duration.seconds)) {
                Logger.files.error("AudioConcatenator: refusing to merge — \(why, privacy: .public); keeping the chunk files")
                throw AudioConcatenatorError.implausibleTiming(why)
            }

            // Each chunk goes at its ABSOLUTE wall-clock offset from the first chunk: the gap is
            // measured against where the merged file actually is (`insertTime`), not the previous
            // chunk's end, so sub-second shortfalls cannot add up — every boundary stays within 1 s.
            var insertTime = CMTime.zero
            var sourceSeconds = 0.0
            var gapsInsertedSeconds = 0.0
            let origin = chunks.first?.startTime
            for (chunk, source) in zip(chunks, loaded) {
                let (_, track, duration) = source
                if let start = chunk.startTime, let origin {
                    let gap = start.timeIntervalSince(origin) - insertTime.seconds
                    if gap > gapThresholdSeconds {
                        let gapTime = CMTime(seconds: gap, preferredTimescale: 48_000)
                        compositionTrack.insertEmptyTimeRange(CMTimeRange(start: insertTime, duration: gapTime))
                        insertTime = CMTimeAdd(insertTime, gapTime)
                        gapsInsertedSeconds += gap
                    }
                }
                let timeRange = CMTimeRange(start: .zero, duration: duration)
                try compositionTrack.insertTimeRange(timeRange, of: track, at: insertTime)
                insertTime = CMTimeAdd(insertTime, duration)
                sourceSeconds += duration.seconds
            }
            return Built(composition: composition, sourceSeconds: sourceSeconds, gapsInsertedSeconds: gapsInsertedSeconds)
        }
        let composition = built.composition, sourceSeconds = built.sourceSeconds, gapsInsertedSeconds = built.gapsInsertedSeconds
        if gapsInsertedSeconds > 0 {
            Logger.files.info("AudioConcatenator: inserted \(gapsInsertedSeconds, format: .fixed(precision: 1), privacy: .public)s of silence between chunks")
        }

        // The sources are deleted only when the merge is as long as they are (+ gaps): a truncated
        // export that "succeeded" would otherwise take the only copies with it.
        let expectedSeconds = sourceSeconds + gapsInsertedSeconds
        let toleranceSeconds = verificationToleranceForTesting ?? (0.25 + 0.05 * Double(chunks.count))

        // Passthrough first — unless silence was inserted: a passthrough merge represents it as an
        // empty edit that decode-based readers (re-detect, speaker samples) may not honour, leaving
        // them 1-2 s off on a long session. The re-encode writes real silence.
        let usedPassthrough: Bool
        do {
            guard gapsInsertedSeconds == 0 else {
                throw AudioConcatenatorError.exportFailed("passthrough skipped: silence was inserted")
            }
            try await exportVerified(
                composition: composition, to: outputURL, preset: AVAssetExportPresetPassthrough,
                expectedSeconds: expectedSeconds, toleranceSeconds: toleranceSeconds, steps: steps
            )
            usedPassthrough = true
            Logger.files.info("AudioConcatenator: passthrough export succeeded → \(outputURL.lastPathComponent, privacy: .sensitive)")
        } catch AudioConcatenatorError.folderNotAnswering(let step) {
            throw AudioConcatenatorError.folderNotAnswering(step)   // never a re-encode into a folder that does not answer
        } catch {
            // Passthrough failed or was skipped — re-encode with AAC
            Logger.files.info("AudioConcatenator: re-encoding with AAC (\(gapsInsertedSeconds > 0 ? "silence inserted" : "passthrough failed", privacy: .public))")
            try await exportVerified(
                composition: composition, to: outputURL, preset: AVAssetExportPresetAppleM4A,
                expectedSeconds: expectedSeconds, toleranceSeconds: toleranceSeconds, steps: steps
            )
            usedPassthrough = false
            Logger.files.info("AudioConcatenator: re-encode succeeded → \(outputURL.lastPathComponent, privacy: .sensitive)")
        }

        if deleteSources {
            // The merge is verified and listed from here: a delete that does not answer is only logged — it may land later,
            // and the merged file holds every source (L review 231).
            do {
                try await steps.run("merge: delete sources") { deleteM4aSources(sources) }
            } catch {
                Logger.files.error("AudioConcatenator: the merged chunk files' deletes did not answer — the merge is kept; they may go later")
            }
        } else {
            Logger.files.info("AudioConcatenator: keeping the chunk files (preserve_source_wav)")
        }
        return AudioConcatenationResult(
            outputPath: outputURL, usedPassthrough: usedPassthrough, gapsInsertedSeconds: gapsInsertedSeconds
        )
    }

    // MARK: - Private

    /// Hard cap on a single export pass. `AVAssetExportSession` can hang indefinitely on a
    /// corrupt composition; this bounds it so `finalize()` fails loudly instead of blocking
    /// forever. 5 minutes is generous — passthrough is near-instant and AAC re-encode runs many
    /// times faster than real time on Apple Silicon, so any longer means the export is stuck. (#51)
    private static let exportTimeout: Duration = .seconds(300)

    /// Test seam: overrides the duration tolerance of the post-export check (a negative value makes
    /// every export fail verification).
    nonisolated(unsafe) static var verificationToleranceForTesting: Double?

    /// `export`, then check the output is `expectedSeconds` long (± `toleranceSeconds`). On any
    /// failure the output is removed so a bad merge is never mistaken for the recording.
    ///
    /// The length is checked twice: as AVFoundation plays it (edit list honoured) and as
    /// `AVAudioFile` decodes it — the reader re-detect and speaker samples use. A passthrough merge
    /// can represent an inserted gap as an empty edit that the second reader may not honour; that
    /// shows up here as a mismatch, and the caller falls back to a re-encode that writes real silence.
    private static func exportVerified(
        composition: AVMutableComposition,
        to outputURL: URL,
        preset: String,
        expectedSeconds: Double,
        toleranceSeconds: Double,
        steps: Steps
    ) async throws {
        try await steps.run("merge: output") { try? FileManager.default.removeItem(at: outputURL) }
        do {
            try await export(composition: composition, to: outputURL, preset: preset, fileType: .m4a)
        } catch {
            try await steps.run("merge: output") { try? FileManager.default.removeItem(at: outputURL) }
            throw error
        }
        // The output's checks, on the folder's queue (L reviews 231, 252). One that does not answer in time has its output
        // removed behind it (`Steps.check`); one that fails in time, here.
        do {
            try await checkOutput(outputURL, preset: preset, expectedSeconds: expectedSeconds, toleranceSeconds: toleranceSeconds, steps: steps)
        } catch AudioConcatenatorError.folderNotAnswering(let step) {
            throw AudioConcatenatorError.folderNotAnswering(step)
        } catch {
            try await steps.run("merge: output") { try? FileManager.default.removeItem(at: outputURL) }
            throw error
        }
    }

    /// The export's output is there, not empty, has audio, and is `expectedSeconds` long (± `toleranceSeconds`) as AVFoundation
    /// plays it AND as `AVAudioFile` decodes it. Split by kind (L review 252): the status, size and decode are blocking steps
    /// on the folder's queue; only the tracks and the played length — AVFoundation's loads — are an asynchronous one.
    private static func checkOutput(_ outputURL: URL, preset: String, expectedSeconds: Double, toleranceSeconds: Double,
                                    steps: Steps) async throws {
        try await steps.check("merge: check output", output: outputURL) {
            guard FileManager.default.fileExists(atPath: outputURL.path) else {
                throw AudioConcatenatorError.exportFailed("\(preset): output file missing after export")
            }
            let attr = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
            guard ((attr?[.size] as? Int) ?? 0) > 0 else {
                throw AudioConcatenatorError.exportFailed("\(preset): output file is empty")
            }
        }
        let played = try await steps.checkLoads("merge: check output loads", output: outputURL) { () -> Double in
            let asset = AVURLAsset(url: outputURL)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else {
                throw AudioConcatenatorError.exportFailed("\(preset): output has no audio tracks")
            }
            return try await asset.load(.duration).seconds
        }
        let decoded = try await steps.check("merge: check output decoded", output: outputURL) { () -> Double in
            let file = try AVAudioFile(forReading: outputURL)
            return file.processingFormat.sampleRate > 0 ? Double(file.length) / file.processingFormat.sampleRate : 0
        }
        for actual in [played, decoded] where abs(actual - expectedSeconds) > toleranceSeconds {
            throw AudioConcatenatorError.exportFailed(
                "\(preset): duration mismatch — got \(String(format: "%.2f", actual))s, expected \(String(format: "%.2f", expectedSeconds))s"
            )
        }
    }

    private static func export(
        composition: AVMutableComposition,
        to outputURL: URL,
        preset: String,
        fileType: AVFileType
    ) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw AudioConcatenatorError.exportFailed("Cannot create export session for preset \(preset)")
        }
        do {
            try await exportWithTimeout(session: session, to: outputURL, as: fileType, preset: preset)
        } catch let error as AudioConcatenatorError {
            throw error
        } catch {
            throw AudioConcatenatorError.exportFailed("\(preset): \(error.localizedDescription)")
        }
    }

    /// Run the export, racing it against `exportTimeout`. If the timeout wins, cancel the
    /// export session and throw, so a corrupt composition can't wedge the pipeline forever. (#51)
    private static func exportWithTimeout(
        session: AVAssetExportSession,
        to outputURL: URL,
        as fileType: AVFileType,
        preset: String
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await session.export(to: outputURL, as: fileType)
            }
            group.addTask {
                try await Task.sleep(for: exportTimeout)
                throw AudioConcatenatorError.exportFailed(
                    "\(preset): export timed out after \(exportTimeout)"
                )
            }
            defer { group.cancelAll() }
            do {
                // Wait for whichever finishes first (export success, export error, or timeout).
                try await group.next()
            } catch {
                session.cancelExport()
                throw error
            }
        }
    }

    /// What the sources' loads found: each asset, its audio track and its length — handed from the loads to the step that
    /// builds the composition from them.
    private struct Loaded: @unchecked Sendable {
        let sources: [(asset: AVURLAsset, track: AVAssetTrack, duration: CMTime)]
    }

    /// What the sources step built: the composition and the lengths the output is checked against.
    private struct Built: @unchecked Sendable {
        let composition: AVMutableComposition
        let sourceSeconds: Double
        let gapsInsertedSeconds: Double
    }

    /// A check's answer, CLAIMED ONCE (L review 253): by the check as it finishes, or by its caller as the bound runs out —
    /// whichever comes first. So a check that finished in the very instant its bound ran out still stands.
    final class Claim<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: Result<T, Error>?
        private var gaveUp = false
        /// The check finished: its answer, unless its caller gave up first.
        func finish(_ value: Result<T, Error>) { lock.withLock { if !gaveUp { answer = value } } }
        /// The bound ran out: the check's answer when it finished first — else nil, and the caller has it.
        func giveUp() -> Result<T, Error>? {
            lock.withLock {
                if let answer { return answer }
                gaveUp = true
                return nil
            }
        }
    }

    /// The merge's steps, through `runner`: a step that does not answer skips the merge (L review 231).
    struct Steps: Sendable {
        let runner: any MergeFileSteps

        func run<T>(_ label: String, _ work: @escaping @Sendable () throws -> T) async throws -> T {
            do { return try await runner.run(label, work) } catch { throw sayIfUnanswered(error, label) }
        }

        func runAsync<T>(_ label: String, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
            do { return try await runner.runAsync(label, work) } catch { throw sayIfUnanswered(error, label) }
        }

        /// A blocking check of `output`, its answer claimed once (L review 253).
        func check<T>(_ label: String, output: URL, _ work: @escaping @Sendable () throws -> T) async throws -> T {
            let claim = Claim<T>()
            do {
                return try await runner.run(label) { () throws -> T in
                    let value = Result { try work() }
                    claim.finish(value)
                    return try value.get()
                }
            } catch AudioConcatenatorError.folderNotAnswering {
                return try gaveUp(label, claim, output)
            }
        }

        /// A check of `output` by AVFoundation's loads, its answer claimed once (L review 253).
        func checkLoads<T>(_ label: String, output: URL, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
            let claim = Claim<T>()
            do {
                return try await runner.runAsync(label) { () async throws -> T in
                    let value: Result<T, Error>
                    do { value = .success(try await work()) } catch { value = .failure(error) }
                    claim.finish(value)
                    return try value.get()
                }
            } catch AudioConcatenatorError.folderNotAnswering {
                return try gaveUp(label, claim, output)
            }
        }

        /// A check's bound ran out (L review 253). One that finished first is its own: its answer stands, and the merge it
        /// verified is listed. Otherwise the merge is skipped — its chunk files listed — and the output is removed BEHIND the
        /// late check, on the folder's queue (L review 252): never left on disk unlisted.
        private func gaveUp<T>(_ label: String, _ claim: Claim<T>, _ output: URL) throws -> T {
            if let answer = claim.giveUp() {
                Logger.files.info("AudioConcatenator: \(label, privacy: .public) answered as its bound ran out — its answer stands")
                return try answer.get()
            }
            let runner = self.runner
            Task { _ = try? await runner.run("merge: output") { try? FileManager.default.removeItem(at: output) } }
            throw sayIfUnanswered(AudioConcatenatorError.folderNotAnswering(label), label)
        }

        private func sayIfUnanswered(_ error: Error, _ label: String) -> Error {
            if case AudioConcatenatorError.folderNotAnswering = error {
                Logger.files.error("AudioConcatenator: \(label, privacy: .public) did not answer — the merge is skipped, its chunk files kept")
            }
            return error
        }
    }

    /// Delete merged chunk files — `.m4a` only. A lossless source is never deleted here.
    private static func deleteM4aSources(_ sources: [URL]) {
        for url in sources where url.pathExtension.lowercased() == "m4a" {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
