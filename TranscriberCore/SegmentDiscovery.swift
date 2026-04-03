import Foundation
import os

/// Discovers multi-segment audio files from crash recovery.
///
/// Given the base (segment-1) system audio path and mic audio path, scans the
/// same directory for `-2.wav`, `-3.wav`, … files (system-side only), stopping
/// at the first gap.  The corresponding mic path for segment N is derived as
/// `<baseName>-N_mic.wav`.  The base pair is always included regardless of
/// whether the files exist on disk.
///
/// - Parameters:
///   - systemAudio: URL to the segment-1 system audio file (e.g. `meeting.wav`).
///   - micAudio:    URL to the segment-1 mic audio file   (e.g. `meeting_mic.wav`).
/// - Returns: Array of `(system:, mic:)` tuples, starting with the base pair.
public func discoverSegments(
    systemAudio: URL,
    micAudio: URL
) -> [(system: URL, mic: URL)] {
    let dir = systemAudio.deletingLastPathComponent()
    let baseName = systemAudio.deletingPathExtension().lastPathComponent

    var segments: [(system: URL, mic: URL)] = [(systemAudio, micAudio)]

    var seg = 2
    while true {
        let sysName = "\(baseName)-\(seg).wav"
        let micName = "\(baseName)-\(seg)_mic.wav"
        let sysPath = dir.appendingPathComponent(sysName)
        let micPath = dir.appendingPathComponent(micName)

        if FileManager.default.fileExists(atPath: sysPath.path) {
            segments.append((sysPath, micPath))
            seg += 1
        } else {
            break
        }
    }

    if segments.count > 1 {
        Logger.transcription.info("Discovered \(segments.count) audio segments for stitching")
    }

    return segments
}
