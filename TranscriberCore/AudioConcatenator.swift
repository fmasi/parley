import AVFoundation
import os

// MARK: - Public types

public struct AudioConcatenationResult: Sendable {
    public let outputPath: URL
    /// True if AVFoundation used passthrough (no re-encode). False if it fell back to AAC re-encode.
    public let usedPassthrough: Bool
}

public enum AudioConcatenatorError: LocalizedError {
    case noSources
    case cannotLoadTrack(String)
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSources: return "No source files provided"
        case .cannotLoadTrack(let msg): return "Cannot load audio track: \(msg)"
        case .exportFailed(let msg): return "Export failed: \(msg)"
        }
    }
}

// MARK: - AudioConcatenator

/// Stitches N stereo AAC .m4a files into a single .m4a using AVMutableComposition.
/// Attempts lossless passthrough export first; falls back to AAC re-encode if passthrough fails.
/// Single-source input is a no-op (returns the source path unchanged).
public enum AudioConcatenator {

    /// Concatenate `sources` into a single .m4a at `outputDirectory/<outputName>.m4a`.
    /// Deletes source files on success (when sources.count > 1).
    ///
    /// - Important: `sources` must be provided in chronological order. This function inserts
    ///   them sequentially into the composition without sorting — callers are responsible for
    ///   ordering by chunk index (or recording time) before calling. (#56)
    public static func concatenate(
        sources: [URL],
        outputDirectory: URL,
        outputName: String
    ) async throws -> AudioConcatenationResult {
        guard !sources.isEmpty else { throw AudioConcatenatorError.noSources }

        Logger.files.info("AudioConcatenator: stitching \(sources.count, privacy: .public) chunks → \(outputName, privacy: .private).m4a")

        // Single source: nothing to stitch.
        if sources.count == 1 {
            return AudioConcatenationResult(outputPath: sources[0], usedPassthrough: true)
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
        for source in sources {
            let asset = AVURLAsset(url: source)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else {
                throw AudioConcatenatorError.cannotLoadTrack(source.lastPathComponent)
            }
            let duration = try await asset.load(.duration)
            let timeRange = CMTimeRange(start: .zero, duration: duration)
            try compositionTrack.insertTimeRange(timeRange, of: track, at: insertTime)
            insertTime = CMTimeAdd(insertTime, duration)
        }

        // Try passthrough first
        if let result = try? await export(
            composition: composition,
            to: outputURL,
            preset: AVAssetExportPresetPassthrough,
            fileType: .m4a
        ) {
            deleteSources(sources)
            Logger.files.info("AudioConcatenator: passthrough export succeeded → \(outputURL.lastPathComponent, privacy: .private)")
            return AudioConcatenationResult(outputPath: result, usedPassthrough: true)
        }

        // Passthrough failed — re-encode with AAC
        Logger.files.info("AudioConcatenator: passthrough failed, falling back to AAC re-encode")
        try? FileManager.default.removeItem(at: outputURL)
        let result = try await export(
            composition: composition,
            to: outputURL,
            preset: AVAssetExportPresetAppleM4A,
            fileType: .m4a
        )
        deleteSources(sources)
        Logger.files.info("AudioConcatenator: re-encode succeeded → \(outputURL.lastPathComponent, privacy: .private)")
        return AudioConcatenationResult(outputPath: result, usedPassthrough: false)
    }

    // MARK: - Private

    /// Hard cap on a single export pass. `AVAssetExportSession` can hang indefinitely on a
    /// corrupt composition; this bounds it so `finalize()` fails loudly instead of blocking
    /// forever. 5 minutes is generous — passthrough is near-instant and AAC re-encode runs many
    /// times faster than real time on Apple Silicon, so any longer means the export is stuck. (#51)
    private static let exportTimeout: Duration = .seconds(300)

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

    private static func deleteSources(_ sources: [URL]) {
        for url in sources {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
