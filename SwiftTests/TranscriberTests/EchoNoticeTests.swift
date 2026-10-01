import Testing
import Foundation
import AVFoundation
@testable import TranscriberCore

/// What the UI says about echo (#244): the copy and the small decisions behind it, built from
/// `metadata.echo_clusters` and friends. Synthetic numbers and labels only.
///
/// The assertions check the labels and the numbers a string carries, not every word of its prose.
@Suite struct EchoNoticeTests {

    // MARK: - Fixtures

    /// One `metadata.echo_clusters` entry, as `EchoDeduplicator.ClusterVerdict.metadataDictionary` writes it.
    private func entry(
        _ label: String, _ verdict: String, lines: Int, matched: Int, seconds: Double, matchedSeconds: Double,
        remote: [String: Double] = [:], chunk: Int? = 0, track: String? = "local"
    ) -> [String: Any] {
        var d: [String: Any] = [
            "label": label, "verdict": verdict, "segments": lines, "matched_segments": matched,
            "seconds": seconds, "matched_seconds": matchedSeconds, "words": lines * 12, "matched_words": matched * 12,
            "share": seconds > 0 ? matchedSeconds / seconds : 0, "matched_remote": remote,
        ]
        if let chunk { d["chunk"] = chunk }
        if let track { d["track"] = track }
        return d
    }

    private let you = "Local Speaker 1", echo = "Local Speaker 2"
    private let r1 = "Remote Speaker 1", r2 = "Remote Speaker 2"

    /// A speaker-mode recording: the user, and the other side's voice as a second local cluster.
    private var speakerMode: [String: Any] {
        ["echo_clusters": [
            entry(you, "kept", lines: 90, matched: 4, seconds: 600, matchedSeconds: 12, remote: [r1: 11]),
            entry(echo, "echo", lines: 120, matched: 96, seconds: 800, matchedSeconds: 720, remote: [r1: 700]),
        ], "echo_segments_flagged": 98]
    }

    private func findings(_ metadata: [String: Any]) -> EchoNotice.Findings { EchoNotice.Findings(metadata: metadata) }

    // MARK: - Nothing to say

    @Test func noEchoClusterSaysNothing() {
        let headphones: [String: Any] = ["echo_clusters": [
            entry(you, "kept", lines: 200, matched: 2, seconds: 1500, matchedSeconds: 9, remote: [r1: 8]),
        ]]
        for metadata in [[:], ["echo_clusters": [] as [Any]], headphones] {
            let f = findings(metadata)
            #expect(f.voices.isEmpty)
            #expect(f.cardNotice(forRow: you) == nil)
            #expect(f.redetectHint(on: "local") == nil)
            #expect(f.redetectHint(on: "remote") == nil)
            #expect(f.completionLines == 0)
        }
        #expect(findings([:]) == .none)
        #expect(EchoNotice.completionNotice(lines: 0) == nil)
    }

    /// A cluster judged to be somebody on this side is never called echo, however many of its lines matched.
    @Test func aKeptEntryNeverProducesACardNotice() {
        let f = findings(["echo_clusters": [
            entry(you, "kept", lines: 40, matched: 19, seconds: 400, matchedSeconds: 190, remote: [r1: 180]),
            entry(echo, "echo", lines: 60, matched: 50, seconds: 500, matchedSeconds: 450, remote: [r1: 440]),
        ]])
        #expect(f.cardNotice(forRow: you) == nil)
        #expect(f.cardNotice(forRow: echo) != nil)
        #expect(f.voices.map(\.label) == [echo])
    }

    // MARK: - The speaker card

    @Test func theCardNamesTheMatchTheRemoteLabelAndTheLinesKept() throws {
        let notice = try #require(findings(speakerMode).cardNotice(forRow: echo))
        #expect(notice.contains("96 of 120 lines"))
        // By duration share (720 s of 800 s), and said to be that: 96 of 120 lines is 80 %.
        #expect(notice.contains("90%"))
        #expect(notice.contains("speaking time"))
        #expect(notice.contains(r1))
        #expect(notice.contains("marked as echo"))
        #expect(notice.contains("other 24 lines"))
        // It describes a match: "looks like", never "is".
        #expect(notice.hasPrefix("Looks like the other side"))
        // Labels as the metadata holds them, never the user's own label in the other side's place.
        #expect(!notice.contains(you))
    }

    @Test func severalRemoteLabelsAreListedMostMatchedFirst() throws {
        func notice(_ remote: [String: Double]) throws -> String {
            try #require(findings(["echo_clusters": [
                entry(echo, "echo", lines: 60, matched: 50, seconds: 500, matchedSeconds: 450, remote: remote),
            ]]).cardNotice(forRow: echo))
        }
        #expect(try notice([r1: 100, r2: 300]).contains("match \(r2) and \(r1) at the same time"))
        #expect(try notice([r1: 100, r2: 300, "Remote Speaker 3": 40])
            .contains("match \(r2), \(r1) and Remote Speaker 3 at the same time"))
        // More than three: the two most matched, then a count.
        #expect(try notice([r1: 100, r2: 300, "Remote Speaker 3": 40, "Remote Speaker 4": 30, "Remote Speaker 5": 20])
            .contains("match \(r2), \(r1) and 3 others at the same time"))
        // Equal seconds: by label, so the copy does not change from one open to the next.
        #expect(try notice([r2: 100, r1: 100]).contains("match \(r1) and \(r2)"))
        // No remote label recorded: still a sentence.
        #expect(try notice([:]).contains("match the other side at the same time"))
    }

    /// One entry per chunk, and after a re-detect one per raw cluster: a label's entries are summed.
    @Test func entriesForTheSameLabelAcrossChunksAreSummed() throws {
        let f = findings(["echo_clusters": [
            entry(echo, "echo", lines: 100, matched: 90, seconds: 600, matchedSeconds: 540, remote: [r1: 500], chunk: 0),
            entry(you, "kept", lines: 80, matched: 1, seconds: 500, matchedSeconds: 2, chunk: 0),
            entry(echo, "echo", lines: 40, matched: 35, seconds: 400, matchedSeconds: 270, remote: [r1: 200, r2: 50], chunk: 1),
            // The same voice, too short to be judged a cluster in the last chunk: still its lines.
            entry(echo, "kept", lines: 10, matched: 1, seconds: 100, matchedSeconds: 5, remote: [r2: 4], chunk: 2),
        ]])
        let voice = try #require(f.voices.first)
        #expect(f.voices.count == 1)
        #expect(voice.lines == 150 && voice.matchedLines == 126 && voice.otherLines == 24)
        #expect(voice.percent == 74)   // 815 of 1100 seconds
        #expect(voice.remoteLabels == [r1, r2])
        let notice = try #require(f.cardNotice(forRow: echo))
        #expect(notice.contains("126 of 150 lines") && notice.contains("74%") && notice.contains("other 24 lines"))
        #expect(notice.contains("\(r1) and \(r2)"))
    }

    @Test func singularAndPlural() throws {
        func notice(lines: Int, matched: Int) throws -> String {
            try #require(findings(["echo_clusters": [
                entry(echo, "echo", lines: lines, matched: matched, seconds: 40, matchedSeconds: 30, remote: [r1: 30]),
            ]]).cardNotice(forRow: echo))
        }
        let one = try notice(lines: 2, matched: 1)
        #expect(one.contains("1 of 2 lines") && one.contains("matches \(r1)") && one.contains("is marked as echo"))
        #expect(one.contains("The other line "))
        let all = try notice(lines: 1, matched: 1)
        #expect(all.contains("1 of 1 line ") && !all.contains("The other"))
        let many = try notice(lines: 12, matched: 10)
        #expect(many.contains("10 of 12 lines") && many.contains("match \(r1)") && many.contains("are marked as echo"))
        #expect(many.contains("The other 2 lines "))
    }

    // MARK: - The re-detect row

    @Test func theRedetectHintIsForTheChannelWithAnEchoVoice() throws {
        let hint = try #require(findings(speakerMode).redetectHint(on: "local"))
        #expect(hint.contains("echo voice") && !hint.contains("echo voices"))
        #expect(hint.contains("separate") && hint.contains("marked as echo"))
        #expect(findings(speakerMode).redetectHint(on: "remote") == nil)
        let two = try #require(findings(["echo_clusters": [
            entry(echo, "echo", lines: 60, matched: 50, seconds: 500, matchedSeconds: 450),
            entry("Local Speaker 3", "echo", lines: 30, matched: 25, seconds: 200, matchedSeconds: 150),
        ]]).redetectHint(on: "local"))
        #expect(two.contains("echo voices"))
    }

    @Test func anOutcomeWithoutEchoReadsAsItAlwaysDid() {
        func outcome(_ speakers: Int, _ relabeled: Int) -> String {
            EchoNotice.redetectOutcome(TranscriptRediarizer.Outcome(
                speakerCount: speakers, segmentsRelabeled: relabeled, echoClusters: 0, echoFlagged: 0))
        }
        #expect(outcome(2, 84) == "2 speakers found · 84 lines relabeled")
        #expect(outcome(1, 1) == "1 speaker found · 1 line relabeled")
    }

    @Test func anOutcomeWithEchoSaysWhatWasFoundMarkedAndRelabeled() {
        let kept = EchoNotice.redetectOutcome(TranscriptRediarizer.Outcome(
            speakerCount: 1, segmentsRelabeled: 115, echoClusters: 1, echoFlagged: 96))
        #expect(kept.contains("1 speaker found") && kept.contains("1 echo voice kept separate"))
        #expect(kept.contains("96 lines marked as echo") && kept.contains("115 lines relabeled"))
        // One blended cluster: lines are flagged, there is no echo voice to keep apart.
        let blended = EchoNotice.redetectOutcome(TranscriptRediarizer.Outcome(
            speakerCount: 1, segmentsRelabeled: 240, echoClusters: 0, echoFlagged: 1))
        #expect(blended.contains("1 line marked as echo") && !blended.contains("echo voice"))
        // A mic channel that holds nothing but the other side's voice: no person on it.
        let none = EchoNotice.redetectOutcome(TranscriptRediarizer.Outcome(
            speakerCount: 0, segmentsRelabeled: 3, echoClusters: 2, echoFlagged: 40))
        #expect(none.contains("0 speakers found") && none.contains("2 echo voices kept separate"))
    }

    // MARK: - The people count the stepper pre-fills

    @Test func thePeopleCountLeavesTheEchoVoiceOut() {
        let f = findings(speakerMode)
        #expect(f.people(on: "local", rows: [you, echo]) == 1)
        #expect(f.people(on: "remote", rows: [r1, r2]) == 2)
        // Never below 1: the stepper has no 0, and a channel is offered only when it has a row.
        #expect(f.people(on: "local", rows: [echo]) == 1)
        #expect(f.people(on: "local", rows: []) == 1)
        // Without an echo voice it is the number of rows, as before.
        #expect(findings([:]).people(on: "local", rows: [you, echo]) == 2)
    }

    /// The rows leave out speakers with only a few lines; a re-detect recorded how many people it found.
    @Test func thePeopleCountIsNeverBelowTheRecordedOne() {
        var metadata = speakerMode
        metadata["speaker_count_local"] = 2
        #expect(findings(metadata).people(on: "local", rows: [you, echo]) == 2)
        #expect(findings(metadata).people(on: "remote", rows: [r1]) == 1)
        metadata["speaker_count_local"] = 0   // a mic channel that is nothing but echo
        #expect(findings(metadata).people(on: "local", rows: [you, echo]) == 1)
        // More rows than the recorded count: the rows win.
        metadata["speaker_count_local"] = 1
        #expect(findings(metadata).people(on: "local", rows: [you, "Local Speaker 3", echo]) == 2)
    }

    /// `echo_clusters` keeps the label a cluster had when it was judged; a rename changes the row,
    /// not that label. The row is found through `speaker_names`, however many renames deep.
    @Test func aRenamedEchoVoiceIsStillRecognised() {
        var metadata = speakerMode
        metadata["speaker_names"] = [you: "Voice A", echo: "Voice B"]
        let once = findings(metadata)
        #expect(once.cardNotice(forRow: "Voice B") != nil)
        #expect(once.cardNotice(forRow: "Voice A") == nil)
        #expect(once.people(on: "local", rows: ["Voice A", "Voice B"]) == 1)
        metadata["speaker_names"] = [echo: "Voice B", "Voice B": "Voice C"]
        #expect(findings(metadata).cardNotice(forRow: "Voice C") != nil)
        // Renamed there and back: a loop in the names must not hang, and the row is still found.
        metadata["speaker_names"] = [echo: "Voice B", "Voice B": echo]
        #expect(findings(metadata).cardNotice(forRow: echo) != nil)
        #expect(findings(metadata).people(on: "local", rows: [you, echo]) == 1)
    }

    // MARK: - Invalid input

    @Test func entriesThatAreNotVerdictsAreIgnored() {
        let good = entry(echo, "echo", lines: 60, matched: 50, seconds: 500, matchedSeconds: 450, remote: [r1: 440])
        var noLabel = good; noLabel["label"] = nil
        var noVerdict = good; noVerdict["verdict"] = 7
        var unknownVerdict = good; unknownVerdict["label"] = "Local Speaker 3"; unknownVerdict["verdict"] = "maybe"
        #expect(findings(["echo_clusters": [noLabel, noVerdict, unknownVerdict, "text", 3] as [Any]]).voices.isEmpty)
        #expect(findings(["echo_clusters": "echo"]).voices.isEmpty)
        // Numbers that are missing or make no sense never produce a negative count or a share above 100 %.
        var odd = good
        odd["segments"] = 10; odd["matched_segments"] = 40; odd["seconds"] = 0; odd["matched_remote"] = "nobody"
        let voice = findings(["echo_clusters": [odd]]).voices.first
        #expect(voice?.otherLines == 0 && voice?.percent == 0 && voice?.remoteLabels == [])
        var huge = good; huge["matched_seconds"] = 9_000.0
        #expect(findings(["echo_clusters": [huge]]).voices.first?.percent == 100)
        // No `track`: the mic channel, the only one the echo check judges.
        var noTrack = good; noTrack["track"] = nil
        #expect(findings(["echo_clusters": [noTrack]]).redetectHint(on: "local") != nil)
    }

    // MARK: - The completion notice

    @Test func theCompletionNoticeCountsTheLinesMarkedAndNamesHeadphones() throws {
        #expect(findings(speakerMode).completionLines == 98)    // `echo_segments_flagged`: every line marked
        var metadata = speakerMode
        metadata["echo_segments_flagged"] = nil
        #expect(findings(metadata).completionLines == 96)       // else the echo voice's matched lines
        let notice = try #require(EchoNotice.completionNotice(lines: 98))
        #expect(notice.contains("98 lines are marked as echo"))
        #expect(notice.contains("other side") && notice.contains("microphone"))
        #expect(notice.lowercased().contains("headphones"))
        #expect(notice.contains("looks like"))
        #expect(try #require(EchoNotice.completionNotice(lines: 1)).contains("1 line is marked as echo"))
    }

    // MARK: - Reading it off the transcript

    /// The keys are the echo check's own: a verdict written by `EchoDeduplicator` and read back
    /// through JSON, as a transcript holds it, gives the same numbers. A renamed key would otherwise
    /// make every notice disappear without a failing test.
    @Test func theFindingsReadWhatTheEchoCheckWrites() throws {
        let verdicts = [
            EchoDeduplicator.ClusterVerdict(
                label: echo, segments: 120, matchedSegments: 96, seconds: 800, matchedSeconds: 720,
                words: 1900, matchedWords: 1700, share: 0.9, verdict: .echo,
                bestEmbeddingSimilarity: 0.7, matchedRemote: [r1: 700, r2: 12.5]),
            EchoDeduplicator.ClusterVerdict(
                label: you, segments: 90, matchedSegments: 4, seconds: 600, matchedSeconds: 12,
                words: 1500, matchedWords: 20, share: 0.02, verdict: .kept),
        ]
        var metadata: [String: Any] = ["echo_clusters": verdicts.map { $0.metadataDictionary(chunk: 0) }]
        TranscriptAssembler.stampEchoFlagged(96, in: &metadata)
        let data = try JSONSerialization.data(withJSONObject: ["metadata": metadata])
        let f = EchoNotice.Findings(json: try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]))
        #expect(f.voices == [EchoNotice.Voice(track: "local", label: echo, lines: 120, matchedLines: 96, percent: 90, remoteLabels: [r1, r2])])
        #expect(f.flaggedLines == 96 && f.completionLines == 96)
    }

    @Test func findingsAreReadFromATranscriptAndAnUnreadableOneHasNone() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("echo-notice-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(EchoNotice.Findings.read(transcriptAt: url) == .none)
        try Data("{not json".utf8).write(to: url)
        #expect(EchoNotice.Findings.read(transcriptAt: url) == .none)
        try JSONSerialization.data(withJSONObject: ["metadata": speakerMode, "segments": [] as [Any]]).write(to: url)
        let read = EchoNotice.Findings.read(transcriptAt: url)
        #expect(read == findings(speakerMode))
        #expect(read.voices.map(\.label) == [echo])
        #expect(EchoNotice.Findings(json: ["segments": [] as [Any]]) == .none)
    }
}

/// The completion notice of a recording with an echo cluster (#244), through the notice builder and
/// through `RecordingCoordinator.presentCompletedTranscription` with the coordinator's fakes.
@MainActor
@Suite struct EchoCompletionNoticeTests {

    private let echoPhrase = "12 lines are marked as echo"

    @Test func anEchoClusterIsNamedInTheTitleAndTheBody() {
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 0, problemChunkCount: 0, segmentCount: 40, echoLines: 12)
                == "Transcription Complete — echo marked")
        let body = CaptureQualityNotice.completionBody(fileName: "m.json", anomalyCount: 0, problemChunkCount: 0, segmentCount: 40, echoLines: 12)
        #expect(body.hasPrefix("m.json — ") && body.contains(echoPhrase) && body.lowercased().contains("headphones"))
        // No echo cluster: exactly what it always said.
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 0, problemChunkCount: 0, segmentCount: 40, echoLines: 0) == "Transcription Complete")
        #expect(CaptureQualityNotice.completionBody(fileName: "m.json", anomalyCount: 0, problemChunkCount: 0, segmentCount: 40, echoLines: 0) == "m.json")
    }

    /// Echo is information, not a problem with the record: every problem is named before it, and the
    /// body still carries it.
    @Test func everyProblemComesBeforeEchoInTheTitle() {
        func title(anomalies: Int = 0, problems: Int = 0, segments: Int = 40, remote: String? = nil) -> String {
            CaptureQualityNotice.completionTitle(anomalyCount: anomalies, problemChunkCount: problems, segmentCount: segments,
                                                 remoteStatus: remote, echoLines: 12)
        }
        #expect(title(anomalies: 1) == "Transcription Complete — capture anomalies")
        #expect(title(problems: 2) == "Transcription Complete — 2 chunks had processing problems")
        #expect(title(segments: 0) == "Transcription Complete — no speech was transcribed")
        #expect(title(remote: "neverDelivered") == "Transcription Complete — the other side was not captured")
        #expect(title(segments: CaptureQualityNotice.unreadable) == "Transcription finished — Parley couldn't re-read the transcript to check it")
        let body = CaptureQualityNotice.completionBody(fileName: "m.json", anomalyCount: 1, problemChunkCount: 2, segmentCount: 40, echoLines: 12)
        #expect(body.contains("1 capture anomaly") && body.contains("2 chunks had processing problems") && body.contains(echoPhrase))
        // A transcript nobody could re-read says only that.
        #expect(CaptureQualityNotice.completionBody(fileName: "m.json", anomalyCount: CaptureQualityNotice.unreadable, problemChunkCount: 0,
                                                    segmentCount: 40, echoLines: 12) == "m.json — Parley couldn't re-read the transcript to check it")
    }

    private func transcript(_ h: Harness, verdict: String, flagged: Int?) throws -> URL {
        let url = h.tmp.appendingPathComponent("speakers-on.json")
        var metadata: [String: Any] = [
            "capture_provenance": ["quality_anomaly_count": 0],
            "processing_issues": [["chunk": 0, "code": "echo_flagged", "track": "local", "count": 12],
                                  ["chunk": 0, "code": "echo_cluster", "track": "local", "count": 1]],
            "echo_clusters": [[
                "track": "local", "chunk": 0, "label": "Local Speaker 2", "verdict": verdict,
                "segments": 15, "matched_segments": 12, "seconds": 90.0, "matched_seconds": 80.0,
                "words": 180, "matched_words": 150, "share": 0.8889, "matched_remote": ["Remote Speaker 1": 78.0],
            ] as [String: Any]],
        ]
        if let flagged { metadata["echo_segments_flagged"] = flagged }
        try JSONSerialization.data(withJSONObject: [
            "metadata": metadata,
            "segments": [["start": 0.0, "end": 1.0, "text": "x", "speaker": "Local Speaker 1", "source": "local"]],
        ]).write(to: url)
        return url
    }

    @Test func aFinishedRecordingWithAnEchoClusterSaysSo() async throws {
        let h = try Harness()
        let url = try transcript(h, verdict: "echo", flagged: 12)
        h.appState.phase = .transcribing(progress: "")
        await h.coordinator.presentCompletedTranscription(TranscriptionResult(jsonPath: url))
        let notice = try #require(h.notified.value.last)
        #expect(notice.title == "Transcription Complete — echo marked")
        #expect(notice.body.hasPrefix("speakers-on.json — "))
        #expect(notice.body.contains(echoPhrase) && notice.body.lowercased().contains("headphones"))
        // The rename dialog still opens: the notice is not an alarm.
        #expect(h.presented.value == [url])
    }

    /// Lines flagged in a cluster that was kept (the 3-word rule) are not an echo voice: no notice.
    @Test func aFinishedRecordingWithoutAnEchoClusterIsPlainComplete() async throws {
        let h = try Harness()
        let url = try transcript(h, verdict: "kept", flagged: 2)
        h.appState.phase = .transcribing(progress: "")
        await h.coordinator.presentCompletedTranscription(TranscriptionResult(jsonPath: url))
        #expect(h.notified.value.last?.title == "Transcription Complete")
        #expect(h.notified.value.last?.body == "speakers-on.json")
    }
}

/// What the rename dialog shows after a re-detect, read from the transcript the re-detect wrote: the
/// real `TranscriptRediarizer` (#243) on one side, the dialog's reader on the other, nothing
/// hand-written in between.
@Suite struct EchoNoticeAfterRedetectTests {
    private typealias Fixtures = TranscriptRediarizerEchoGuardTests

    /// The user plus the other side's voice through the loudspeakers, re-detected at "1 speaker on
    /// this side": one person, an echo voice that explains itself, and a stepper that offers 1.
    @Test func afterARedetectAtOneTheDialogCountsOnePersonAndExplainsTheEchoVoice() async throws {
        let voices = Fixtures.TwoVoices()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("echo-notice-redetect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // One second of audio per channel: the scripted diarizer never looks at it.
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let files = [dir.appendingPathComponent("call-0_mic.wav"), dir.appendingPathComponent("call-1.wav")]
        for file in files {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
            buffer.frameLength = 16000
            try AVAudioFile(forWriting: file, settings: format.settings).write(from: buffer)
        }
        let transcript = dir.appendingPathComponent("t.json")
        try JSONSerialization.data(withJSONObject: [
            "metadata": ["audio_paths": files.map(\.path), "chunk_durations": [1.0, 1.0]] as [String: Any],
            "segments": voices.segments(own: "Local Speaker 1", bleed: "Local Speaker 2"),
        ]).write(to: transcript)

        let outcome = try await TranscriptRediarizer.rediarize(
            transcript: transcript, source: "local", speakerCount: 1,
            diarizer: Fixtures.ScriptedDiarizer(result: voices.diarization()), scratchDirectory: dir)

        // As the dialog rebuilds itself: the rows and the findings from one parse of the rewritten file.
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: transcript)) as? [String: Any])
        let rows = TranscriptRenamer.collectSpeakerSamples(json: json, maxSamplesPerSpeaker: 3, minSegmentsPerSpeaker: 1).map(\.id)
        let local = rows.filter { $0.hasPrefix("Local ") }
        let findings = EchoNotice.Findings(json: json)

        #expect(local.count == 2)                                    // the user, and the echo voice
        #expect(findings.people(on: "local", rows: local) == 1)      // … of whom one is a person
        #expect(outcome.speakerCount == 1)
        let notices = local.compactMap(findings.cardNotice(forRow:))
        #expect(notices.count == 1)                                  // the user's own card says nothing
        let notice = try #require(notices.first)
        // 10 copies of the remote lines (50 s) and 1 line the remote transcript has no match for (4 s).
        #expect(notice.contains("10 of 11 lines") && notice.contains("93%") && notice.contains("Remote Speaker 1"))
        #expect(notice.contains("The other line "))
        #expect(findings.redetectHint(on: "local") != nil && findings.redetectHint(on: "remote") == nil)
        #expect(findings.completionLines == 10)
        let line = EchoNotice.redetectOutcome(outcome)
        #expect(line == "1 speaker found · 1 echo voice kept separate · 10 lines marked as echo · 11 lines relabeled")
    }
}
