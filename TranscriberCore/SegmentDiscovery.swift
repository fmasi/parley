import Foundation
import os

/// Discovers multi-segment audio files from crash recovery.
///
/// Both modes are **gap-tolerant**: every matching segment present on disk is included even
/// when the index sequence has a hole (e.g. `-0` and `-2` with no `-1`). Crash recovery can
/// skip an index, and silently truncating at the first gap drops real recorded audio (#84) —
/// timestamps are absolute, so a missing middle segment is harmless to the merge.
///
/// **Legacy mode** (default): Given the base system audio path (e.g. `meeting.wav`), the base
/// pair is always returned first (regardless of whether it exists on disk), followed by every
/// `meeting-N.wav` with `N >= 2` found in the same directory, in ascending order. The mic path
/// for segment N is derived as `<baseName>-N_mic.wav`.
///
/// **0-indexed mode**: If the base file name ends with `-0` (e.g. `meeting-0.wav`), the root is
/// stripped of that suffix (→ `meeting`) and every `meeting-N.wav` with `N >= 0` found on disk
/// is returned in ascending order. If none are found the original pair is returned as a fallback.
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
    let zeroIndexed = baseName.hasSuffix("-0")
    let root = zeroIndexed ? String(baseName.dropLast(2)) : baseName

    // Enumerate all system-side segment files `<root>-<N>.wav` present in the directory.
    // Gap-tolerant: collect indices from the listing rather than scanning until a hole.
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    let prefix = "\(root)-"
    var indices: [Int] = []
    for name in entries {
        guard name.hasSuffix(".wav"), !name.hasSuffix("_mic.wav") else { continue }
        let stem = String(name.dropLast(4)) // drop ".wav"
        guard stem.hasPrefix(prefix), let idx = Int(stem.dropFirst(prefix.count)) else { continue }
        indices.append(idx)
    }
    indices.sort()

    func pair(_ idx: Int) -> (system: URL, mic: URL) {
        (dir.appendingPathComponent("\(root)-\(idx).wav"),
         dir.appendingPathComponent("\(root)-\(idx)_mic.wav"))
    }

    // Observability (#89): record the recovery path and the raw discovery before any filtering.
    let mode = zeroIndexed ? "0-indexed" : "legacy"
    Logger.transcription.debug(
        "SegmentDiscovery: base=\(baseName, privacy: .private) root=\(root, privacy: .private) mode=\(mode, privacy: .public) suffixed-indices=[\(indices.map(String.init).joined(separator: ","), privacy: .public)]"
    )

    var segments: [(system: URL, mic: URL)]
    if zeroIndexed {
        segments = indices.map(pair)
        if segments.isEmpty {
            // Fallback: nothing on disk, return the original pair.
            Logger.transcription.warning(
                "SegmentDiscovery: 0-indexed mode found no \(root, privacy: .private)-N.wav on disk; falling back to the original pair"
            )
            return [(systemAudio, micAudio)]
        }
    } else {
        // Legacy naming: base is segment "1" (always included); suffixed segments start at -2 (never -1).
        // A `<root>-1.wav` should never exist (numbering jumps base → -2). If one ever appears it would
        // be filtered out silently — counter to the never-silently-lose-audio principle — so warn (#89).
        if indices.contains(1) {
            Logger.transcription.warning(
                "SegmentDiscovery: legacy mode found unexpected \(root, privacy: .private)-1.wav; legacy numbering jumps base → -2, so this file is being dropped (possible numbering bug)"
            )
        }
        segments = [(systemAudio, micAudio)] + indices.filter { $0 >= 2 }.map(pair)
    }

    // Surface gaps in the discovered index sequence. Discovery is gap-tolerant (a missing middle
    // segment is harmless given absolute timestamps), but a hole is worth recording during a
    // crash-recovery investigation (#89).
    if let lo = indices.first, let hi = indices.last {
        let present = Set(indices)
        let missing = (lo...hi).filter { !present.contains($0) }
        if !missing.isEmpty {
            Logger.transcription.info(
                "SegmentDiscovery: gap(s) in segment indices, missing [\(missing.map(String.init).joined(separator: ","), privacy: .public)] (gap-tolerant, remaining segments still stitched)"
            )
        }
    }

    if segments.count > 1 {
        let ordered = segments.map { $0.system.lastPathComponent }.joined(separator: ", ")
        Logger.transcription.info(
            "Discovered \(segments.count) audio segments for stitching (\(mode, privacy: .public) mode): \(ordered, privacy: .private)"
        )
    }

    return segments
}

/// Repairs the WAV headers of every discovered segment in place, so a segment whose writer
/// was killed mid-recording (header underreports its payload) is decodable before transcription.
///
/// This complements `discoverSegments`: the chunked `ChunkProcessor` path already repairs each
/// chunk, but the single-file / crash-recovery / CLI path goes through `TranscriptionRunner.run`
/// and previously never repaired, leaving orphaned segments unreadable (#85). Repair is a no-op
/// for already-consistent files.
///
/// - Returns: the number of files whose header was rewritten.
@discardableResult
public func repairSegmentHeaders(_ segments: [(system: URL, mic: URL)]) -> Int {
    var repaired = 0
    for segment in segments {
        if WavFileWriter.repairHeader(path: segment.system.path) { repaired += 1 }
        if WavFileWriter.repairHeader(path: segment.mic.path) { repaired += 1 }
    }
    return repaired
}
