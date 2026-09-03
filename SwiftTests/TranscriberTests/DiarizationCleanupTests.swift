import Testing
import Foundation
@testable import TranscriberCore

/// Guards the share-of-speech absorption rule (#65).
///
/// Two device recordings define the boundary this rule has to sit between, and they are only
/// separable by SHARE OF SPEECH — not by embedding similarity:
///
///   2026-08-26, remote channel, ONE person: the clusterer split him into 766s + 28s (3.5%) in one
///     chunk and 559s + 12s (2.1%) in the next. Cosine between the spurious pair: 0.4030.
///   2026-09-02, local channel, TWO people on a speakerphone: 312s + 211s (40%). Cosine between the
///     two genuinely different people: 0.3987.
///
/// A similarity threshold cannot tell 0.4030 from 0.3987. Share of speech tells 3.5% from 40%.
@Suite("DiarizationCleanup")
struct DiarizationCleanupTests {

    /// Build a result whose speakers hold the given durations, laid end to end.
    private func result(_ durations: [(String, Double)], embeddingDim: Int = 256) -> DiarizationResult {
        var segments: [DiarizedSegment] = []
        var db: [String: [Float]] = [:]
        var t = 0.0
        for (idx, pair) in durations.enumerated() {
            segments.append(DiarizedSegment(start: t, end: t + pair.1, speaker: pair.0, qualityScore: 1.0))
            t += pair.1
            var emb = [Float](repeating: 0, count: embeddingDim)
            emb[idx % embeddingDim] = 1.0
            db[pair.0] = emb
        }
        return DiarizationResult(segments: segments, speakerDatabase: db)
    }

    private func durations(_ r: DiarizationResult) -> [String: Double] {
        var d: [String: Double] = [:]
        for s in r.segments { d[s.speaker, default: 0] += s.end - s.start }
        return d
    }

    // MARK: - The two device cases

    @Test("absorbs the 3.5% spurious cluster measured on 2026-08-26 chunk 0")
    func absorbsSpuriousClusterFromRealOverSplit() {
        let cleaned = DiarizationCleanup.absorbMinorityClusters(result([("S2", 766), ("S1", 28)]))
        let d = durations(cleaned)
        #expect(d.count == 1)
        #expect(d["S2"] == 794)
        #expect(cleaned.speakerDatabase.keys.sorted() == ["S2"])
    }

    @Test("absorbs the 2.1% spurious cluster measured on 2026-08-26 chunk 1")
    func absorbsSpuriousClusterFromRealOverSplitSecondChunk() {
        let cleaned = DiarizationCleanup.absorbMinorityClusters(result([("S1", 559), ("S2", 12)]))
        #expect(durations(cleaned).count == 1)
        #expect(durations(cleaned)["S1"] == 571)
    }

    @Test("keeps both speakers of the 2026-09-02 speakerphone call — 40% is not a fragment")
    func keepsGenuineSecondSpeaker() {
        let cleaned = DiarizationCleanup.absorbMinorityClusters(result([("S1", 312), ("S2", 211)]))
        let d = durations(cleaned)
        #expect(d.count == 2)
        #expect(d["S1"] == 312)
        #expect(d["S2"] == 211)
        #expect(cleaned.speakerDatabase.keys.sorted() == ["S1", "S2"])
    }

    // MARK: - Guards

    @Test("a balanced multi-party meeting is never touched")
    func fourWayMeetingSurvives() {
        let cleaned = DiarizationCleanup.absorbMinorityClusters(
            result([("S1", 400), ("S2", 300), ("S3", 250), ("S4", 200)]))
        #expect(durations(cleaned).count == 4)
    }

    @Test("never absorbs when no single cluster dominates the stream")
    func noDominantClusterMeansNoAbsorption() {
        // Ten speakers at ~10% each: every one is small, none dominates. Absorbing here would
        // collapse a real conference call into one person.
        let even = (1...10).map { ("S\($0)", 100.0) }
        #expect(durations(DiarizationCleanup.absorbMinorityClusters(result(even))).count == 10)
    }

    @Test("a single-speaker result passes through unchanged")
    func singleSpeakerUntouched() {
        let cleaned = DiarizationCleanup.absorbMinorityClusters(result([("S1", 600)]))
        #expect(durations(cleaned) == ["S1": 600])
    }

    @Test("an empty result passes through unchanged")
    func emptyResultUntouched() {
        let cleaned = DiarizationCleanup.absorbMinorityClusters(DiarizationResult(segments: []))
        #expect(cleaned.segments.isEmpty)
    }

    @Test("absorbed segments keep their timing — only the speaker label changes")
    func absorptionPreservesSegmentTiming() {
        let original = result([("S2", 766), ("S1", 28)])
        let cleaned = DiarizationCleanup.absorbMinorityClusters(original)
        #expect(cleaned.segments.count == original.segments.count)
        for (a, b) in zip(original.segments.sorted { $0.start < $1.start },
                          cleaned.segments.sorted { $0.start < $1.start }) {
            #expect(a.start == b.start)
            #expect(a.end == b.end)
        }
    }

    @Test("the absorbed speaker's embedding is dropped so the reconciler cannot carry it forward")
    func absorbedEmbeddingIsRemoved() {
        let cleaned = DiarizationCleanup.absorbMinorityClusters(result([("S2", 766), ("S1", 28)]))
        #expect(cleaned.speakerDatabase["S1"] == nil)
        #expect(cleaned.speakerDatabase["S2"] != nil)
    }

    @Test("absorption is disabled when the user has stated the speaker count")
    func explicitSpeakerCountDisablesAbsorption() {
        // The user said "2 people". A 3.5% second cluster is then their call, not ours to erase.
        let cleaned = DiarizationCleanup.absorbMinorityClusters(
            result([("S2", 766), ("S1", 28)]), minShare: nil)
        #expect(durations(cleaned).count == 2)
    }

    @Test("absorbs every minority cluster in a single pass, not just the smallest")
    func absorbsMultipleMinorityClusters() {
        // S1=80%, S2=3%, S3=2%. Both fragments must vanish in one call. Every other test here has
        // exactly one minority cluster, so a change that absorbed one per call — or stopped at the
        // first hit — would pass the whole suite.
        let cleaned = DiarizationCleanup.absorbMinorityClusters(
            result([("S1", 800), ("S2", 30), ("S3", 20)]))
        #expect(durations(cleaned).count == 1)
        #expect(durations(cleaned)["S1"] == 850)
        #expect(cleaned.speakerDatabase.keys.sorted() == ["S1"])
    }

    @Test("a cluster at exactly the threshold is KEPT — the comparison is strict")
    func clusterExactlyAtThresholdIsKept() {
        // 5% of 600s is 30s. Pinning the boundary matters because the two device cases sit either
        // side of it (3.5% absorbed, 40% kept) and neither exercises equality.
        let cleaned = DiarizationCleanup.absorbMinorityClusters(result([("S1", 570), ("S2", 30)]))
        #expect(durations(cleaned).count == 2)
    }

    @Test("a cluster just below the threshold is absorbed")
    func clusterJustBelowThresholdIsAbsorbed() {
        let cleaned = DiarizationCleanup.absorbMinorityClusters(result([("S1", 571), ("S2", 29)]))
        #expect(durations(cleaned).count == 1)
    }

    @Test("share is measured against total speech, not wall-clock duration")
    func shareIgnoresSilenceBetweenSegments() {
        // 28s out of 794s of SPEECH is 3.5% and must be absorbed, even though the recording
        // is an hour long with most of it silent.
        var segs = [DiarizedSegment(start: 0, end: 766, speaker: "S2", qualityScore: 1.0)]
        segs.append(DiarizedSegment(start: 3000, end: 3028, speaker: "S1", qualityScore: 1.0))
        let cleaned = DiarizationCleanup.absorbMinorityClusters(
            DiarizationResult(segments: segs, speakerDatabase: ["S1": [1, 0], "S2": [0, 1]]))
        #expect(durations(cleaned).count == 1)
    }
}

/// The absorption threshold is a tuning knob with real failure modes in both directions, so it is
/// reachable from config.json like the other diarizer knobs (`diarization_clustering_threshold`,
/// `diarization_max_speakers`) rather than being a constant only a rebuild can change.
@Suite("DiarizationCleanup config")
struct DiarizationCleanupConfigTests {

    @Test("an unset min-speaker-share resolves to the shipping default")
    func unsetResolvesToDefault() throws {
        let json = #"{"recording_directory":"/tmp","silence_timeout_minutes":5,"silence_detection_enabled":true,"output_format":"json","launch_on_startup":false,"suppress_capture_warning":false,"engine":"fluid_audio","system_audio_source":"sck","archive_bitrate_kbps":64,"audio_archive_limit_hours":37,"chunk_duration_minutes":30,"chunk_processing_qos":"utility","merge_chunked_audio":false,"model_update_check_enabled":true,"calendar_lookahead_minutes":10}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.diarizationMinSpeakerShare == nil)
        #expect(config.resolvedDiarizationMinSpeakerShare == DiarizationCleanup.defaultMinShare)
    }

    @Test("an explicit min-speaker-share is honoured")
    func explicitValueIsHonoured() throws {
        let json = #"{"recording_directory":"/tmp","silence_timeout_minutes":5,"silence_detection_enabled":true,"output_format":"json","launch_on_startup":false,"suppress_capture_warning":false,"engine":"fluid_audio","system_audio_source":"sck","archive_bitrate_kbps":64,"audio_archive_limit_hours":37,"chunk_duration_minutes":30,"chunk_processing_qos":"utility","merge_chunked_audio":false,"model_update_check_enabled":true,"calendar_lookahead_minutes":10,"diarization_min_speaker_share":0.1}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.resolvedDiarizationMinSpeakerShare == 0.1)
    }

    @Test("zero disables absorption entirely rather than absorbing nothing by accident")
    func zeroDisablesAbsorption() throws {
        let json = #"{"recording_directory":"/tmp","silence_timeout_minutes":5,"silence_detection_enabled":true,"output_format":"json","launch_on_startup":false,"suppress_capture_warning":false,"engine":"fluid_audio","system_audio_source":"sck","archive_bitrate_kbps":64,"audio_archive_limit_hours":37,"chunk_duration_minutes":30,"chunk_processing_qos":"utility","merge_chunked_audio":false,"model_update_check_enabled":true,"calendar_lookahead_minutes":10,"diarization_min_speaker_share":0}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.resolvedDiarizationMinSpeakerShare == nil)
    }
}
