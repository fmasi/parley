import Testing
import Foundation
@testable import TranscriberCore

struct AudioSourceResolverTests {

    @Test func detectsTwoWavFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let systemPath = dir.appendingPathComponent("meeting.wav")
        let micPath = dir.appendingPathComponent("meeting_mic.wav")
        try Data([0]).write(to: systemPath)
        try Data([0]).write(to: micPath)

        let result = try AudioSourceResolver.detect(baseName: "meeting", in: dir)
        guard case .dualWav(let system, let mic) = result else {
            Issue.record("Expected dualWav, got \(result)")
            return
        }
        #expect(system.lastPathComponent == "meeting.wav")
        #expect(mic.lastPathComponent == "meeting_mic.wav")
    }

    @Test func detectsStereoAac() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let aacPath = dir.appendingPathComponent("meeting.m4a")
        try Data([0]).write(to: aacPath)

        let result = try AudioSourceResolver.detect(baseName: "meeting", in: dir)
        guard case .stereoAac(let path) = result else {
            Issue.record("Expected stereoAac, got \(result)")
            return
        }
        #expect(path.lastPathComponent == "meeting.m4a")
    }

    @Test func prefersWavOverAacWhenBothExist() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data([0]).write(to: dir.appendingPathComponent("meeting.wav"))
        try Data([0]).write(to: dir.appendingPathComponent("meeting_mic.wav"))
        try Data([0]).write(to: dir.appendingPathComponent("meeting.m4a"))

        let result = try AudioSourceResolver.detect(baseName: "meeting", in: dir)
        guard case .dualWav = result else {
            Issue.record("Expected dualWav when both formats exist, got \(result)")
            return
        }
    }

    @Test func throwsWhenNoFilesFound() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: AudioSourceResolverError.self) {
            try AudioSourceResolver.detect(baseName: "missing", in: dir)
        }
    }

    @Test func detectsSystemWavOnlyWhenNoMic() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data([0]).write(to: dir.appendingPathComponent("meeting.wav"))

        let result = try AudioSourceResolver.detect(baseName: "meeting", in: dir)
        guard case .singleWav(let path) = result else {
            Issue.record("Expected singleWav, got \(result)")
            return
        }
        #expect(path.lastPathComponent == "meeting.wav")
    }
}
