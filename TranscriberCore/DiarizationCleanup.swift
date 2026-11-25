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

    /// The point past which this knob stops describing fragments and starts deleting people.
    ///
    /// Absorption only runs when some cluster holds >= `dominanceShare`, so every other cluster
    /// shares less than half the stream between them. A five-way meeting with one dominant speaker
    /// leaves the rest around 12% each; the smallest real participant observed on device was 40%.
    /// A threshold above half of what the non-dominant speakers can hold is therefore absorbing the
    /// median other participant, not a fragment — no configured value should be allowed there.
    public static let maxSensibleShare = dominanceShare / 2

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
        absorbMinorityClustersCounting(result, minShare: minShare).0
    }

    /// `absorbMinorityClusters`, also returning how many clusters were absorbed — so the record can
    /// say a quiet voice was merged into the main speaker (`clusters_absorbed`, P7) rather than the
    /// merge being invisible.
    ///
    /// - Parameter keeping: clusters (the diarizer's own IDs) the echo check judged to be the other
    ///   side's voice through the loudspeakers (#249). A kept cluster is never absorbed and nothing is
    ///   absorbed into it: when it holds the most speech no person on this channel is dominant, and
    ///   nothing is absorbed at all. It still counts in the total, as the sound on this channel it is,
    ///   so a kept cluster never makes absorption take a cluster it would leave alone without one. An
    ///   ID that names no cluster is ignored.
    public static func absorbMinorityClustersCounting(
        _ result: DiarizationResult,
        minShare: Double? = defaultMinShare,
        keeping: Set<String> = []
    ) -> (DiarizationResult, absorbed: Int) {
        guard let absorption = plan(result, minShare: minShare, keeping: keeping) else { return (result, 0) }
        let absorbed = absorption.absorbed

        Logger.transcription.info(
            "DiarizationCleanup: absorbed \(absorbed.count, privacy: .public) minority cluster(s) into the dominant speaker (each under \(Int((minShare ?? 0) * 100), privacy: .public)% of \(String(format: "%.1f", absorption.total), privacy: .public)s of speech), \(keeping.intersection(absorption.clusters).count, privacy: .public) cluster(s) judged echo left as they are"
        )

        let segments = result.segments.map { seg in
            absorbed.contains(seg.speaker)
                ? DiarizedSegment(start: seg.start, end: seg.end, speaker: absorption.dominant, qualityScore: seg.qualityScore)
                : seg
        }
        let database = result.speakerDatabase.filter { !absorbed.contains($0.key) }
        return (DiarizationResult(segments: segments, speakerDatabase: database), absorbed.count)
    }

    /// The clusters `absorbMinorityClustersCounting` would absorb, absorbing nothing: empty when it
    /// would leave the result as it is. With no clusters kept, the only clusters a kept one could
    /// change the fate of (#249) — so the echo check before absorption only runs when this is not empty.
    public static func minorityClusters(
        _ result: DiarizationResult,
        minShare: Double? = defaultMinShare,
        keeping: Set<String> = []
    ) -> Set<String> {
        plan(result, minShare: minShare, keeping: keeping)?.absorbed ?? []
    }

    /// What absorption would do: the dominant cluster, the clusters absorbed into it, the stream's
    /// total speech and every cluster in it. nil when nothing would be absorbed.
    private static func plan(
        _ result: DiarizationResult, minShare: Double?, keeping: Set<String>
    ) -> (dominant: String, absorbed: Set<String>, total: Double, clusters: Set<String>)? {
        guard let minShare, !result.segments.isEmpty else { return nil }

        var speech: [String: Double] = [:]
        for s in result.segments { speech[s.speaker, default: 0] += s.end - s.start }
        guard speech.count > 1 else { return nil }

        let total = speech.values.reduce(0, +)
        guard total > 0 else { return nil }

        // The dominant cluster is a PERSON: a kept cluster is never a target. When a kept cluster
        // holds the most speech, no other can hold half of it, and nothing is absorbed.
        guard let dominant = speech.filter({ !keeping.contains($0.key) }).max(by: { $0.value < $1.value }),
              dominant.value / total >= dominanceShare
        else { return nil }

        let absorbed = Set(speech.filter {
            $0.key != dominant.key && !keeping.contains($0.key) && $0.value / total < minShare
        }.keys)
        guard !absorbed.isEmpty else { return nil }
        return (dominant.key, absorbed, total, Set(speech.keys))
    }
}
