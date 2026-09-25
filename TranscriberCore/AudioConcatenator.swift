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

    public var errorDescription: String? {
        switch self {
        case .noSources: return "No source files provided"
        case .cannotLoadTrack(let msg): return "Cannot load audio track: \(msg)"
        case .exportFailed(let msg): return "Export failed: \(msg)"
        case .mixedSources(let names): return "Refusing to merge sources that are not all .m4a: \(names.joined(separator: ", "))"
        case .implausibleTiming(let why): return "Refusing to merge: \(why)"
        }
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
    /// - Important: `chunks` must be provided in chronological order. This function inserts
    ///   them sequentially into the composition without sorting — callers are responsible for
    ///   ordering by chunk index (or recording time) before calling. (#56)
    public static func concatenate(
        chunks: [ChunkAudio],
        outputDirectory: URL,
        outputName: String,
        deleteSources: Bool
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

        // Build composition
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioConcatenatorError.exportFailed("Cannot add composition track")
        }

        // Load every source first, and check the timeline they make before anything is inserted or
        // written: implausible timing is refused, the chunk files kept (round 5).
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
                expectedSeconds: expectedSeconds, toleranceSeconds: toleranceSeconds
            )
            usedPassthrough = true
            Logger.files.info("AudioConcatenator: passthrough export succeeded → \(outputURL.lastPathComponent, privacy: .sensitive)")
        } catch {
            // Passthrough failed or was skipped — re-encode with AAC
            Logger.files.info("AudioConcatenator: re-encoding with AAC (\(gapsInsertedSeconds > 0 ? "silence inserted" : "passthrough failed", privacy: .public))")
            try await exportVerified(
                composition: composition, to: outputURL, preset: AVAssetExportPresetAppleM4A,
                expectedSeconds: expectedSeconds, toleranceSeconds: toleranceSeconds
            )
            usedPassthrough = false
            Logger.files.info("AudioConcatenator: re-encode succeeded → \(outputURL.lastPathComponent, privacy: .sensitive)")
        }

        if deleteSources {
            deleteM4aSources(sources)
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
        toleranceSeconds: Double
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        do {
            _ = try await export(composition: composition, to: outputURL, preset: preset, fileType: .m4a)
            let played = try await AVURLAsset(url: outputURL).load(.duration).seconds
            let file = try AVAudioFile(forReading: outputURL)
            let decoded = file.processingFormat.sampleRate > 0
                ? Double(file.length) / file.processingFormat.sampleRate : 0
            for actual in [played, decoded] where abs(actual - expectedSeconds) > toleranceSeconds {
                throw AudioConcatenatorError.exportFailed(
                    "\(preset): duration mismatch — got \(String(format: "%.2f", actual))s, expected \(String(format: "%.2f", expectedSeconds))s"
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func export(
        composition: AVMutableComposition,
        to outputURL: URL,
        preset: String,
        fileType: AVFileType
    ) async throws -> URL {
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
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw AudioConcatenatorError.exportFailed("\(preset): output file missing after export")
        }
        let attr = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = (attr?[.size] as? Int) ?? 0
        guard size > 0 else {
            throw AudioConcatenatorError.exportFailed("\(preset): output file is empty")
        }
        let asset = AVURLAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw AudioConcatenatorError.exportFailed("\(preset): output has no audio tracks")
        }
        return outputURL
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

    /// Delete merged chunk files — `.m4a` only. A lossless source is never deleted here.
    private static func deleteM4aSources(_ sources: [URL]) {
        for url in sources where url.pathExtension.lowercased() == "m4a" {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
