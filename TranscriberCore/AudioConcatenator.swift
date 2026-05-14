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
    public static func concatenate(
        sources: [URL],
        outputDirectory: URL,
        outputName: String
    ) async throws -> AudioConcatenationResult {
        guard !sources.isEmpty else { throw AudioConcatenatorError.noSources }

        Logger.files.info("AudioConcatenator: stitching \(sources.count, privacy: .public) chunks → \(outputName, privacy: .public).m4a")

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
            Logger.files.info("AudioConcatenator: passthrough export succeeded → \(outputURL.lastPathComponent, privacy: .public)")
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
        Logger.files.info("AudioConcatenator: re-encode succeeded → \(outputURL.lastPathComponent, privacy: .public)")
        return AudioConcatenationResult(outputPath: result, usedPassthrough: false)
    }

    // MARK: - Private

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
            try await session.export(to: outputURL, as: fileType)
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

    private static func deleteSources(_ sources: [URL]) {
        for url in sources {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
