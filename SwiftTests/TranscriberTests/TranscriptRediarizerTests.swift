import Testing
import Foundation
@testable import TranscriberCore

/// Rewriting one channel's speakers after a re-diarization (#67).
///
/// Re-diarization is NOT a relabel in place: word-level boundary splitting (#120) can turn one
/// ASR segment into two when a speaker change lands mid-segment. On `150633-Paul feedback` it
/// turned 73 segments into 84. So the operation replaces one source's segments wholesale and
/// leaves the other source untouched.
@Suite("TranscriptRediarizer")
struct TranscriptRediarizerTests {

    private func seg(_ start: Double, _ end: Double, _ speaker: String, _ source: String, _ text: String) -> [String: Any] {
        ["start": start, "end": end, "speaker": speaker, "source": source, "text": text, "confidence": 0.9]
    }
    private func labeled(_ start: Double, _ end: Double, _ speaker: String, _ text: String) -> LabeledSegment {
        LabeledSegment(start: start, end: end, speaker: speaker, text: text, source: "local", confidence: 0.9)
    }

    @Test("replaces the target source's segments and leaves the other source alone")
    func otherSourceIsUntouched() {
        let original = [
            seg(0, 5, "Local Speaker 1", "local", "mine"),
            seg(5, 10, "Remote Speaker 1", "remote", "theirs"),
        ]
        let merged = TranscriptRediarizer.mergeRelabeled(
            into: original, source: "local",
            relabeled: [labeled(0, 5, "Local Speaker 2", "mine")]
        )
        #expect(merged.count == 2)
        let remote = merged.first { $0["source"] as? String == "remote" }
        #expect(remote?["speaker"] as? String == "Remote Speaker 1")
        let local = merged.first { $0["source"] as? String == "local" }
        #expect(local?["speaker"] as? String == "Local Speaker 2")
    }

    @Test("accepts a different segment count — boundary splitting adds segments")
    func segmentCountMayGrow() {
        let original = [seg(0, 10, "Local Speaker 1", "local", "one long turn")]
        let merged = TranscriptRediarizer.mergeRelabeled(
            into: original, source: "local",
            relabeled: [labeled(0, 4, "Local Speaker 1", "one long"), labeled(4, 10, "Local Speaker 2", "turn")]
        )
        #expect(merged.count == 2)
        #expect(merged.map { $0["speaker"] as? String } == ["Local Speaker 1", "Local Speaker 2"])
    }

    @Test("output is sorted by start time across both sources")
    func outputIsTimeSorted() {
        let original = [
            seg(0, 5, "Local Speaker 1", "local", "a"),
            seg(5, 10, "Remote Speaker 1", "remote", "b"),
            seg(10, 15, "Local Speaker 1", "local", "c"),
        ]
        let merged = TranscriptRediarizer.mergeRelabeled(
            into: original, source: "local",
            relabeled: [labeled(0, 5, "Local Speaker 1", "a"), labeled(10, 15, "Local Speaker 2", "c")]
        )
        #expect(merged.compactMap { $0["start"] as? Double } == [0, 5, 10])
        #expect(merged.map { $0["speaker"] as? String }
                == ["Local Speaker 1", "Remote Speaker 1", "Local Speaker 2"])
    }

    @Test("a stale speaker_names entry for a label that no longer exists is dropped")
    func staleSpeakerNamesAreDropped() {
        // The user named "Local Speaker 3" before re-diarizing; the new run produces only two
        // local speakers. Leaving the stale mapping would re-apply a name to nobody, or worse,
        // to a different person if the numbering shifts.
        let names = ["Local Speaker 1": "Fred", "Local Speaker 3": "Ghost", "Remote Speaker 1": "Paul"]
        let kept = TranscriptRediarizer.prunedSpeakerNames(
            names, source: "local", survivingLabels: ["Local Speaker 1", "Local Speaker 2"]
        )
        #expect(kept == ["Local Speaker 1": "Fred", "Remote Speaker 1": "Paul"])
    }

    @Test("pruning never touches names belonging to the other channel")
    func pruningIsScopedToTheRediarizedChannel() {
        let names = ["Remote Speaker 2": "Someone", "Local Speaker 1": "Fred"]
        let kept = TranscriptRediarizer.prunedSpeakerNames(
            names, source: "local", survivingLabels: ["Local Speaker 1"]
        )
        #expect(kept["Remote Speaker 2"] == "Someone")
    }

    @Test("an empty relabeling removes that source's segments rather than duplicating them")
    func emptyRelabelingClearsTheSource() {
        let original = [
            seg(0, 5, "Local Speaker 1", "local", "a"),
            seg(5, 10, "Remote Speaker 1", "remote", "b"),
        ]
        let merged = TranscriptRediarizer.mergeRelabeled(into: original, source: "local", relabeled: [])
        #expect(merged.count == 1)
        #expect(merged.first?["source"] as? String == "remote")
    }
}

@Suite("TranscriptRediarizer errors")
struct TranscriptRediarizerErrorTests {

    @Test("an unreadable transcript surfaces the underlying OS error, not a generic message")
    func underlyingReadErrorSurfaces() async {
        // `try? Data(contentsOf:)` flattened permission-denied, quota-exceeded and
        // deleted-mid-run into one "Could not read the transcript." with nothing in the log to
        // say which — so a failure report had no way to name its own cause.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        do {
            _ = try await TranscriptRediarizer.rediarize(
                transcript: missing, source: "local", speakerCount: 2,
                diarizer: FluidAudioDiarizer())
            Issue.record("expected a throw for a missing transcript")
        } catch {
            // NSCocoaErrorDomain 260 = NSFileReadNoSuchFileError. The point is that the real
            // error reaches the caller instead of being replaced by our own wording.
            let ns = error as NSError
            #expect(ns.domain == NSCocoaErrorDomain)
            #expect(ns.code == NSFileReadNoSuchFileError)
        }
    }
}

/// How a single chunk file contributes to one channel's audio.
///
/// This is the seam where #183 and #67 meet, and it is wrong until both are together: #183
/// redefined `isSystemOnly` so a `_mic.wav` fallback is no longer "system audio", which means the
/// re-diarize path stopped skipping it for a LOCAL request (correct) but then fell through to
/// `splitChannels` on a MONO file (wrong). Mic-only recordings are exactly the ones the speaker-
/// count control exists for, so this seam has to hold.
@Suite("TranscriptRediarizer channel roles")
struct TranscriptRediarizerChannelRoleTests {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/rec/\(name)") }

    @Test("a stereo archive must be split for either channel")
    func archiveNeedsSplitting() {
        #expect(TranscriptRediarizer.channelRole(of: url("call-0.m4a"), wantsLocal: true) == .needsSplit)
        #expect(TranscriptRediarizer.channelRole(of: url("call-0.m4a"), wantsLocal: false) == .needsSplit)
    }

    @Test("a mic WAV fallback is used directly for the local channel")
    func micWavUsedDirectlyForLocal() {
        #expect(TranscriptRediarizer.channelRole(of: url("call-0_mic.wav"), wantsLocal: true) == .useDirectly)
    }

    @Test("a mic WAV fallback contributes nothing to the remote channel")
    func micWavSkippedForRemote() {
        #expect(TranscriptRediarizer.channelRole(of: url("call-0_mic.wav"), wantsLocal: false) == .skip)
    }

    @Test("a system WAV fallback is used directly for the remote channel")
    func systemWavUsedDirectlyForRemote() {
        #expect(TranscriptRediarizer.channelRole(of: url("call-0.wav"), wantsLocal: false) == .useDirectly)
    }

    @Test("a system WAV fallback contributes nothing to the local channel")
    func systemWavSkippedForLocal() {
        #expect(TranscriptRediarizer.channelRole(of: url("call-0.wav"), wantsLocal: true) == .skip)
    }
}

@Suite("TranscriptRediarizer guards")
struct TranscriptRediarizerGuardTests {

    @Test("a non-positive speaker count is refused rather than silently half-applied")
    func nonPositiveSpeakerCountThrows() async throws {
        // ≤ 0 is not merely ignored: FluidAudioDiarizer treats it as "unforced" (correctly), but
        // the caller still passes speakerCountIsUserStated: true, which DISABLES minority
        // absorption. The result is unforced diarization with the automatic cleanup switched off —
        // neither of the two behaviours anyone asked for.
        //
        // Uses a REAL, readable transcript so the count is the only possible reason to throw: with
        // a nonexistent path this test passes whether or not the guard exists.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rediar-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("t.json")
        let doc: [String: Any] = [
            "metadata": ["audio_paths": []],
            "segments": [["start": 0.0, "end": 1.0, "text": "hi", "speaker": "Local Speaker 1", "source": "local"]],
        ]
        try JSONSerialization.data(withJSONObject: doc).write(to: transcript)
        let before = try Data(contentsOf: transcript)

        for count in [0, -1] {
            do {
                _ = try await TranscriptRediarizer.rediarize(
                    transcript: transcript, source: "local", speakerCount: count,
                    diarizer: FluidAudioDiarizer())
                Issue.record("expected a throw for speakerCount \(count)")
            } catch TranscriptRediarizer.RediarizeError.invalidSpeakerCount(let got) {
                // The SPECIFIC case: an empty audio_paths list throws noAudioForChannel from the
                // same function, so matching on the error type alone passes with no guard at all.
                #expect(got == count)
            } catch {
                Issue.record("wrong error for speakerCount \(count): \(error)")
            }
        }
        // And it must refuse before touching anything.
        #expect(try Data(contentsOf: transcript) == before)
    }
}
