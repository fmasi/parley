import Foundation

/// Turns reconciled, per-chunk speaker identities into readable, deduplicated
/// display labels ("Local Speaker N" / "Remote Speaker N").
///
/// Reconciliation runs in two separate pools — local (mic) and remote (system) —
/// so a local speaker is never merged with a remote one even if their embeddings
/// happen to match. Display numbers are assigned per source in order of first
/// appearance across the time-sorted segments, producing stable labels.
public enum SpeakerLabeler {

    /// Strip a "Local "/"Remote " source prefix to recover the bare diarizer
    /// label ("Speaker 1") used as the reconciliation map key. Bare labels and
    /// "Unknown" pass through unchanged.
    static func bareLabel(_ speaker: String) -> String {
        if speaker.hasPrefix("Local ") {
            return String(speaker.dropFirst("Local ".count))
        }
        if speaker.hasPrefix("Remote ") {
            return String(speaker.dropFirst("Remote ".count))
        }
        return speaker
    }

    /// Build the final, display-named, time-sorted segments for a chunked session.
    ///
    /// - Parameters:
    ///   - chunks: All processed chunks (any order; sorted internally).
    ///   - meetingStart: Wall-clock start used to convert chunk-relative offsets
    ///     to absolute elapsed times.
    ///   - threshold: Cosine similarity threshold for reconciliation (default 0.65).
    ///   - emaAlpha: EMA weight for reference-embedding updates during reconciliation (default 0.9).
    /// - Returns: Time-sorted `LabeledSegment`s with final display speaker names.
    public static func label(
        chunks: [ProcessedChunk],
        meetingStart: Date,
        threshold: Float = 0.65,
        emaAlpha: Float = 0.9
    ) -> [LabeledSegment] {

        // 1. Reconcile each pool independently.
        let remoteMapping = SpeakerReconciler.reconcile(
            databases: chunks.map { (chunkIndex: $0.index, database: $0.speakerDatabase) },
            threshold: threshold,
            emaAlpha: emaAlpha
        )
        let localMapping = SpeakerReconciler.reconcile(
            databases: chunks.map { (chunkIndex: $0.index, database: $0.localSpeakerDatabase) },
            threshold: threshold,
            emaAlpha: emaAlpha
        )

        // 2. Flatten chunks → segments carrying an opaque global identity.
        //    The identity is namespaced by source so the local pool's "spk_0"
        //    can never collide with the remote pool's "spk_0".
        struct IdentifiedSegment {
            let start: Double
            let end: Double
            let text: String
            let source: String
            let confidence: Float?
            let identity: String? // nil for Unknown / bare passthroughs
        }

        var identified: [IdentifiedSegment] = []
        for chunk in chunks.sorted(by: { $0.index < $1.index }) {
            let chunkOffset = chunk.startTime.timeIntervalSince(meetingStart)

            for seg in chunk.segments {
                let isLocal = seg.source == "local"
                let chunkMapping = (isLocal ? localMapping : remoteMapping)[chunk.index] ?? [:]

                let bare = bareLabel(seg.speaker)
                let identity: String?
                if bare == "Unknown" || bare.isEmpty {
                    identity = nil
                } else if let global = chunkMapping[bare] {
                    // Namespace by source so pools never merge.
                    identity = "\(seg.source)#\(global)"
                } else {
                    // No reconciliation entry — keep this segment's own label as a
                    // stable per-source identity so it still groups by itself.
                    identity = "\(seg.source)#raw#\(chunk.index)#\(bare)"
                }

                identified.append(IdentifiedSegment(
                    start: chunkOffset + seg.start,
                    end: chunkOffset + seg.end,
                    text: seg.text,
                    source: seg.source,
                    confidence: seg.qualityScore,
                    identity: identity
                ))
            }
        }

        identified.sort { $0.start < $1.start }

        // 3. Assign display numbers per source in order of first appearance.
        var counters: [String: Int] = [:]               // source → next number
        var displayNames: [String: String] = [:]         // (source#identity) → label

        func displayName(source: String, identity: String?) -> String {
            let prefix = source == "local" ? "Local" : "Remote"
            guard let identity else { return "Unknown" }
            let key = "\(source)\u{1}\(identity)"
            if let existing = displayNames[key] { return existing }
            let n = (counters[source] ?? 0) + 1
            counters[source] = n
            let label = "\(prefix) Speaker \(n)"
            displayNames[key] = label
            return label
        }

        return identified.map { seg in
            LabeledSegment(
                start: seg.start,
                end: seg.end,
                speaker: displayName(source: seg.source, identity: seg.identity),
                text: seg.text,
                source: seg.source,
                confidence: seg.confidence
            )
        }
    }
}
