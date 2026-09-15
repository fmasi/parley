import Foundation
import os

/// Makes a user-stated speaker count binding on a diarization result (#201).
///
/// Why this is needed at all: forcing the count at the diarizer does not force it. The count
/// reaches FluidAudio as `clustering.maxSpeakers`, which the clusterer treats as a target rather
/// than a ceiling — it was validated at 2, 3 and 4 and never at 1. And stating a count sets
/// `speakerCountIsUserStated`, which switches `DiarizationCleanup.absorbMinorityClusters` off,
/// on the reasoning that a share-based heuristic should not second-guess an explicit answer.
/// Together those left the one case the control exists for — "there was only ever one person on
/// this channel" — with nothing enforcing it: on an 82-minute call, asking for 1 returned 2.
///
/// So the answer is enforced here instead, deterministically and after the fact. Absorption stays
/// disabled: its job (guessing which clusters are fragments) is precisely what the user has just
/// done for us, and a rule that can delete a real participant has no business running alongside a
/// stated count.
///
/// This only ever MERGES. There is no way to split a cluster after the fact, so asking for more
/// speakers than the diarizer found is a no-op — the diarizer's own forced count is the only lever
/// in that direction.
public enum SpeakerCountEnforcer {

    /// Merge clusters until exactly `speakerCount` remain, relabeling the merged turns.
    ///
    /// Each round takes the cluster holding the LEAST speech and folds it into whichever surviving
    /// cluster it sounds most like, by cosine similarity over the speaker embeddings the result
    /// already carries. Smallest-first because a short cluster is the one whose separation the
    /// diarizer was least sure about; nearest-by-embedding because, having decided a merge must
    /// happen, the least damaging destination is the voice it most resembles — not simply the
    /// loudest person in the room.
    ///
    /// Without embeddings there is no "nearest", so the fallback is the dominant cluster (most
    /// speech). That is the same destination `DiarizationCleanup` uses, and for the same reason:
    /// duration is the signal that survives when embeddings are missing or unreliable.
    ///
    /// - Parameters:
    ///   - result: raw diarization output.
    ///   - speakerCount: the number of speakers the user stated. `<= 0` is a no-op — the caller
    ///     already refuses it, and returning an empty or arbitrary labeling here would turn a bad
    ///     argument into a rewritten transcript.
    public static func enforce(_ result: DiarizationResult, to speakerCount: Int) -> DiarizationResult {
        guard speakerCount > 0, !result.segments.isEmpty else { return result }

        // First-appearance order is carried alongside the durations so that ties resolve the same
        // way on every run. A re-detect that returned a different answer each press would be
        // indistinguishable from the bug this fixes.
        var order: [String] = []
        var speech: [String: Double] = [:]
        for s in result.segments {
            if speech[s.speaker] == nil { order.append(s.speaker) }
            speech[s.speaker, default: 0] += max(0, s.end - s.start)
        }
        guard speech.count > speakerCount else { return result }

        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        var embeddings = result.speakerDatabase
        var live = order
        // Original label -> the label it currently resolves to. Rewriting the whole map on each
        // merge (rather than recording victim -> target once) keeps chains correct: when a cluster
        // that has already absorbed another is itself absorbed, both move together.
        var resolved = Dictionary(uniqueKeysWithValues: order.map { ($0, $0) })

        while live.count > speakerCount {
            // `live` cannot be empty here (the loop runs only while `live.count > speakerCount`,
            // and speakerCount >= 1), but a bare `!` in release code makes a reader stop and prove
            // that for themselves. Break instead — an unreachable branch that degrades to "leave
            // the clusters alone" rather than to a crash.
            guard let victim = live.min(by: { a, b in
                let da = speech[a] ?? 0, db = speech[b] ?? 0
                return da == db ? (rank[a] ?? 0) < (rank[b] ?? 0) : da < db
            }) else { break }
            let candidates = live.filter { $0 != victim }
            let target = destination(
                for: victim, among: candidates, embeddings: embeddings, speech: speech, rank: rank)

            for (original, current) in resolved where current == victim { resolved[original] = target }
            speech[target, default: 0] += speech[victim] ?? 0
            speech[victim] = nil
            // The surviving cluster keeps its own embedding rather than a blend: it is the longer,
            // better-estimated voice, and averaging in a fragment's unreliable embedding would drag
            // the reference toward a vector the diarizer itself could not place.
            embeddings[victim] = nil
            live.removeAll { $0 == victim }
        }

        let absorbed = Set(resolved.filter { $0.key != $0.value }.keys)
        guard !absorbed.isEmpty else { return result }

        Logger.transcription.info(
            "SpeakerCountEnforcer: merged \(absorbed.count, privacy: .public) cluster(s) to honour the stated count of \(speakerCount, privacy: .public) (diarizer returned \(order.count, privacy: .public))"
        )

        let segments = result.segments.map { seg -> DiarizedSegment in
            guard let target = resolved[seg.speaker], target != seg.speaker else { return seg }
            return DiarizedSegment(
                start: seg.start, end: seg.end, speaker: target, qualityScore: seg.qualityScore)
        }
        return DiarizationResult(
            segments: segments,
            speakerDatabase: result.speakerDatabase.filter { !absorbed.contains($0.key) })
    }

    /// Fold segments the assigner could not attribute ("Unknown") into the stated speaker.
    ///
    /// `SpeakerAssignment` labels a segment "Unknown" when it overlaps no diarization turn, or when
    /// the VAD quality gate rejects the overlap it found. That is an *absence of attribution*, not a
    /// person — but it reaches the rename dialog as a row of its own, so a user who answered "1
    /// speaker" is shown two speakers and reasonably concludes the answer was ignored. Device-observed
    /// on an 82-minute call: one real cluster plus 113s of "Right." / "Oui." backchannels.
    ///
    /// Only safe at a stated count of 1, where the attribution is unambiguous: if one person is on
    /// this channel, every word on it is theirs. At 2+ we genuinely cannot say which of them spoke,
    /// and inventing an answer is the silent-wrong-answer failure this product exists to avoid.
    public static func foldUnattributed(_ labeled: [LabeledSegment], statedCount: Int) -> [LabeledSegment] {
        guard statedCount == 1 else { return labeled }
        let named = labeled.map(\.speaker).filter { $0 != SpeakerAssignment.unknownSpeaker }
        // No attributed speaker at all: name the channel's single speaker rather than leaving every
        // segment under a label that reads as a failure.
        // "Speaker 1" is load-bearing, not arbitrary: `tagWithSourcePrefix` turns it into
        // "Local Speaker 1" / "Remote Speaker 1", the same shape the rename dialog and
        // `speaker_names` expect. A different string here would render as a speaker the rest of the
        // pipeline does not recognise.
        let target = named.first ?? "Speaker 1"
        guard labeled.contains(where: { $0.speaker == SpeakerAssignment.unknownSpeaker }) else { return labeled }
        var out = labeled
        for i in out.indices where out[i].speaker == SpeakerAssignment.unknownSpeaker {
            out[i].speaker = target
        }
        return out
    }

    /// The surviving cluster a doomed one should join.
    private static func destination(
        for victim: String,
        among candidates: [String],
        embeddings: [String: [Float]],
        speech: [String: Double],
        rank: [String: Int]
    ) -> String {
        // Same reasoning as the `victim` guard: `candidates` is `live` minus one element and cannot
        // be empty, but returning the victim unchanged is a survivable answer where a crash is not.
        guard let dominant = candidates.max(by: { a, b in
            let da = speech[a] ?? 0, db = speech[b] ?? 0
            return da == db ? (rank[a] ?? 0) > (rank[b] ?? 0) : da < db
        }) else { return victim }

        guard let victimEmbedding = embeddings[victim], !victimEmbedding.isEmpty else {
            return dominant
        }
        let scored = candidates.compactMap { candidate -> (String, Float)? in
            guard let e = embeddings[candidate], !e.isEmpty else { return nil }
            return (candidate, SpeakerReconciler.cosineSimilarity(victimEmbedding, e))
        }
        guard let best = scored.max(by: { a, b in
            a.1 == b.1 ? (rank[a.0] ?? 0) > (rank[b.0] ?? 0) : a.1 < b.1
        }) else { return dominant }
        return best.0
    }
}
