import Testing
import Foundation
@testable import TranscriberCore

/// `CaptureProvenance` is persisted inside `session.json`, and `ChunkSession.read()` decodes it with
/// `try?` — so ONE throwing field turns the whole session into "corrupt" and drops it. During crash
/// recovery that is an in-progress recording lost.
///
/// Adding a non-optional `Int` to a persisted Codable struct is therefore a data-loss change unless
/// it decodes tolerantly. These tests pin that: every field added after the original shape must
/// survive its own absence.
@Suite struct ProvenanceCompatTests {

    private func decode(_ json: [String: Any]) throws -> CaptureProvenance {
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(CaptureProvenance.self, from: data)
    }

    /// THE REGRESSION: a session.json written by a build that predates `quality_anomaly_count`.
    @Test func legacyProvenanceWithoutQualityCountStillDecodes() throws {
        let provenance = try decode([
            "engine": "fluid_audio",
            "route_changes": 1,
            "retries": 0,
            "recovered": false,
            "anomaly_count": 2,
            // no quality_anomaly_count, no system_audio_unrecovered — this is the old shape
        ])
        #expect(provenance.qualityAnomalyCount == 0)
        #expect(provenance.systemAudioUnrecovered == false)
        #expect(provenance.anomalyCount == 2)
        #expect(provenance.engine == "fluid_audio")
    }

    /// The oldest shape of all: before `system_audio_unrecovered` existed either. This was already
    /// latent before this PR — the same hazard, never exercised.
    @Test func oldestProvenanceShapeDecodes() throws {
        let provenance = try decode([
            "engine": "speech_analyzer",
            "route_changes": 0,
            "retries": 0,
            "recovered": true,
            "anomaly_count": 0,
        ])
        #expect(provenance.qualityAnomalyCount == 0)
        #expect(provenance.systemAudioUnrecovered == false)
    }

    @Test func currentShapeRoundTrips() throws {
        let original = CaptureProvenance(
            engine: "fluid_audio",
            systemFormat: "48000Hz/1ch",
            micFormat: "48000Hz/1ch",
            micDevice: "built-in",
            routeChanges: 2,
            retries: 1,
            recovered: true,
            anomalyCount: 3,
            qualityAnomalyCount: 1,
            systemAudioUnrecovered: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CaptureProvenance.self, from: data)
        #expect(decoded == original)
    }

    /// A whole legacy `SessionState` must survive — this is the path crash recovery actually takes,
    /// and the one that matters: `ChunkSession.read()` drops the session on ANY decode failure, so
    /// asserting only that the inner type tolerates the missing key would prove the wrong thing.
    @Test func legacySessionStateWithOldProvenanceSurvives() throws {
        let json: [String: Any] = [
            "sessionId": "153004-meeting",
            "meetingStart": 770_000_000.0,
            "engine": "fluid_audio",
            "chunkDurationMinutes": 10,
            "chunks": [],
            "provenance": [
                "engine": "fluid_audio",
                "route_changes": 0,
                "retries": 0,
                "recovered": false,
                "anomaly_count": 1,
                // pre-dates quality_anomaly_count AND system_audio_unrecovered
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        // Unconditional: if this throws, a real crash-recovery session would be silently discarded.
        let decoded = try JSONDecoder().decode(SessionState.self, from: data)
        #expect(decoded.sessionId == "153004-meeting")
        #expect(decoded.provenance?.anomalyCount == 1)
        #expect(decoded.provenance?.qualityAnomalyCount == 0)
        #expect(decoded.provenance?.systemAudioUnrecovered == false)
    }
}
