import Testing
import Foundation
@testable import TranscriberCore

// MARK: - Helpers

private func makeFiles(_ names: [String], in dir: URL) {
    for name in names {
        FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: nil)
    }
}

private func withTempDir(_ body: (URL) throws -> Void) throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    try body(tmp)
}

// MARK: - Tests

@Suite("discoverSegments")
struct DiscoverSegmentsTests {

    // Only the base files exist → 1 pair returned
    @Test func singleSegmentReturnsOnePair() throws {
        try withTempDir { dir in
            let sys = dir.appendingPathComponent("meeting.wav")
            let mic = dir.appendingPathComponent("meeting_mic.wav")
            makeFiles(["meeting.wav", "meeting_mic.wav"], in: dir)

            let result = discoverSegments(systemAudio: sys, micAudio: mic)

            #expect(result.count == 1)
            #expect(result[0].system == sys)
            #expect(result[0].mic == mic)
        }
    }

    // Base + segment-2 files exist → 2 pairs
    @Test func twoSegmentsReturnsBothPairs() throws {
        try withTempDir { dir in
            let sys = dir.appendingPathComponent("meeting.wav")
            let mic = dir.appendingPathComponent("meeting_mic.wav")
            makeFiles(["meeting.wav", "meeting_mic.wav",
                       "meeting-2.wav", "meeting-2_mic.wav"], in: dir)

            let result = discoverSegments(systemAudio: sys, micAudio: mic)

            #expect(result.count == 2)
            #expect(result[1].system.lastPathComponent == "meeting-2.wav")
            #expect(result[1].mic.lastPathComponent == "meeting-2_mic.wav")
        }
    }

    // Base + segment-2 + segment-3 → 3 pairs
    @Test func threeSegmentsReturnsThreePairs() throws {
        try withTempDir { dir in
            let sys = dir.appendingPathComponent("session.wav")
            let mic = dir.appendingPathComponent("session_mic.wav")
            makeFiles(["session.wav", "session_mic.wav",
                       "session-2.wav", "session-2_mic.wav",
                       "session-3.wav", "session-3_mic.wav"], in: dir)

            let result = discoverSegments(systemAudio: sys, micAudio: mic)

            #expect(result.count == 3)
            #expect(result[2].system.lastPathComponent == "session-3.wav")
        }
    }

    // Base + segment-2 exist, segment-3 absent but segment-4 present → stops at gap, returns 2
    @Test func gapInSequenceStopsEarly() throws {
        try withTempDir { dir in
            let sys = dir.appendingPathComponent("rec.wav")
            let mic = dir.appendingPathComponent("rec_mic.wav")
            // segment-3 intentionally absent; segment-4 present (should not be discovered)
            makeFiles(["rec.wav", "rec_mic.wav",
                       "rec-2.wav", "rec-2_mic.wav",
                       "rec-4.wav", "rec-4_mic.wav"], in: dir)

            let result = discoverSegments(systemAudio: sys, micAudio: mic)

            #expect(result.count == 2)
            #expect(result[1].system.lastPathComponent == "rec-2.wav")
        }
    }

    // System segment-2 exists but mic segment-2 doesn't → pair still included (mic checked later)
    @Test func micFileMissingStillIncludesSegment() throws {
        try withTempDir { dir in
            let sys = dir.appendingPathComponent("call.wav")
            let mic = dir.appendingPathComponent("call_mic.wav")
            // Only the system-side segment-2 file exists
            makeFiles(["call.wav", "call_mic.wav", "call-2.wav"], in: dir)

            let result = discoverSegments(systemAudio: sys, micAudio: mic)

            #expect(result.count == 2)
            #expect(result[1].system.lastPathComponent == "call-2.wav")
            #expect(result[1].mic.lastPathComponent == "call-2_mic.wav")
            // mic path is returned even though the file doesn't exist on disk
            #expect(!FileManager.default.fileExists(atPath: result[1].mic.path))
        }
    }

    // Directory exists, only the base pair present → 1 pair (no extras discovered)
    @Test func noExtraFilesReturnsBaseOnly() throws {
        try withTempDir { dir in
            let sys = dir.appendingPathComponent("audio.wav")
            let mic = dir.appendingPathComponent("audio_mic.wav")
            makeFiles(["audio.wav", "audio_mic.wav"], in: dir)

            let result = discoverSegments(systemAudio: sys, micAudio: mic)

            #expect(result.count == 1)
        }
    }

    // 0-indexed mode: meeting-0.wav + meeting-1.wav → 2 pairs in order
    @Test func discoversZeroIndexedChunks() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiscoverChunks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 0...1 {
            try Data([0x00]).write(to: dir.appendingPathComponent("meeting-\(i).wav"))
            try Data([0x00]).write(to: dir.appendingPathComponent("meeting-\(i)_mic.wav"))
        }

        let base = dir.appendingPathComponent("meeting-0.wav")
        let baseMic = dir.appendingPathComponent("meeting-0_mic.wav")
        let segments = discoverSegments(systemAudio: base, micAudio: baseMic)

        #expect(segments.count == 2)
        #expect(segments[0].system.lastPathComponent == "meeting-0.wav")
        #expect(segments[1].system.lastPathComponent == "meeting-1.wav")
    }

    // 0-indexed mode: no files on disk → fallback to original pair
    @Test func zeroIndexedFallbackWhenNoFilesExist() throws {
        try withTempDir { dir in
            let base = dir.appendingPathComponent("rec-0.wav")
            let baseMic = dir.appendingPathComponent("rec-0_mic.wav")

            let result = discoverSegments(systemAudio: base, micAudio: baseMic)

            #expect(result.count == 1)
            #expect(result[0].system == base)
            #expect(result[0].mic == baseMic)
        }
    }
}
