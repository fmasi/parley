import Foundation
import os

/// Discovers multi-segment audio files from crash recovery.
///
/// **Legacy mode** (default): Given the base system audio path (e.g. `meeting.wav`) and mic
/// audio path, scans the same directory for `-2.wav`, `-3.wav`, … files (system-side only),
/// stopping at the first gap.  The corresponding mic path for segment N is derived as
/// `<baseName>-N_mic.wav`.  The base pair is always included regardless of whether the files
/// exist on disk.
///
/// **0-indexed mode**: If the base file name ends with `-0` (e.g. `meeting-0.wav`), the root
/// name is stripped of that suffix (→ `meeting`) and segments are scanned from index 0:
/// `meeting-0.wav`, `meeting-1.wav`, … until a gap.  The corresponding mic path for index N
/// is `meeting-N_mic.wav`.  If no files are found on disk the original pair is returned as a
/// fallback.
///
/// - Parameters:
///   - systemAudio: URL to the base system audio file (e.g. `meeting.wav` or `meeting-0.wav`).
///   - micAudio:    URL to the base mic audio file   (e.g. `meeting_mic.wav` or `meeting-0_mic.wav`).
/// - Returns: Array of `(system:, mic:)` tuples in ascending order.
public func discoverSegments(
    systemAudio: URL,
    micAudio: URL
) -> [(system: URL, mic: URL)] {
    let dir = systemAudio.deletingLastPathComponent()
    let baseName = systemAudio.deletingPathExtension().lastPathComponent

    // 0-indexed mode: base name ends with "-0"
    if baseName.hasSuffix("-0") {
        let root = String(baseName.dropLast(2)) // strip "-0"
        var segments: [(system: URL, mic: URL)] = []

        var idx = 0
        while true {
            let sysName = "\(root)-\(idx).wav"
            let micName = "\(root)-\(idx)_mic.wav"
            let sysPath = dir.appendingPathComponent(sysName)
            let micPath = dir.appendingPathComponent(micName)

            if FileManager.default.fileExists(atPath: sysPath.path) {
                segments.append((sysPath, micPath))
                idx += 1
            } else {
                break
            }
        }

        if segments.isEmpty {
            // Fallback: no files found, return original pair
            return [(systemAudio, micAudio)]
        }

        if segments.count > 1 {
            Logger.transcription.info("Discovered \(segments.count) 0-indexed audio segments for stitching")
        }

        return segments
    }

    // Legacy mode: base file + -2, -3, … suffixes
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
