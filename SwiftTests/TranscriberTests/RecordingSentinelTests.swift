import Testing
import Foundation
@testable import TranscriberCore

struct RecordingSentinelTests {
    // MARK: - Helpers

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentinelTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeSentinel(startedAt: Date = Date(), segment: Int = 0) -> RecordingSentinel {
        RecordingSentinel(
            startedAt: startedAt,
            sessionName: "Weekly Sync",
            systemAudioPath: "/tmp/system.wav",
            micAudioPath: "/tmp/mic.wav",
            micDeviceUID: "UID-ABC123",
            segment: segment
        )
    }

    // MARK: - Round trip

    @Test func writeAndReadRoundTrip() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        // Use a fixed date to avoid sub-second precision loss through ISO 8601 encoding.
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let original = makeSentinel(startedAt: date)

        try RecordingSentinel.write(original, directory: dir)
        let recovered = RecordingSentinel.read(directory: dir)

        #expect(recovered != nil)
        #expect(recovered?.sessionName == original.sessionName)
        #expect(recovered?.systemAudioPath == original.systemAudioPath)
        #expect(recovered?.micAudioPath == original.micAudioPath)
        #expect(recovered?.micDeviceUID == original.micDeviceUID)
        #expect(recovered?.segment == original.segment)
        // ISO 8601 is second-precision — compare to the nearest second.
        #expect(recovered?.startedAt.timeIntervalSinceReferenceDate == date.timeIntervalSinceReferenceDate)
    }

    // MARK: - Read returns nil when no file

    @Test func readReturnsNilWhenNoFile() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let result = RecordingSentinel.read(directory: dir)
        #expect(result == nil)
    }

    // MARK: - Delete removes file

    @Test func deleteRemovesFile() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        try RecordingSentinel.write(makeSentinel(), directory: dir)
        #expect(RecordingSentinel.read(directory: dir) != nil)

        RecordingSentinel.delete(directory: dir)
        #expect(RecordingSentinel.read(directory: dir) == nil)
    }

    // MARK: - Delete is no-op when no file

    @Test func deleteIsNoOpWhenNoFile() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        // Should not throw or crash.
        RecordingSentinel.delete(directory: dir)
        #expect(RecordingSentinel.read(directory: dir) == nil)
    }

    // MARK: - Write is atomic (file exists at expected path)

    @Test func writeIsAtomic() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        try RecordingSentinel.write(makeSentinel(), directory: dir)

        let expectedPath = dir.appendingPathComponent("recording.json").path
        #expect(FileManager.default.fileExists(atPath: expectedPath))
    }

    // MARK: - Robustness: corrupt / malformed JSON

    @Test func readReturnsNilForCorruptJSON() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let url = dir.appendingPathComponent("recording.json")
        try Data("this is not json at all!!!".utf8).write(to: url)

        #expect(RecordingSentinel.read(directory: dir) == nil)
    }

    @Test func readReturnsNilForPartialJSON() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        // Valid JSON but missing required fields (systemAudioPath, micAudioPath, startedAt, segment).
        let url = dir.appendingPathComponent("recording.json")
        try Data(#"{"sessionName": "test"}"#.utf8).write(to: url)

        #expect(RecordingSentinel.read(directory: dir) == nil)
    }

    @Test func readHandlesExtraUnknownFields() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        // Write a complete sentinel via the normal path, then add an unknown field manually.
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let original = makeSentinel(startedAt: date)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var dict = try JSONSerialization.jsonObject(
            with: encoder.encode(original)
        ) as! [String: Any]
        dict["extraField"] = true
        let data = try JSONSerialization.data(withJSONObject: dict)
        try data.write(to: dir.appendingPathComponent("recording.json"))

        let recovered = RecordingSentinel.read(directory: dir)
        #expect(recovered != nil)
        #expect(recovered?.sessionName == original.sessionName)
        #expect(recovered?.segment == original.segment)
    }

    @Test func readHandlesNullMicDeviceUID() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let json = """
        {
          "startedAt": "2025-05-01T12:00:00Z",
          "sessionName": "Null UID Test",
          "systemAudioPath": "/tmp/system.wav",
          "micAudioPath": "/tmp/mic.wav",
          "micDeviceUID": null,
          "segment": 0
        }
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("recording.json"))

        let recovered = RecordingSentinel.read(directory: dir)
        #expect(recovered != nil)
        #expect(recovered?.micDeviceUID == nil)
        #expect(recovered?.sessionName == "Null UID Test")
    }

    @Test func writeOverwritesExistingFile() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let first = RecordingSentinel(
            startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            sessionName: "First Session",
            systemAudioPath: "/tmp/first-system.wav",
            micAudioPath: "/tmp/first-mic.wav",
            micDeviceUID: "UID-FIRST",
            segment: 0
        )
        let second = RecordingSentinel(
            startedAt: Date(timeIntervalSinceReferenceDate: 900_000_000),
            sessionName: "Second Session",
            systemAudioPath: "/tmp/second-system.wav",
            micAudioPath: "/tmp/second-mic.wav",
            micDeviceUID: "UID-SECOND",
            segment: 1
        )

        try RecordingSentinel.write(first, directory: dir)
        try RecordingSentinel.write(second, directory: dir)

        let recovered = RecordingSentinel.read(directory: dir)
        #expect(recovered?.sessionName == "Second Session")
        #expect(recovered?.segment == 1)
        #expect(recovered?.micDeviceUID == "UID-SECOND")
    }

    // MARK: - Segment increments

    @Test func sentinelPreservesChunkIndex() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let original = RecordingSentinel(
            startedAt: date,
            sessionName: "Chunk Test",
            systemAudioPath: "/tmp/system.wav",
            micAudioPath: "/tmp/mic.wav",
            micDeviceUID: "UID-ABC",
            segment: 1,
            chunkIndex: 3
        )

        try RecordingSentinel.write(original, directory: dir)
        let recovered = RecordingSentinel.read(directory: dir)

        #expect(recovered != nil)
        #expect(recovered?.chunkIndex == 3)
        #expect(recovered?.segment == 1)

        // Also verify incrementedSegment preserves chunkIndex
        let incremented = original.incrementedSegment(
            systemAudioPath: "/tmp/system-2.wav",
            micAudioPath: "/tmp/mic-2.wav"
        )
        #expect(incremented.chunkIndex == 3)
        #expect(incremented.segment == 2)
    }

    @Test func segmentIncrements() {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let original = makeSentinel(startedAt: date, segment: 2)

        let next = original.incrementedSegment(
            systemAudioPath: "/tmp/system-1.wav",
            micAudioPath: "/tmp/mic-1.wav"
        )

        #expect(next.segment == 3)
        #expect(next.systemAudioPath == "/tmp/system-1.wav")
        #expect(next.micAudioPath == "/tmp/mic-1.wav")
        // Unchanged fields
        #expect(next.sessionName == original.sessionName)
        #expect(next.startedAt == original.startedAt)
        #expect(next.micDeviceUID == original.micDeviceUID)
    }
}
