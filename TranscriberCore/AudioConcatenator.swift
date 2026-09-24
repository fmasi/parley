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

    public var errorDescription: String? {
        switch self {
        case .noSources: return "No source files provided"
        case .cannotLoadTrack(let msg): return "Cannot load audio track: \(msg)"
        case .exportFailed(let msg): return "Export failed: \(msg)"
        case .mixedSources(let names): return "Refusing to merge sources that are not all .m4a: \(names.joined(separator: ", "))"
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

    /// Concatenate `sources` into a single .m4a, deleting the sources on success. Kept for callers
    /// without chunk start times: no gaps are inserted.
    public static func concatenate(
        sources: [URL],
        outputDirectory: URL,
        outputName: String
    ) async throws -> AudioConcatenationResult {
        try await concatenate(
            chunks: sources.map { ChunkAudio(url: $0, startTime: nil) },
            outputDirectory: outputDirectory,
            outputName: outputName,
            deleteSources: true
        )
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

        let outputURL = outputDirectory.appendingPathComponent("\(outputName).m4a")
        try? FileManager.default.removeItem(at: outputURL)

        // Build composition
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioConcatenatorError.exportFailed("Cannot add composition track")
        }

        var insertTime = CMTime.zero
        var previousEnd: Date?
        var sourceSeconds = 0.0
        var gapsInsertedSeconds = 0.0
        for chunk in chunks {
            let asset = AVURLAsset(url: chunk.url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else {
                throw AudioConcatenatorError.cannotLoadTrack(chunk.url.lastPathComponent)
            }
            let duration = try await asset.load(.duration)
            if let start = chunk.startTime, let previousEnd {
                let gap = start.timeIntervalSince(previousEnd)
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
            previousEnd = chunk.startTime?.addingTimeInterval(duration.seconds)
        }
        if gapsInsertedSeconds > 0 {
            Logger.files.info("AudioConcatenator: inserted \(gapsInsertedSeconds, format: .fixed(precision: 1), privacy: .public)s of silence between chunks")
        }

        // The sources are deleted only when the merge is as long as they are (+ gaps): a truncated
        // export that "succeeded" would otherwise take the only copies with it.
        let expectedSeconds = sourceSeconds + gapsInsertedSeconds
        let toleranceSeconds = 0.25 + 0.05 * Double(chunks.count)

        // Try passthrough first
        let usedPassthrough: Bool
        do {
            try await exportVerified(
                composition: composition, to: outputURL, preset: AVAssetExportPresetPassthrough,
                expectedSeconds: expectedSeconds, toleranceSeconds: toleranceSeconds
            )
            usedPassthrough = true
            Logger.files.info("AudioConcatenator: passthrough export succeeded → \(outputURL.lastPathComponent, privacy: .sensitive)")
        } catch {
            // Passthrough failed — re-encode with AAC
            Logger.files.info("AudioConcatenator: passthrough failed, falling back to AAC re-encode")
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
