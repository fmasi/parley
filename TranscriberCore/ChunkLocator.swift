import Foundation

/// Maps an absolute transcript timestamp onto the chunk audio file that actually contains it.
///
/// Transcript timestamps are absolute across the whole recording, but a chunked recording
/// stores audio as N separate files laid end to end. Anything that wants to play a sample
/// must translate absolute time into (which file, offset within that file) — without this,
/// a sample from chunk 2 gets sought in chunk 1 and silently yields zero frames (#132).
public enum ChunkLocator {

    public struct Location: Equatable {
        /// Index into the ordered chunk list.
        public let index: Int
        /// Offset within that chunk, in seconds.
        public let start: TimeInterval
        public let end: TimeInterval

        public init(index: Int, start: TimeInterval, end: TimeInterval) {
            self.index = index
            self.start = start
            self.end = end
        }

        public var duration: TimeInterval { end - start }
    }

    /// Locate `start..<end` (absolute seconds) within a sequence of chunks laid end to end.
    ///
    /// The chunk holding `start` wins: a range spanning a seam is truncated at that chunk's
    /// end rather than reading past EOF. Returns nil when the range starts outside the
    /// timeline or resolves to nothing playable.
    ///
    /// A chunk whose duration is unknown (`nil` — file missing, corrupt, or evicted by the
    /// storage quota) makes every LATER position unresolvable: without its length we cannot
    /// know where the following chunks begin. We return nil rather than silently closing the
    /// gap, because a shifted timeline would confidently play the wrong speaker's voice —
    /// precisely the harm the rename dialog exists to prevent.
    ///
    /// - Parameter maxDuration: optional cap on the returned range, so callers never size a
    ///   playback buffer from an arbitrarily long diarization segment.
    ///
    /// - Parameter chunkOffsets: where the transcript placed each chunk on its wall-clock timeline
    ///   (seconds from the meeting start, `metadata.chunk_offsets`). When present and one per chunk,
    ///   they are used instead of laying chunks end to end: after a relaunch or sleep gap, chunks
    ///   are NOT contiguous, and summing durations would play the wrong audio after the gap. A time
    ///   inside a gap resolves to nothing.
    public static func locate(
        start: TimeInterval,
        end: TimeInterval,
        chunkDurations: [TimeInterval?],
        chunkOffsets: [TimeInterval]? = nil,
        maxDuration: TimeInterval? = nil
    ) -> Location? {
        guard start >= 0, end > start, !chunkDurations.isEmpty else { return nil }

        if let offsets = chunkOffsets, offsets.count == chunkDurations.count, offsets.allSatisfy(\.isFinite) {
            // The chunk with the latest offset at or before `start` (offsets may be out of list
            // order: a chunk re-indexed after a collision).
            guard let index = offsets.indices.filter({ offsets[$0] <= start }).max(by: { offsets[$0] < offsets[$1] }),
                  let duration = chunkDurations[index], duration > 0
            else { return nil }
            let localStart = start - offsets[index]
            guard localStart < duration else { return nil }   // inside a gap
            var localEnd = min(end - offsets[index], duration)
            if let maxDuration, localEnd - localStart > maxDuration {
                localEnd = localStart + maxDuration
            }
            guard localEnd > localStart else { return nil }
            return Location(index: index, start: localStart, end: localEnd)
        }

        var elapsed: TimeInterval = 0
        for (index, duration) in chunkDurations.enumerated() {
            // Unknown length: everything from here on is un-anchorable.
            guard let duration, duration > 0 else { return nil }
            let chunkEnd = elapsed + duration

            if start < chunkEnd {
                let localStart = start - elapsed
                var localEnd = min(end - elapsed, duration)
                if let maxDuration, localEnd - localStart > maxDuration {
                    localEnd = localStart + maxDuration
                }
                guard localEnd > localStart else { return nil }
                return Location(index: index, start: localStart, end: localEnd)
            }
            elapsed = chunkEnd
        }
        return nil
    }
}
