import Testing
import Foundation
@testable import TranscriberCore

/// Whether a transcript's audio is still there for the rename dialog's Play and Re-detect (#29): an old recording's
/// archives may have been removed by the storage limit (`audio_removed`, #224) or be gone from where the transcript says.
/// Renaming never needs audio; Play and Re-detect do, and the dialog says why they are not offered.
@Suite struct RecordingAudioAvailabilityTests {

    private func metadata(paths: [String], removed: [String]? = nil) -> [String: Any] {
        var metadata: [String: Any] = ["audio_paths": paths, "audio_files": paths.map { ($0 as NSString).lastPathComponent }]
        if let removed { metadata["audio_removed"] = ["at": "2026-11-01T00:00:00Z", "files": removed, "reason": "storage_limit"] }
        return metadata
    }

    @Test func everyFileOnDiskIsAvailable() {
        let audio = RecordingAudioAvailability.of(
            metadata: metadata(paths: ["/r/d/093000-a-0.m4a", "/r/d/093000-a-1.m4a"]), fileExists: { _ in true })
        #expect(audio == .available)
        #expect(audio.allowsRedetect)
        #expect(audio.notice == nil)
    }

    @Test func removedByTheStorageLimit_allOrPart() {
        let paths = ["/r/d/093000-a-0.m4a", "/r/d/093000-a-1.m4a"]
        let all = RecordingAudioAvailability.of(metadata: metadata(paths: paths, removed: ["093000-a-0.m4a", "093000-a-1.m4a"]),
                                                fileExists: { _ in false })
        #expect(all == .removedByStorageLimit(all: true))
        let part = RecordingAudioAvailability.of(metadata: metadata(paths: paths, removed: ["093000-a-0.m4a"]),
                                                 fileExists: { $0.hasSuffix("-1.m4a") })
        #expect(part == .removedByStorageLimit(all: false))
        for audio in [all, part] {
            #expect(!audio.allowsRedetect, "\(audio)")
            let notice = audio.notice ?? ""
            #expect(notice.contains("storage limit"), "\(audio)")
            #expect(notice.contains("Names can still be changed"), "\(audio)")
        }
        // A mark whose files are all back on disk (restored from a backup): the audio is there.
        #expect(RecordingAudioAvailability.of(metadata: metadata(paths: paths, removed: ["093000-a-0.m4a"]),
                                              fileExists: { _ in true }) == .available)
    }

    @Test func notWhereTheTranscriptSays_allOrPart() {
        let paths = ["/old/d/093000-a-0.m4a", "/old/d/093000-a-1.m4a"]
        let all = RecordingAudioAvailability.of(metadata: metadata(paths: paths), fileExists: { _ in false })
        #expect(all == .missing(all: true))
        let part = RecordingAudioAvailability.of(metadata: metadata(paths: paths), fileExists: { $0.hasSuffix("-0.m4a") })
        #expect(part == .missing(all: false))
        for audio in [all, part] {
            #expect(!audio.allowsRedetect, "\(audio)")
            #expect(audio.notice?.contains("Names can still be changed") == true, "\(audio)")
            #expect(audio.notice?.contains("storage limit") == false, "\(audio)")
        }
    }

    @Test func aTranscriptThatListsNoAudio() {
        for meta in [[String: Any](), ["audio_paths": [String]()], nil] as [[String: Any]?] {
            let audio = RecordingAudioAvailability.of(metadata: meta, fileExists: { _ in true })
            #expect(audio == .notListed)
            #expect(!audio.allowsRedetect)
            #expect(audio.notice != nil)
        }
        // The storage limit removed everything a transcript listed under `audio_files` only.
        let removedOnly: [String: Any] = ["audio_removed": ["files": ["093000-a.m4a"], "reason": "storage_limit"]]
        #expect(RecordingAudioAvailability.of(metadata: removedOnly, fileExists: { _ in true }) == .removedByStorageLimit(all: true))
    }

    @Test func eachNoticeIsOneLineAndNamesNoPath() {
        let cases: [RecordingAudioAvailability] = [
            .removedByStorageLimit(all: true), .removedByStorageLimit(all: false), .missing(all: true), .missing(all: false),
            .notListed,
        ]
        for audio in cases {
            let notice = audio.notice ?? ""
            #expect(!notice.isEmpty, "\(audio)")
            #expect(!notice.contains("\n"), "\(audio)")
            #expect(!notice.contains("/"), "\(audio)")
        }
    }

    /// From the transcript on disk, as the rename panel reads it.
    @Test func fromATranscriptFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("audio-avail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appendingPathComponent("093000-a.m4a")
        try Data([0]).write(to: archive)
        let json: [String: Any] = ["metadata": metadata(paths: [archive.path]), "segments": [[String: Any]]()]
        #expect(RecordingAudioAvailability.of(json: json) == .available)
        try FileManager.default.removeItem(at: archive)
        #expect(RecordingAudioAvailability.of(json: json) == .missing(all: true))
    }
}
