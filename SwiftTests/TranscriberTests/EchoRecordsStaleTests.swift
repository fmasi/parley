import Testing
import Foundation
import AVFoundation
@testable import TranscriberCore

/// The echo record goes stale after the labels it quotes change (#270).
///
/// `metadata.echo_clusters[].matched_remote` is keyed by the remote labels at the time of the check.
/// A re-detect of the REMOTE channel renumbers those speakers, so the key must follow the speech to
/// the label that now carries it, or go: a stale key makes the speaker card name a remote speaker
/// who is somebody else now. A rename does not rewrite the record, so the card resolves the labels
/// through `speaker_names` the way it does the echo voice's own.
///
/// Synthetic labels and numbers only.
@Suite struct EchoRecordRemapTests {

    private let r1 = "Remote Speaker 1", r2 = "Remote Speaker 2", r3 = "Remote Speaker 3"

    private func line(_ start: Double, _ end: Double, _ label: String) -> SpeakerNameCarryOver.Line {
        .init(start: start, end: end, label: label)
    }

    /// An echo record: one entry that matched `remote`, one kept entry that matched nothing.
    private func metadata(remote: [String: Double], names: [String: String]? = nil) -> [String: Any] {
        var m: [String: Any] = [
            "echo_clusters": [
                ["track": "local", "chunk": 0, "label": "Local Speaker 2", "verdict": "echo", "segments": 30,
                 "matched_segments": 28, "seconds": 300.0, "matched_seconds": 280.0, "matched_remote": remote],
                ["track": "local", "chunk": 0, "label": "Local Speaker 1", "verdict": "kept", "segments": 50,
                 "matched_segments": 0, "seconds": 500.0, "matched_seconds": 0.0, "matched_remote": [String: Double]()],
            ] as [[String: Any]],
            "echo_segments_flagged": 28,
        ]
        if let names { m["speaker_names"] = names }
        return m
    }

    private func matched(_ metadata: [String: Any], entry: Int = 0) -> [String: Double] {
        let entries = metadata["echo_clusters"] as? [[String: Any]] ?? []
        return entries[entry]["matched_remote"] as? [String: Double] ?? [:]
    }

    // MARK: - A clear mapping remaps

    @Test func aSpeakerWhoseSpeechAllWentToOneLabelIsRemapped() {
        // The old "2" is the new "1": renumbered, not a different person.
        let overlap = SpeakerNameCarryOver.Overlap(
            old: [line(0, 100, r2), line(200, 260, r1)],
            new: [line(0, 100, r1), line(200, 260, r3)])
        let out = TranscriptRediarizer.remappingMatchedRemote(in: metadata(remote: [r2: 250, r1: 30]), overlap: overlap)
        #expect(matched(out) == [r1: 250, r3: 30])
        #expect(matched(out, entry: 1).isEmpty)
    }

    @Test func labelsMergedIntoOneAreSummed() {
        let overlap = SpeakerNameCarryOver.Overlap(
            old: [line(0, 100, r1), line(200, 300, r2)],
            new: [line(0, 100, r1), line(200, 300, r1)])
        let out = TranscriptRediarizer.remappingMatchedRemote(in: metadata(remote: [r1: 100, r2: 40]), overlap: overlap)
        #expect(matched(out) == [r1: 140])
    }

    /// "Most" is MORE than half, and the rest must not be a quarter or more on one other label.
    @Test func aMostlyKeptLabelIsRemappedWhenTheRestIsSmall() {
        let overlap = SpeakerNameCarryOver.Overlap(
            old: [line(0, 100, r1)],
            new: [line(0, 80, r2), line(80, 100, r3)])    // 80 / 20
        #expect(matched(TranscriptRediarizer.remappingMatchedRemote(in: metadata(remote: [r1: 90]), overlap: overlap)) == [r2: 90])
    }

    /// Only what the record holds changes: the rest of the metadata, and the entry's other fields.
    @Test func nothingButMatchedRemoteChanges() throws {
        let overlap = SpeakerNameCarryOver.Overlap(old: [line(0, 100, r2)], new: [line(0, 100, r1)])
        let before = metadata(remote: [r2: 250], names: ["Local Speaker 1": "Robin"])
        let out = TranscriptRediarizer.remappingMatchedRemote(in: before, overlap: overlap)
        let entry = try #require((out["echo_clusters"] as? [[String: Any]])?.first)
        #expect(entry["label"] as? String == "Local Speaker 2")
        #expect(entry["verdict"] as? String == "echo")
        #expect(entry["matched_seconds"] as? Double == 280)
        #expect(out["speaker_names"] as? [String: String] == ["Local Speaker 1": "Robin"])
        #expect(out["echo_segments_flagged"] as? Int == 28)
    }

    // MARK: - An ambiguous one drops

    @Test func aSpeakerSplitBetweenTwoLabelsIsDropped() {
        let overlap = SpeakerNameCarryOver.Overlap(
            old: [line(0, 100, r1)],
            new: [line(0, 60, r1), line(60, 100, r2)])    // 60 / 40: the larger half is a guess
        let out = TranscriptRediarizer.remappingMatchedRemote(in: metadata(remote: [r1: 200]), overlap: overlap)
        #expect(matched(out).isEmpty)
    }

    @Test func anEvenSplitIsDropped() {
        let overlap = SpeakerNameCarryOver.Overlap(
            old: [line(0, 100, r1)], new: [line(0, 50, r1), line(50, 100, r2)])
        #expect(matched(TranscriptRediarizer.remappingMatchedRemote(in: metadata(remote: [r1: 200]), overlap: overlap)).isEmpty)
    }

    @Test func aLabelWithNoSpeechToFollowIsDropped() {
        // R3 had only flagged lines before: nothing says where it went. R1 still has its own speech.
        let overlap = SpeakerNameCarryOver.Overlap(old: [line(0, 100, r1)], new: [line(0, 100, r2)])
        let out = TranscriptRediarizer.remappingMatchedRemote(in: metadata(remote: [r3: 90, r1: 60]), overlap: overlap)
        #expect(matched(out) == [r2: 60])
    }

    @Test func aLabelWhoseSpeechWentToNoOneIsDropped() {
        let overlap = SpeakerNameCarryOver.Overlap(old: [line(0, 100, r1)], new: [line(500, 600, r2)])
        #expect(matched(TranscriptRediarizer.remappingMatchedRemote(in: metadata(remote: [r1: 90]), overlap: overlap)).isEmpty)
    }

    @Test func noOverlapAtAllDropsEveryKey() {
        let out = TranscriptRediarizer.remappingMatchedRemote(in: metadata(remote: [r1: 90, r2: 10]), overlap: .none)
        #expect(matched(out).isEmpty)
        // The entry itself stays, so the card still says what it found: "the other side".
        #expect((out["echo_clusters"] as? [[String: Any]])?.count == 2)
    }

    // MARK: - Renamed speakers and records without echo

    /// The key is the label the check saw; the lines carry the name given since (renamed twice here:
    /// the chain in `speaker_names` is followed to its end).
    @Test func aRenamedRemoteSpeakerIsFollowedThroughItsName() {
        let names = [r2: "Alice", "Alice": "Alicia"]
        let overlap = SpeakerNameCarryOver.Overlap(
            old: [line(0, 100, "Alicia"), line(200, 260, r1)],
            new: [line(0, 100, r1), line(200, 260, r3)])
        let out = TranscriptRediarizer.remappingMatchedRemote(in: metadata(remote: [r2: 250, r1: 30], names: names), overlap: overlap)
        #expect(matched(out) == [r1: 250, r3: 30])
    }

    @Test func aTranscriptWithoutEchoClustersIsReturnedAsItWas() {
        let overlap = SpeakerNameCarryOver.Overlap(old: [line(0, 100, r1)], new: [line(0, 100, r2)])
        for before in [[:], ["speaker_names": [r1: "Alice"]], ["echo_clusters": [] as [Any]]] as [[String: Any]] {
            let out = TranscriptRediarizer.remappingMatchedRemote(in: before, overlap: overlap)
            #expect(NSDictionary(dictionary: out).isEqual(to: before))
        }
    }

    /// A name reused for someone else: RS1 was "Sam", then one Save corrected RS1 to "Tom" and named
    /// RS2 "Sam". The map is `{RS1: Sam, Sam: Tom, RS2: Sam}`; whose "Sam" is whose is lost, so the
    /// key is dropped, not pinned on Tom's speech.
    @Test func aKeyWhoseNameWasReusedIsDropped() {
        let names = [r1: "Sam", "Sam": "Tom", r2: "Sam"]
        let overlap = SpeakerNameCarryOver.Overlap(
            old: [line(0, 100, "Tom"), line(200, 300, "Sam")],
            new: [line(0, 100, r1), line(200, 300, r2)])
        let out = TranscriptRediarizer.remappingMatchedRemote(in: metadata(remote: [r2: 250], names: names), overlap: overlap)
        #expect(matched(out).isEmpty)
    }

    /// Renamed there and back (Sam → Tom → Sam): one person, and the lines carried "Sam".
    @Test func aKeyRenamedThereAndBackFollowsTheNameItsLinesCarry() {
        let names = [r1: "Sam", "Sam": "Tom", "Tom": "Sam"]
        let overlap = SpeakerNameCarryOver.Overlap(old: [line(0, 100, "Sam")], new: [line(0, 100, r2)])
        let out = TranscriptRediarizer.remappingMatchedRemote(in: metadata(remote: [r1: 90], names: names), overlap: overlap)
        #expect(matched(out) == [r2: 90])
    }

    /// A remote channel an older build re-detected: its keys are the labels of a clustering that is
    /// gone, so none of them is followed — even one that happens to name a label with speech now.
    @Test func aRecordAnOlderBuildLeftStaleDropsEveryKey() {
        let overlap = SpeakerNameCarryOver.Overlap(old: [line(0, 100, r1)], new: [line(0, 100, r1)])
        for stamp in [["rediarized_channels": ["remote"]], ["speaker_count_remote": 2]] as [[String: Any]] {
            let before = metadata(remote: [r1: 90]).merging(stamp) { $1 }
            let out = TranscriptRediarizer.remappingMatchedRemote(in: before, overlap: overlap)
            #expect(matched(out).isEmpty)
            #expect(out[TranscriptRediarizer.matchedRemoteCurrentKey] as? Bool == true)
        }
        // Once this build has remapped it, a later re-detect follows the keys again.
        let stamped = metadata(remote: [r1: 90]).merging(
            ["rediarized_channels": ["remote"], TranscriptRediarizer.matchedRemoteCurrentKey: true]) { $1 }
        #expect(matched(TranscriptRediarizer.remappingMatchedRemote(in: stamped, overlap: overlap)) == [r1: 90])
    }

    /// One malformed entry, or key, is skipped on its own; the rest of the record is still remapped.
    @Test func aMalformedEntryDoesNotStopTheRemap() throws {
        var before = metadata(remote: [r2: 250])
        before["echo_clusters"] = ["not an entry"] + (before["echo_clusters"] as? [[String: Any]] ?? []).map { $0 as Any }
        var entries = try #require(before["echo_clusters"] as? [Any])
        var first = try #require(entries[1] as? [String: Any])
        first["matched_remote"] = [r2: 250.0, r1: "twelve"] as [String: Any]
        entries[1] = first
        before["echo_clusters"] = entries
        let overlap = SpeakerNameCarryOver.Overlap(
            old: [line(0, 100, r2), line(200, 260, r1)], new: [line(0, 100, r1), line(200, 260, r3)])
        let out = TranscriptRediarizer.remappingMatchedRemote(in: before, overlap: overlap)
        let after = try #require(out["echo_clusters"] as? [Any])
        #expect(after.count == 3)
        #expect(after[0] as? String == "not an entry")
        #expect((after[1] as? [String: Any])?["matched_remote"] as? [String: Double] == [r1: 250])
    }

    @Test func anEntryWithoutMatchedRemoteIsLeftAlone() throws {
        let before: [String: Any] = ["echo_clusters": [["track": "local", "label": "Local Speaker 2", "verdict": "echo"]]]
        let out = TranscriptRediarizer.remappingMatchedRemote(
            in: before, overlap: .init(old: [line(0, 10, r1)], new: [line(0, 10, r2)]))
        let entry = try #require((out["echo_clusters"] as? [[String: Any]])?.first)
        #expect(entry["matched_remote"] == nil)
    }
}

/// The card quotes the other side's labels as people see them now: the name a rename gave them.
@Suite struct EchoCardRemoteNamesTests {

    private let echo = "Local Speaker 2"
    private let r1 = "Remote Speaker 1", r2 = "Remote Speaker 2"

    private func metadata(remote: [String: Double], names: [String: String] = [:]) -> [String: Any] {
        var m: [String: Any] = ["echo_clusters": [
            ["track": "local", "chunk": 0, "label": echo, "verdict": "echo", "segments": 60, "matched_segments": 50,
             "seconds": 500.0, "matched_seconds": 450.0, "matched_remote": remote] as [String: Any],
        ]]
        if !names.isEmpty { m["speaker_names"] = names }
        return m
    }

    /// The card as the dialog builds it: from the transcript, whose remote lines carry `remote`.
    private func findings(_ metadata: [String: Any], remote: [String]) -> EchoNotice.Findings {
        EchoNotice.Findings(json: [
            "metadata": metadata,
            "segments": remote.enumerated().map { i, label in
                ["start": Double(i * 10), "end": Double(i * 10 + 5), "speaker": label, "source": "remote", "text": "w"]
            } + [["start": 500.0, "end": 505.0, "speaker": echo, "source": "local", "text": "w"]],
        ])
    }

    private func notice(_ metadata: [String: Any], remote: [String]) throws -> String {
        try #require(findings(metadata, remote: remote).cardNotice(forRow: echo))
    }

    @Test func aRenamedRemoteSpeakerIsQuotedByItsName() throws {
        let text = try notice(metadata(remote: [r1: 400], names: [r1: "Alice"]), remote: ["Alice"])
        #expect(text.contains("match Alice at the same time"))
        #expect(!text.contains(r1))
    }

    @Test func aTwiceRenamedRemoteSpeakerIsQuotedByItsLastName() throws {
        let text = try notice(metadata(remote: [r1: 400], names: [r1: "Alice", "Alice": "Alicia"]), remote: ["Alicia"])
        #expect(text.contains("match Alicia at the same time"))
        #expect(!text.contains("Alice at") && !text.contains(r1))
    }

    /// Renamed there and back to the label: the loop ends, and the lines say what it is called now.
    @Test func aLoopInTheNamesDoesNotHangTheCard() throws {
        let text = try notice(metadata(remote: [r1: 400], names: [r1: "Alice", "Alice": r1]), remote: [r1])
        #expect(text.contains("match \(r1) at the same time"))
        // Without the lines, a loop has no end to quote.
        let bare = try #require(EchoNotice.Findings(metadata: metadata(remote: [r1: 400], names: [r1: "Alice", "Alice": r1]))
            .cardNotice(forRow: echo))
        #expect(bare.contains("match the other side at the same time"))
    }

    /// Sam → Tom → Sam: one person, whose lines carry "Sam" again; never "Tom", which no row shows.
    @Test func aNameGivenThereAndBackIsTheOneTheLinesCarry() throws {
        let text = try notice(metadata(remote: [r1: 400], names: [r1: "Sam", "Sam": "Tom", "Tom": "Sam"]), remote: ["Sam"])
        #expect(text.contains("match Sam at the same time"))
    }

    /// RS1 was "Sam"; one Save corrected RS1 to "Tom" and named RS2 "Sam". The echo matched RS2, who
    /// is Sam — but the map `{RS1: Sam, Sam: Tom, RS2: Sam}` cannot say so, and following it says
    /// Tom. The card names neither.
    @Test func aReusedNameIsNotFollowedToSomebodyElse() throws {
        let names = [r1: "Sam", "Sam": "Tom", r2: "Sam"]
        let text = try notice(metadata(remote: [r2: 400], names: names), remote: ["Tom", "Sam"])
        #expect(text.contains("match the other side at the same time"))
        #expect(!text.contains("Tom"))
    }

    /// A later Save overwrote the reused name's entry: RS1 "Sam", then {Sam: Tom, RS2: Sam}, then
    /// {Sam: Bob}. RS1 is Tom, RS2 is Bob, and `{RS1: Sam, Sam: Bob, RS2: Sam}` has lost Tom: the
    /// chain from RS1 meets exactly one label on the lines (Bob), the wrong one. Neither resolves.
    @Test func anOverwrittenRenameResolvesNeitherSpeaker() {
        let names = [r1: "Sam", "Sam": "Bob", r2: "Sam"]
        #expect(TranscriptRenamer.currentLabel(of: r1, names: names, present: ["Tom", "Bob"]) == nil)
        #expect(TranscriptRenamer.currentLabel(of: r2, names: names, present: ["Tom", "Bob"]) == nil)
        // Two labels given one name, never renamed on: both are that name.
        #expect(TranscriptRenamer.currentLabel(of: r1, names: [r1: "Sam", r2: "Sam"], present: ["Sam"]) == "Sam")
        // A label never renamed is itself, whatever the lines.
        #expect(TranscriptRenamer.currentLabel(of: r1, names: [r2: "Sam"], present: []) == r1)
    }

    /// A remote channel an older build re-detected: its keys name a clustering that is gone.
    @Test func aRecordAnOlderBuildLeftStaleQuotesNoRemoteLabel() throws {
        var m = metadata(remote: [r1: 400])
        m["rediarized_channels"] = ["remote"]
        #expect(try notice(m, remote: [r1]).contains("match the other side at the same time"))
        m[TranscriptRediarizer.matchedRemoteCurrentKey] = true
        #expect(try notice(m, remote: [r1]).contains("match \(r1) at the same time"))
    }

    @Test func twoLabelsGivenTheSameNameAreOnePersonAndTheirSecondsAdd() throws {
        let f = findings(metadata(remote: [r1: 100, r2: 150, "Remote Speaker 3": 120], names: [r1: "Alice", r2: "Alice"]),
                         remote: ["Alice", "Remote Speaker 3"])
        #expect(f.voices.first?.remoteLabels == ["Alice", "Remote Speaker 3"])    // 250 s, then 120 s
        #expect(try #require(f.cardNotice(forRow: echo)).contains("match Alice and Remote Speaker 3"))
    }

    @Test func aLabelNobodyRenamedIsQuotedAsItAlwaysWas() throws {
        let text = try notice(metadata(remote: [r1: 400, r2: 50], names: ["Local Speaker 1": "Robin", "Remote Speaker 9": "Zed"]),
                              remote: [r1, r2])
        #expect(text.contains("match \(r1) and \(r2) at the same time"))
    }

    /// A rename of this side does not touch what the card says about the other.
    @Test func aLocalRenameDoesNotChangeTheQuotedRemoteLabel() throws {
        let f = findings(metadata(remote: [r1: 400], names: [echo: "Voice B"]), remote: [r1])
        let text = try #require(f.cardNotice(forRow: "Voice B"))
        #expect(text.contains("match \(r1) at the same time"))
    }
}

/// A rename on disk, then the card read back from it (#270): the record keeps the labels the check
/// wrote, `speaker_names` says what they are called now, and the card follows both.
@Suite(.serialized) struct EchoRecordAfterRenameTests {

    private func makeTranscript() throws -> (url: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("echo-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("t.json")
        let json: [String: Any] = [
            "metadata": [
                "echo_clusters": [
                    ["track": "local", "chunk": 0, "label": "Local Speaker 2", "verdict": "echo", "segments": 60,
                     "matched_segments": 50, "seconds": 500.0, "matched_seconds": 450.0,
                     "matched_remote": ["Remote Speaker 1": 400.0]] as [String: Any],
                ],
            ] as [String: Any],
            "segments": [
                ["start": 0.0, "end": 5.0, "speaker": "Remote Speaker 1", "source": "remote", "text": "one"],
                ["start": 6.0, "end": 9.0, "speaker": "Local Speaker 2", "source": "local", "text": "two"],
                ["start": 10.0, "end": 12.0, "speaker": "Local Speaker 1", "source": "local", "text": "three"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return (url, { try? FileManager.default.removeItem(at: dir) })
    }

    @Test func theCardFollowsARenameOfEitherSide() throws {
        let (url, cleanup) = try makeTranscript(); defer { cleanup() }
        #expect(TranscriptRenamer.applyRenames(["Remote Speaker 1": "Alice", "Local Speaker 2": "Voice B"], jsonPath: url))

        let findings = EchoNotice.Findings.read(transcriptAt: url)
        // The echo voice's row is its new name; the quoted remote speaker is called what the user calls them.
        let text = try #require(findings.cardNotice(forRow: "Voice B"))
        #expect(text.contains("match Alice at the same time"))
        #expect(!text.contains("Remote Speaker 1"))

        // A second rename of the same speaker: the chain, not the first name.
        #expect(TranscriptRenamer.applyRenames(["Alice": "Alicia"], jsonPath: url))
        #expect(try #require(EchoNotice.Findings.read(transcriptAt: url).cardNotice(forRow: "Voice B")).contains("match Alicia at"))
    }

    /// The record is what the check wrote; a rename keeps it that way. Resolving at read is what
    /// keeps the card right, and a re-detect (which clears the channel's names) cannot be fooled by it.
    @Test func aRenameLeavesTheRecordAsTheCheckWroteIt() throws {
        let (url, cleanup) = try makeTranscript(); defer { cleanup() }
        #expect(TranscriptRenamer.applyRenames(["Remote Speaker 1": "Alice", "Local Speaker 2": "Voice B"], jsonPath: url))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entry = try #require(((json["metadata"] as? [String: Any])?["echo_clusters"] as? [[String: Any]])?.first)
        #expect(entry["label"] as? String == "Local Speaker 2")
        #expect((entry["matched_remote"] as? [String: Double])?.keys.sorted() == ["Remote Speaker 1"])
    }
}

/// A remote re-detect, through the real `TranscriptRediarizer` (#270): the echo record's remote
/// labels follow the speech or go.
@Suite(.serialized) struct EchoRecordAfterRemoteRedetectTests {

    private struct Scripted: DiarizationProvider {
        let result: DiarizationResult
        func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult { result }
        func diarize(audio: [Float], numSpeakers: Int?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult { result }
    }

    private func line(_ start: Double, _ end: Double, _ label: String, _ source: String = "remote") -> [String: Any] {
        ["start": start, "end": end, "speaker": label, "source": source, "text": "w\(Int(start)) w\(Int(end)) made up words", "confidence": 0.9]
    }

    /// One second of audio per channel (a mic-only chunk, then a system-only one); the scripted
    /// diarizer never looks at it.
    private func makeRecording(segments: [[String: Any]], metadata extra: [String: Any]) throws -> (URL, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("echo-remote-redetect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let files = [dir.appendingPathComponent("call-0_mic.wav"), dir.appendingPathComponent("call-1.wav")]
        for file in files {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
            buffer.frameLength = 16000
            try AVAudioFile(forWriting: file, settings: format.settings).write(from: buffer)
        }
        var metadata: [String: Any] = ["audio_paths": files.map(\.path), "chunk_durations": [1.0, 1.0]]
        metadata.merge(extra) { _, new in new }
        let url = dir.appendingPathComponent("t.json")
        try JSONSerialization.data(withJSONObject: ["metadata": metadata, "segments": segments]).write(to: url)
        return (url, { try? FileManager.default.removeItem(at: dir) })
    }

    private func echoRecord(remote: [String: Double]) -> [String: Any] {
        ["echo_clusters": [
            ["track": "local", "chunk": 0, "label": "Local Speaker 2", "verdict": "echo", "segments": 20,
             "matched_segments": 18, "seconds": 100.0, "matched_seconds": 90.0, "matched_remote": remote] as [String: Any],
        ], "echo_segments_flagged": 18]
    }

    private func matchedRemote(_ url: URL) throws -> [String: Double] {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entries = try #require((json["metadata"] as? [String: Any])?["echo_clusters"] as? [[String: Any]])
        return try #require(entries.first?["matched_remote"] as? [String: Double])
    }

    private func result(_ turns: [(Double, Double, String)]) -> DiarizationResult {
        let labels = Set(turns.map(\.2)).sorted()
        return DiarizationResult(
            segments: turns.map { DiarizedSegment(start: $0.0, end: $0.1, speaker: $0.2, qualityScore: 0.9) },
            speakerDatabase: Dictionary(uniqueKeysWithValues: labels.enumerated().map { i, l in
                (l, (0..<3).map { $0 == i ? Float(1) : 0 })
            }))
    }

    @Test("a clear mapping: the quoted remote label follows the speech to its new number")
    func aClearMappingRemaps() async throws {
        // Two remote people; the re-detect swaps their numbers: who was "2" is now "1".
        let before = [line(10, 20, "Remote Speaker 1"), line(30, 40, "Remote Speaker 2"),
                      line(50, 60, "Remote Speaker 1"), line(70, 80, "Remote Speaker 2")]
        let (url, cleanup) = try makeRecording(segments: before, metadata: echoRecord(remote: ["Remote Speaker 2": 60, "Remote Speaker 1": 30]))
        defer { cleanup() }
        _ = try await TranscriptRediarizer.rediarize(
            transcript: url, source: "remote", speakerCount: 2,
            diarizer: Scripted(result: result([(30, 40, "A"), (70, 80, "A"), (10, 20, "B"), (50, 60, "B")])))
        let after = try matchedRemote(url)
        // Whoever the diarizer numbers first, the seconds sit on the label now carrying the same voice.
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let segments = try #require(json["segments"] as? [[String: Any]])
        let nowFirst = try #require(segments.first { $0["start"] as? Double == 30 }?["speaker"] as? String)   // was "2"
        let nowSecond = try #require(segments.first { $0["start"] as? Double == 10 }?["speaker"] as? String)  // was "1"
        // The numbers did swap: the speaker who was "2" is "1" now.
        #expect(nowFirst == "Remote Speaker 1" && nowSecond == "Remote Speaker 2")
        #expect(after == [nowFirst: 60, nowSecond: 30])
    }

    @Test("an ambiguous mapping: a speaker split between two new labels is dropped, never guessed")
    func anAmbiguousMappingDrops() async throws {
        let before = [line(10, 20, "Remote Speaker 1"), line(30, 40, "Remote Speaker 1"),
                      line(50, 60, "Remote Speaker 2")]
        let (url, cleanup) = try makeRecording(segments: before, metadata: echoRecord(remote: ["Remote Speaker 1": 80, "Remote Speaker 2": 20]))
        defer { cleanup() }
        // Old "1" (two lines) is split in half by the new clustering; old "2" stays whole.
        _ = try await TranscriptRediarizer.rediarize(
            transcript: url, source: "remote", speakerCount: 3,
            diarizer: Scripted(result: result([(10, 20, "A"), (30, 40, "B"), (50, 60, "C")])))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let segments = try #require(json["segments"] as? [[String: Any]])
        let whole = try #require(segments.first { $0["start"] as? Double == 50 }?["speaker"] as? String)
        // Only the speaker who moved whole keeps a key; the split one is gone, not pinned on either half.
        #expect(try matchedRemote(url) == [whole: 20])
    }

    @Test("a re-detect of this side does not remap: remote labels stay as they were")
    func aLocalRedetectDoesNotTouchTheRemoteLabels() async throws {
        let before = [line(10, 20, "Remote Speaker 1"), line(30, 40, "Local Speaker 1", "local")]
        var metadata = echoRecord(remote: ["Remote Speaker 1": 60])
        // An entry of the other track survives a local re-detect untouched (the local ones are rewritten).
        metadata["echo_clusters"] = (metadata["echo_clusters"] as? [[String: Any]] ?? []) + [
            ["track": "remote", "chunk": 0, "label": "Remote Speaker 7", "verdict": "kept", "segments": 5,
             "matched_remote": ["Remote Speaker 9": 5.0]] as [String: Any],
        ]
        let (url, cleanup) = try makeRecording(segments: before, metadata: metadata)
        defer { cleanup() }
        _ = try await TranscriptRediarizer.rediarize(
            transcript: url, source: "local", speakerCount: 1, diarizer: Scripted(result: result([(30, 40, "A")])))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entries = try #require((json["metadata"] as? [String: Any])?["echo_clusters"] as? [[String: Any]])
        let other = try #require(entries.first { $0["track"] as? String == "remote" })
        #expect((other["matched_remote"] as? [String: Double]) == ["Remote Speaker 9": 5])
    }

    @Test("a re-detect of this side writes the record again, under the remote labels the lines carry now")
    func aLocalRedetectMarksTheRecordCurrent() async throws {
        let before = [line(10, 20, "Remote Speaker 1"), line(30, 40, "Local Speaker 1", "local")]
        let (url, cleanup) = try makeRecording(
            segments: before, metadata: echoRecord(remote: ["Remote Speaker 1": 60]).merging(["rediarized_channels": ["remote"]]) { $1 })
        defer { cleanup() }
        _ = try await TranscriptRediarizer.rediarize(
            transcript: url, source: "local", speakerCount: 1, diarizer: Scripted(result: result([(30, 40, "A")])))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let metadata = try #require(json["metadata"] as? [String: Any])
        #expect(metadata[TranscriptRediarizer.matchedRemoteCurrentKey] as? Bool == true)
        #expect(TranscriptRediarizer.matchedRemoteIsCurrent(in: metadata))
    }

    @Test("a transcript without echo_clusters is re-detected as before")
    func noEchoClustersNoEchoRecordAppears() async throws {
        let before = [line(10, 20, "Remote Speaker 1"), line(30, 40, "Remote Speaker 2")]
        let (url, cleanup) = try makeRecording(segments: before, metadata: [:]); defer { cleanup() }
        _ = try await TranscriptRediarizer.rediarize(
            transcript: url, source: "remote", speakerCount: 2, diarizer: Scripted(result: result([(10, 20, "A"), (30, 40, "B")])))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((json["metadata"] as? [String: Any])?["echo_clusters"] == nil)
    }

    @Test("a name a later rename keyed is cleared with the channel's labels, so it cannot resolve a new speaker")
    func aNameKeyedEntryDoesNotSurviveARemoteRedetect() async throws {
        // RS1 was named Sam, then Sam renamed Tom: `{RS1: Sam, Sam: Tom}`. The lines carry "Tom".
        let before = [line(10, 20, "Tom"), line(30, 40, "Remote Speaker 2"), line(50, 60, "Tom")]
        let (url, cleanup) = try makeRecording(
            segments: before,
            metadata: echoRecord(remote: ["Remote Speaker 1": 70]).merging(
                ["speaker_names": ["Remote Speaker 1": "Sam", "Sam": "Tom", "Local Speaker 1": "Robin"]]) { $1 })
        defer { cleanup() }
        _ = try await TranscriptRediarizer.rediarize(
            transcript: url, source: "remote", speakerCount: 2,
            diarizer: Scripted(result: result([(10, 20, "A"), (50, 60, "A"), (30, 40, "B")])))
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var metadata = try #require(json["metadata"] as? [String: Any])
        // The whole remote chain went to the stash; this side's name stayed.
        #expect(metadata["speaker_names"] as? [String: String] == ["Local Speaker 1": "Robin"])
        #expect(metadata["speaker_names_previous"] as? [String: String] == ["Remote Speaker 1": "Sam", "Sam": "Tom"])
        #expect(metadata[TranscriptRediarizer.matchedRemoteCurrentKey] as? Bool == true)
        let tomNow = try #require((json["segments"] as? [[String: Any]])?.first { $0["start"] as? Double == 10 }?["speaker"] as? String)
        #expect(try matchedRemote(url) == [tomNow: 70])

        // Somebody names the speaker "Sam": the card quotes Sam, not the Tom of the old clustering.
        let other = tomNow == "Remote Speaker 1" ? "Remote Speaker 2" : "Remote Speaker 1"
        #expect(TranscriptRenamer.applyRenames([tomNow: "Sam", other: "Ann"], jsonPath: url))
        json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        metadata = try #require(json["metadata"] as? [String: Any])
        #expect((metadata["speaker_names"] as? [String: String])?["Sam"] == nil)
        let text = try #require(EchoNotice.Findings(json: json).cardNotice(forRow: "Local Speaker 2"))
        #expect(text.contains("match Sam at the same time"))
    }

    @Test("a second remote re-detect still follows the keys the first one remapped")
    func aSecondRemoteRedetectStillRemaps() async throws {
        let before = [line(10, 20, "Remote Speaker 1"), line(30, 40, "Remote Speaker 2")]
        let (url, cleanup) = try makeRecording(segments: before, metadata: echoRecord(remote: ["Remote Speaker 1": 60]))
        defer { cleanup() }
        for turns in [[(30.0, 40.0, "A"), (10.0, 20.0, "B")], [(10.0, 20.0, "A"), (30.0, 40.0, "B")]] {
            _ = try await TranscriptRediarizer.rediarize(
                transcript: url, source: "remote", speakerCount: 2, diarizer: Scripted(result: result(turns)))
        }
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let now = try #require((json["segments"] as? [[String: Any]])?.first { $0["start"] as? Double == 10 }?["speaker"] as? String)
        #expect(try matchedRemote(url) == [now: 60])
    }

    @Test("a renamed remote speaker is followed through the name, and the re-detect still clears the names")
    func aRenamedRemoteSpeakerIsFollowedOnDisk() async throws {
        // R1 was renamed Alice: her lines carry the name, the record still holds R1.
        let before = [line(10, 20, "Alice"), line(30, 40, "Remote Speaker 2")]
        let (url, cleanup) = try makeRecording(
            segments: before,
            metadata: echoRecord(remote: ["Remote Speaker 1": 70, "Remote Speaker 2": 20]).merging(
                ["speaker_names": ["Remote Speaker 1": "Alice"]]) { $1 })
        defer { cleanup() }
        _ = try await TranscriptRediarizer.rediarize(
            transcript: url, source: "remote", speakerCount: 2, diarizer: Scripted(result: result([(30, 40, "A"), (10, 20, "B")])))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let segments = try #require(json["segments"] as? [[String: Any]])
        let aliceNow = try #require(segments.first { $0["start"] as? Double == 10 }?["speaker"] as? String)
        #expect(aliceNow == "Remote Speaker 2")   // renumbered: she was "1"
        #expect(try matchedRemote(url)[aliceNow] == 70)
        #expect((json["metadata"] as? [String: Any])?["speaker_names"] == nil)
    }
}
