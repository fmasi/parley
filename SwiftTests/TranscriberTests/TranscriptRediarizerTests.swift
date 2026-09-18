import Testing
import Foundation
import AVFoundation
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

    /// `mergeRelabeled` is a pure replace, so an empty relabeling empties the channel. That is the
    /// correct behaviour for this function and a catastrophic one for a transcript, which is why
    /// `rediarize` refuses to call it with no labels (`RediarizeError.producedNoLabels`).
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

extension TranscriptRediarizerGuardTests {

    @Test("a recording whose audio is gone reports it instead of failing obscurely")
    func missingAudioReportsNoAudioForChannel() async throws {
        // The storage quota evicts .m4a archives, so a transcript can outlive its audio. The
        // checklist calls this out as a must-verify path and nothing covered it.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rediar-noaudio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("t.json")
        let doc: [String: Any] = [
            "metadata": ["audio_paths": [dir.appendingPathComponent("evicted-0.m4a").path]],
            "segments": [["start": 0.0, "end": 1.0, "text": "hi", "speaker": "Local Speaker 1", "source": "local"]],
        ]
        try JSONSerialization.data(withJSONObject: doc).write(to: transcript)

        do {
            _ = try await TranscriptRediarizer.rediarize(
                transcript: transcript, source: "local", speakerCount: 2, diarizer: FluidAudioDiarizer())
            Issue.record("expected a throw when the archive is gone")
        } catch TranscriptRediarizer.RediarizeError.noAudioForChannel(let channel) {
            #expect(channel == "local")
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }
}

/// What happens to speaker NAMES when a channel is re-diarized (#202).
///
/// The old behaviour kept a name whose exact label survived the new clustering. That is silent
/// mislabelling: "Remote Speaker 1" after a re-run is whichever cluster the new pass happened to
/// emit first, which can be a different person. On a record this product positions as
/// courtroom-grade, re-pointing a name at the wrong voice is far worse than losing the name — so
/// the re-diarized channel's names are cleared outright and stashed for recovery.
@Suite("TranscriptRediarizer speaker names")
struct TranscriptRediarizerNameClearingTests {

    private func names(_ metadata: [String: Any], _ key: String) -> [String: String]? {
        metadata[key] as? [String: String]
    }

    @Test("clears the re-diarized channel's names and stashes them, leaving the other channel alone")
    func clearsOnlyTheTargetChannel() {
        let metadata: [String: Any] = [
            "speaker_names": ["Remote Speaker 1": "Paul", "Local Speaker 1": "Fred"],
            "audio_paths": ["/tmp/a.m4a"],
        ]
        let out = TranscriptRediarizer.clearingChannelNames(in: metadata, source: "remote")
        #expect(names(out, "speaker_names") == ["Local Speaker 1": "Fred"])
        #expect(names(out, TranscriptRediarizer.previousNamesKey) == ["Remote Speaker 1": "Paul"])
        // Everything else in the metadata is none of this function's business.
        #expect(out["audio_paths"] as? [String] == ["/tmp/a.m4a"])
    }

    @Test("stashing merges into an existing history instead of overwriting the other channel's")
    func stashMergesWithExistingHistory() {
        let metadata: [String: Any] = [
            "speaker_names": ["Remote Speaker 1": "Paul"],
            TranscriptRediarizer.previousNamesKey: ["Local Speaker 1": "Fred"],
        ]
        let out = TranscriptRediarizer.clearingChannelNames(in: metadata, source: "remote")
        #expect(names(out, TranscriptRediarizer.previousNamesKey)
                == ["Local Speaker 1": "Fred", "Remote Speaker 1": "Paul"])
    }

    @Test("a second re-detect stashes the newer name for a repeated label")
    func newerNameWinsInTheStash() {
        // Re-detect #1 stashed "Paul" under this key; the user then named the new cluster "Anna"
        // and re-detected again. The stash is a recovery aid, so the most recent answer is the
        // useful one to keep.
        let metadata: [String: Any] = [
            "speaker_names": ["Remote Speaker 1": "Anna"],
            TranscriptRediarizer.previousNamesKey: ["Remote Speaker 1": "Paul"],
        ]
        let out = TranscriptRediarizer.clearingChannelNames(in: metadata, source: "remote")
        #expect(names(out, TranscriptRediarizer.previousNamesKey) == ["Remote Speaker 1": "Anna"])
    }

    @Test("clearing the last name removes speaker_names rather than leaving an empty map")
    func emptyMapIsRemoved() {
        let metadata: [String: Any] = ["speaker_names": ["Local Speaker 1": "Fred"]]
        let out = TranscriptRediarizer.clearingChannelNames(in: metadata, source: "local")
        #expect(out["speaker_names"] == nil)
        #expect(names(out, TranscriptRediarizer.previousNamesKey) == ["Local Speaker 1": "Fred"])
    }

    @Test("a channel with no names is left exactly as it was")
    func noNamesIsANoOp() {
        let metadata: [String: Any] = ["speaker_names": ["Local Speaker 1": "Fred"]]
        let out = TranscriptRediarizer.clearingChannelNames(in: metadata, source: "remote")
        #expect(names(out, "speaker_names") == ["Local Speaker 1": "Fred"])
        // No empty stash either: a key that appears only when nothing was stashed is noise in a
        // file people read.
        #expect(out[TranscriptRediarizer.previousNamesKey] == nil)
    }

    @Test("metadata with no speaker_names at all is untouched")
    func missingSpeakerNamesIsANoOp() {
        let out = TranscriptRediarizer.clearingChannelNames(in: ["duration": 12.0], source: "local")
        #expect(out["speaker_names"] == nil)
        #expect(out[TranscriptRediarizer.previousNamesKey] == nil)
        #expect(out["duration"] as? Double == 12.0)
    }

    @Test("names on a channel are reported so the dialog can warn before clearing them")
    func channelNamesAreReportable() {
        let metadata: [String: Any] = [
            "speaker_names": ["Remote Speaker 1": "Paul", "Local Speaker 1": "Fred"]
        ]
        #expect(TranscriptRediarizer.channelNames(in: metadata, source: "remote")
                == ["Remote Speaker 1": "Paul"])
        #expect(TranscriptRediarizer.channelNames(in: [:], source: "remote").isEmpty)
    }
}

/// `rediarize`'s `onProgress` plumbing for the `.samples` path (`.chunkedArchives` — the case
/// with a decoded-buffer/progress callback to wire up at all) went unexercised by any test:
/// `FakeDiarizer` used to silently drop the `progress` callback it was handed, so a regression in
/// `rediarize`'s progress-forwarding closure (a divide-by-zero on `total == 0`, or reporting the
/// wrong phase) wouldn't have been caught.
@Suite(.serialized)
struct TranscriptRediarizerProgressTests {

    /// A single mic-only WAV chunk classifies as `.chunkedArchives` (not `.legacyDualStream`,
    /// which has no per-chunk progress fraction at all — see `SpeakerSampleLocator.classify`),
    /// so it exercises the `diarize(audio:numSpeakers:progress:)` branch this suite targets.
    private func makeMicOnlyRecording() throws -> (transcript: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rediar-progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let wav = dir.appendingPathComponent("call-0_mic.wav")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let frameCount = 16000
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let file = try AVAudioFile(forWriting: wav, settings: format.settings)
        try file.write(from: buffer)

        let transcript = dir.appendingPathComponent("t.json")
        let doc: [String: Any] = [
            "metadata": ["audio_paths": [wav.path]],
            "segments": [["start": 0.0, "end": 1.0, "text": "hi", "speaker": "Local Speaker 1", "source": "local"]],
        ]
        try JSONSerialization.data(withJSONObject: doc).write(to: transcript)

        return (transcript, { try? FileManager.default.removeItem(at: dir) })
    }

    /// Plain lock-protected accumulator rather than an actor: `onProgress` is a synchronous
    /// `@Sendable` closure, and recording synchronously (no spawned `Task`) means the test doesn't
    /// need to guess at a delay before every call has landed.
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [TranscriptRediarizer.Progress] = []
        func record(_ p: TranscriptRediarizer.Progress) {
            lock.lock(); defer { lock.unlock() }
            stored.append(p)
        }
        var phases: [TranscriptRediarizer.Progress] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    @Test("reports decodingAudio then detectingSpeakers, with the diarizer's own fraction forwarded")
    func progressSequenceMatchesDiarizerCallback() async throws {
        let (transcript, cleanup) = try makeMicOnlyRecording()
        defer { cleanup() }

        let log = ProgressLog()
        _ = try await TranscriptRediarizer.rediarize(
            transcript: transcript, source: "local", speakerCount: 1,
            diarizer: FakeDiarizer(),
            onProgress: { log.record($0) })

        let phases = log.phases
        #expect(phases.contains { $0.phase == .decodingAudio })
        // FakeDiarizer.diarize(audio:numSpeakers:progress:) calls progress(1, 2) then
        // progress(2, 2) — both should reach here as detectingSpeakers with the matching fraction.
        #expect(phases.contains { $0.phase == .detectingSpeakers && $0.fraction == 0.5 })
        #expect(phases.contains { $0.phase == .detectingSpeakers && $0.fraction == 1.0 })
    }
}

/// `AudioDecode` mirrors FluidAudio's own decode algorithm rather than calling it directly (a
/// Swift name collision makes the real `AudioConverter` class unreachable from this module — see
/// the type's doc comment in `TranscriptRediarizer.swift`). That reimplementation is exactly the
/// part of PR #218 flagged as needing a device A/B before merge, so this suite exists to catch a
/// gross format mismatch (wrong frame count, wrong channel handling, wrong output rate) even
/// though it can't substitute for the device comparison against FluidAudio's real converter.
@Suite(.serialized)
struct AudioDecodeTests {

    private enum TestHelperError: Error { case cannotCreateBuffer }

    /// A mono or stereo sine-wave WAV at an arbitrary sample rate, written to `url`.
    private func writeTestWav(
        at url: URL, durationSeconds: Double, sampleRate: Double, channels: UInt32
    ) throws {
        let frameCount = Int(sampleRate * durationSeconds)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false
        )!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw TestHelperError.cannotCreateBuffer
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for channel in 0..<Int(channels) {
            let ptr = buffer.floatChannelData![channel]
            for i in 0..<frameCount {
                let t = Double(i) / sampleRate
                ptr[i] = Float(sin(2.0 * .pi * 440.0 * t))
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func tempWavURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("audiodecode-test-\(UUID().uuidString).wav")
    }

    @Test("a file already at 16kHz mono passes through with the same frame count")
    func alreadyTargetRatePassesThroughFrameCount() throws {
        let url = tempWavURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTestWav(at: url, durationSeconds: 1.0, sampleRate: 16000, channels: 1)

        let samples = try AudioDecode.mono16kHzFloat(contentsOf: url)
        #expect(samples.count == 16000)
    }

    @Test("a 48kHz source is downsampled to land within tolerance of the 16kHz-equivalent frame count")
    func downsamplesToTargetRate() throws {
        let url = tempWavURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTestWav(at: url, durationSeconds: 2.0, sampleRate: 48000, channels: 1)

        let samples = try AudioDecode.mono16kHzFloat(contentsOf: url)
        // 2s at 16kHz == 32000 frames. AVAudioConverter's resampler can land a few dozen frames
        // either side of the exact ratio — this checks it's in the right ballpark, not exact.
        let expected = 32000
        #expect(abs(samples.count - expected) < 200)
    }

    @Test("a stereo source is mixed down to mono — one sample per frame, not one per channel")
    func stereoIsMixedToMono() throws {
        let url = tempWavURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTestWav(at: url, durationSeconds: 1.0, sampleRate: 16000, channels: 2)

        let samples = try AudioDecode.mono16kHzFloat(contentsOf: url)
        // Both channels carry the same 440Hz tone, so a correct mixdown lands at ~1 frame per
        // input frame, not 2 (which is what a raw interleaved read gone wrong would produce).
        #expect(abs(samples.count - 16000) < 200)
    }

    @Test("an empty (zero-frame) file decodes to an empty array rather than throwing")
    func emptyFileDecodesToEmptyArray() throws {
        let url = tempWavURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTestWav(at: url, durationSeconds: 0.0, sampleRate: 16000, channels: 1)

        let samples = try AudioDecode.mono16kHzFloat(contentsOf: url)
        #expect(samples.isEmpty)
    }

    /// 44.1kHz -> 16kHz is a non-integer ratio (unlike the app's actual 48kHz -> 16kHz, which is
    /// exactly 3:1) — the kind of source a USB headset or some capture hardware can hand the
    /// pipeline. A resampling filter with nonzero internal latency can leave a few trailing
    /// frames unflushed after a single `convert()` call even with output headroom to spare; a
    /// truncated result here would mean `resample`'s drain loop regressed to trusting one call.
    @Test("a non-integer-ratio source (44.1kHz) is not silently truncated at the tail")
    func nonIntegerRatioDoesNotTruncate() throws {
        let url = tempWavURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTestWav(at: url, durationSeconds: 5.0, sampleRate: 44100, channels: 1)

        let samples = try AudioDecode.mono16kHzFloat(contentsOf: url)
        // 5s at 16kHz == 80000 frames. A resampler that silently dropped its final flush pass
        // would come up short by however many frames its internal latency buffered — this
        // tolerance is generous on the ratio itself but would still catch a dropped flush of any
        // real size (a typical polyphase filter's latency is tens to low hundreds of frames).
        let expected = 80000
        #expect(abs(samples.count - expected) < 400)
    }
}
