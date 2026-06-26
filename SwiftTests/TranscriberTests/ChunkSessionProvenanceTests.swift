import Testing
import Foundation
@testable import TranscriberCore

struct ChunkSessionProvenanceTests {

    @Test func provenanceRoundTripsThroughDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-prov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let prov = CaptureProvenance(
            engine: "fluid_audio", systemFormat: "48000Hz/1ch", micFormat: nil, micDevice: "AirPods",
            routeChanges: 1, retries: 0, recovered: true, anomalyCount: 1
        )
        let state = SessionState(
            sessionId: "s", meetingStart: Date(timeIntervalSinceReferenceDate: 0),
            engine: "fluid_audio", chunkDurationMinutes: 30, chunks: [], provenance: prov
        )
        try SessionState.write(state, directory: dir)

        let read = SessionState.read(directory: dir)
        #expect(read?.provenance == prov)
    }

    @Test func legacySessionWithoutProvenanceDecodesNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-prov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A pre-#95 session.json with no `provenance` key must still decode.
        let legacy = """
        {"sessionId":"s","meetingStart":"2026-06-25T10:00:00Z","engine":"fluid_audio","chunkDurationMinutes":30,"chunks":[]}
        """
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("session.json"))

        let read = SessionState.read(directory: dir)
        #expect(read != nil)
        #expect(read?.provenance == nil)
    }

    @Test func provenanceOmittedWhenNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-prov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let state = SessionState(
            sessionId: "s", meetingStart: Date(timeIntervalSinceReferenceDate: 0),
            engine: "fluid_audio", chunkDurationMinutes: 30, chunks: []
        )
        try SessionState.write(state, directory: dir)
        let read = SessionState.read(directory: dir)
        #expect(read?.provenance == nil)
    }
}
