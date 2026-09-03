import Foundation
import os

/// Post-processing for a raw `DiarizationResult`, applied before segments are labeled.
public enum DiarizationCleanup {

    /// Default share of a stream's speech below which a cluster is treated as a diarization
    /// fragment rather than a participant.
    ///
    /// 5% is chosen to sit inside a measured gap, not picked round: the real fragments came in at
    /// **3.5%** and **2.1%**, the real second speaker at **40%**. Anything from ~4% to ~35% would
    /// separate the observed cases; 5% keeps margin above the largest observed fragment while
    /// staying an order of magnitude below the smallest observed real participant.
    public static let defaultMinShare = 0.05

    /// A cluster must hold at least this share of the stream before anything is absorbed INTO it.
    /// Without it, a room of quiet speakers — thirty people at 1.5% each — would all qualify as
    /// fragments and collapse into whoever happened to be longest.
    public static let dominanceShare = 0.5

    /// Absorb clusters holding a negligible share of the stream's speech into the dominant cluster.
    ///
    /// Two device recordings bound this rule, and **only share of speech separates them**:
    ///
    /// | recording | clusters | small cluster's share | cosine between them | correct action |
    /// |---|---|---|---|---|
    /// | 2026-08-26 remote, one person | 766s + 28s | 3.5% | 0.4030 | absorb |
    /// | 2026-08-26 remote, one person | 559s + 12s | 2.1% | 0.2784 | absorb |
    /// | 2026-09-02 local, speakerphone | 312s + 211s | 40% | 0.3987 | keep |
    ///
    /// A similarity threshold cannot tell 0.4030 from 0.3987 — the spurious pair and the two real
    /// people sit at the same cosine, because a short utterance produces an unreliable embedding
    /// that lands as far from its own speaker as a different speaker would. Duration is the signal
    /// that survives.
    ///
    /// Known residual risk: a genuine participant who speaks only briefly in a meeting otherwise
    /// dominated by one person is indistinguishable from a fragment by this rule and will be
    /// absorbed. That is why `minShare: nil` exists — when the user states the speaker count, their
    /// answer wins and no absorption runs at all.
    ///
    /// - Parameters:
    ///   - result: raw diarization output.
    ///   - minShare: share of total speech below which a cluster is absorbed; `nil` disables
    ///     absorption entirely (the user stated how many speakers there are).
    public static func absorbMinorityClusters(
        _ result: DiarizationResult,
        minShare: Double? = defaultMinShare
    ) -> DiarizationResult {
        guard let minShare, !result.segments.isEmpty else { return result }

        var speech: [String: Double] = [:]
        for s in result.segments { speech[s.speaker, default: 0] += s.end - s.start }
        guard speech.count > 1 else { return result }

        let total = speech.values.reduce(0, +)
        guard total > 0 else { return result }

        guard let dominant = speech.max(by: { $0.value < $1.value }),
              dominant.value / total >= dominanceShare
        else { return result }

        let absorbed = Set(speech.filter { $0.key != dominant.key && $0.value / total < minShare }.keys)
        guard !absorbed.isEmpty else { return result }

        Logger.transcription.info(
            "DiarizationCleanup: absorbed \(absorbed.count, privacy: .public) minority cluster(s) into the dominant speaker (each under \(Int(minShare * 100), privacy: .public)% of \(String(format: "%.1f", total), privacy: .public)s of speech)"
        )

        let segments = result.segments.map { seg in
            absorbed.contains(seg.speaker)
                ? DiarizedSegment(start: seg.start, end: seg.end, speaker: dominant.key, qualityScore: seg.qualityScore)
                : seg
        }
        let database = result.speakerDatabase.filter { !absorbed.contains($0.key) }
        return DiarizationResult(segments: segments, speakerDatabase: database)
    }
}
