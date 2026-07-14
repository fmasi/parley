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
    ///
    /// A chunked recording lists its chunks in order; a legacy dual-stream recording lists
    /// exactly [system, mic]. The distinguishing signal must NOT be "every path is .m4a":
    /// a chunk keeps its raw .wav when AAC archiving fails, and those paths are published
    /// verbatim, so a mixed list is reachable under the default config. Reading such a list
    /// as [system, mic] is exactly the #132 hazard, so any list containing an archive is
    /// treated as chunks.
    public static func classify(audioPaths: [URL]) -> AudioLayout {
        guard !audioPaths.isEmpty else { return .unavailable }

        let isArchive = { (url: URL) in url.pathExtension.lowercased() == "m4a" }

        // Any archive present => this came from the chunked pipeline. A .wav element is a chunk
        // whose archiving failed (system-only; see `isSystemOnly`), not a mic stream.
        if audioPaths.contains(where: isArchive) {
            return .chunkedArchives(audioPaths)
        }

        // All-WAV. A legacy dual-stream pair is [system.wav, <base>_mic.wav] — capture guarantees
        // that suffix. Two chunk WAVs (archiving failed for both) look identical by COUNT, and
        // reading them as [system, mic] would route a local sample to chunk 1's SYSTEM audio: the
        // user auditions "Local Speaker N" and hears the remote participants, then names them from
        // it. That is #132's exact harm, and it slips past the isSystemOnly guard in locate()
        // because that guard only runs on the .chunkedArchives branch. Key off the mic filename,
        // not the count.
        let isMicFile = { (url: URL) in url.lastPathComponent.hasSuffix("_mic.wav") }
        if audioPaths.count == 2, isMicFile(audioPaths[1]) {
            return .legacyDualStream(remote: audioPaths[0], local: audioPaths[1])
        }
        if audioPaths.count == 1, !isMicFile(audioPaths[0]) {
            return .legacyDualStream(remote: audioPaths[0], local: nil)
        }
        return .chunkedArchives(audioPaths)
    }

    /// A chunk that fell back to raw WAV carries system audio only — the mic stream is not
    /// archived — so local samples cannot be played from it.
    static func isSystemOnly(_ url: URL) -> Bool {
        url.pathExtension.lowercased() != "m4a"
    }

    /// Read each chunk's duration so absolute time can be mapped onto it.
    /// An unreadable file yields nil, which makes every LATER chunk unresolvable rather than
    /// silently shifting the timeline (a shifted timeline plays the wrong speaker).
    public static func durations(of urls: [URL]) -> [TimeInterval?] {
        urls.map { url in
            guard let file = try? AVAudioFile(forReading: url),
                  file.processingFormat.sampleRate > 0,
                  file.length > 0
            else {
                Logger.files.error("SpeakerSampleLocator: cannot read duration of \(url.lastPathComponent, privacy: .private)")
                return nil
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
        chunkDurations: [TimeInterval?],
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
            // A WAV-fallback chunk holds system audio only, so there is no mic channel to play.
            if isLocal, isSystemOnly(url) { return nil }
            return SpeakerSampleLocation(url: url, start: hit.start, end: hit.end, isLocal: isLocal)

        case .legacyDualStream(let remote, let local):
            // Each source has its own mono file on its own timeline — no chunk mapping needed.
            guard let url = isLocal ? local : remote,
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            // Duration-check: an out-of-sync legacy transcript (archiving failed mid-stream) could
            // point past the end of the audio. Return nil so the caller disables the control, rather
            // than a location that later throws emptyRange and leaves a dead play button.
            let duration = durations(of: [url]).first ?? nil
            if let duration, start >= duration { return nil }
            let capped = min(end, start + maxSampleDuration)
            guard capped > start else { return nil }
            return SpeakerSampleLocation(url: url, start: start, end: capped, isLocal: isLocal)
        }
    }
}
