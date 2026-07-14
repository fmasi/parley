import AVFoundation
import Foundation
import os

/// Where a speaker sample actually lives on disk, once absolute transcript time has been
/// resolved against the recording's audio layout.
public struct SpeakerSampleLocation: Equatable {
    public let url: URL
    /// Offset within `url` (NOT absolute transcript time).
    public let start: TimeInterval
    public let end: TimeInterval
    /// Channel to read from a stereo archive: L = local (mic), R = remote (system).
    public let isLocal: Bool

    public init(url: URL, start: TimeInterval, end: TimeInterval, isLocal: Bool) {
        self.url = url
        self.start = start
        self.end = end
        self.isLocal = isLocal
    }
}

/// How a transcript's `audio_paths` map onto playable audio.
public enum AudioLayout: Equatable {
    /// One or more stereo AAC archives laid end to end (L = mic/local, R = system/remote).
    /// A single-chunk recording is just the one-element case.
    case chunkedArchives([URL])
    /// Legacy dual-stream WAVs: separate mono files per source, each on its own timeline.
    case legacyDualStream(remote: URL?, local: URL?)
    case unavailable
}

/// Resolves a transcript segment (absolute time + source) to a concrete file, offset and channel.
///
/// Before this existed, callers assumed `audio_paths` was always `[system, mic]`. For a chunked
/// recording it is actually `[chunk0, chunk1, ...]`, so samples past the first chunk were sought
/// in the wrong file and silently played nothing (#132).
public enum SpeakerSampleLocator {

    /// Default cap on sample length, so playback never sizes a buffer from an arbitrarily long
    /// diarization segment (segments over 400s have been observed on degraded audio).
    public static let defaultMaxSampleDuration: TimeInterval = 15

    /// Pure classification — no I/O, so it is directly testable.
    public static func classify(audioPaths: [URL]) -> AudioLayout {
        guard !audioPaths.isEmpty else { return .unavailable }

        // Chunked recordings archive each chunk to its own stereo .m4a. The single-file case
        // (merge_chunked_audio, or a one-chunk recording) is the same layout with one element.
        if audioPaths.allSatisfy({ $0.pathExtension.lowercased() == "m4a" }) {
            return .chunkedArchives(audioPaths)
        }

        // Legacy dual WAV: [0] = system (remote), [1] = mic (local).
        return .legacyDualStream(
            remote: audioPaths.first,
            local: audioPaths.count > 1 ? audioPaths[1] : nil
        )
    }

    /// Read each chunk's duration so absolute time can be mapped onto it.
    /// Unreadable files contribute 0 and are skipped by `ChunkLocator`.
    public static func durations(of urls: [URL]) -> [TimeInterval] {
        urls.map { url in
            guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else {
                Logger.files.error("SpeakerSampleLocator: cannot read duration of \(url.lastPathComponent, privacy: .private)")
                return 0
            }
            return Double(file.length) / file.processingFormat.sampleRate
        }
    }

    /// Resolve one segment. Returns nil when the sample cannot be played, so callers can
    /// disable the control rather than presenting a play button that silently does nothing.
    public static func locate(
        source: String,
        start: TimeInterval,
        end: TimeInterval,
        layout: AudioLayout,
        chunkDurations: [TimeInterval],
        maxSampleDuration: TimeInterval = defaultMaxSampleDuration
    ) -> SpeakerSampleLocation? {
        let isLocal = (source == "local")

        switch layout {
        case .unavailable:
            return nil

        case .chunkedArchives(let chunks):
            guard let hit = ChunkLocator.locate(
                start: start, end: end,
                chunkDurations: chunkDurations,
                maxDuration: maxSampleDuration
            ), chunks.indices.contains(hit.index) else { return nil }
            let url = chunks[hit.index]
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return SpeakerSampleLocation(url: url, start: hit.start, end: hit.end, isLocal: isLocal)

        case .legacyDualStream(let remote, let local):
            // Each source has its own mono file on its own timeline — no chunk mapping needed.
            guard let url = isLocal ? local : remote,
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            let capped = min(end, start + maxSampleDuration)
            guard capped > start else { return nil }
            return SpeakerSampleLocation(url: url, start: start, end: capped, isLocal: isLocal)
        }
    }
}
