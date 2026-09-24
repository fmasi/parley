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

@Suite(.serialized)
struct TranscriptRediarizerTimelineTests {
    /// Counts the samples the diarizer received, so timeline padding is observable.
    final class CountingDiarizer: DiarizationProvider, @unchecked Sendable {
        private(set) var samplesSeen = 0
        func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult {
            try await FakeDiarizer().diarize(audioPath: audioPath, numSpeakers: numSpeakers)
        }
        func diarize(audio: [Float], numSpeakers: Int?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult {
            samplesSeen = audio.count
            return try await FakeDiarizer().diarize(audio: audio, numSpeakers: numSpeakers, progress: progress)
        }
    }

    private func writeSilentWav(at url: URL, seconds: Double) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * 16000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }

    /// Chunk 0 = mic-only WAV (`.skip` for the remote channel, 10 s); chunk 1 = system-only WAV (1 s).
    private func makeTwoChunkRecording(withDurations: Bool = true) throws -> (transcript: URL, chunk1: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rediar-timeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mic0 = dir.appendingPathComponent("call-0_mic.wav"), sys1 = dir.appendingPathComponent("call-1.wav")
        try writeSilentWav(at: mic0, seconds: 10); try writeSilentWav(at: sys1, seconds: 1)
        var metadata: [String: Any] = ["audio_paths": [mic0.path, sys1.path]]
        if withDurations { metadata["chunk_durations"] = [10.0, 1.0] }
        let transcript = dir.appendingPathComponent("t.json")
        try JSONSerialization.data(withJSONObject: [
            "metadata": metadata,
            "segments": [["start": 10.2, "end": 10.8, "text": "hi", "speaker": "Remote Speaker 1", "source": "remote"]],
        ]).write(to: transcript)
        return (transcript, sys1, { try? FileManager.default.removeItem(at: dir) })
    }

    /// P5: a `.skip` chunk contributed nothing and every later chunk's timeline shifted by its length.
    @Test func skipChunksArePaddedWithTheirDuration() async throws {
        let (t, _, cleanup) = try makeTwoChunkRecording(); defer { cleanup() }
        let d = CountingDiarizer()
        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: d)
        #expect(d.samplesSeen == 11 * 16_000)
    }

    /// R6 review round 1: with no `chunk_durations` the skipped chunk's length is read from its file.
    @Test func aMissingDurationFallsBackToTheFile() async throws {
        let (t, _, cleanup) = try makeTwoChunkRecording(withDurations: false); defer { cleanup() }
        let d = CountingDiarizer()
        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: d)
        #expect(d.samplesSeen == 11 * 16_000)
    }

    /// ...and refused only when the file cannot say either. The message names the chunk by
    /// position, never by file name (file names name the meeting).
    @Test func aSkipChunkWithUnknownDurationIsRefused() async throws {
        let (t, _, cleanup) = try makeTwoChunkRecording(withDurations: false); defer { cleanup() }
        let mic0 = t.deletingLastPathComponent().appendingPathComponent("call-0_mic.wav")
        try Data("not audio".utf8).write(to: mic0)
        do {
            _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: FakeDiarizer())
            Issue.record("expected chunkDurationUnknown")
        } catch TranscriptRediarizer.RediarizeError.chunkDurationUnknown(let chunk, let total) {
            #expect(chunk == 1 && total == 2)
            #expect(TranscriptRediarizer.RediarizeError.chunkDurationUnknown(chunk: 1, of: 2).errorDescription?.contains("call-") == false)
        }
    }

    @Test func aMissingListedChunkIsRefused() async throws {
        let (t, chunk1, cleanup) = try makeTwoChunkRecording(); defer { cleanup() }
        try FileManager.default.removeItem(at: chunk1)
        do {
            _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: FakeDiarizer())
            Issue.record("expected chunkMissing")
        } catch TranscriptRediarizer.RediarizeError.chunkMissing(let chunk, let total) {
            #expect(chunk == 2 && total == 2)
            #expect(TranscriptRediarizer.RediarizeError.chunkMissing(chunk: 2, of: 2).errorDescription == "Chunk 2 of 2 is missing — re-detect cannot rebuild the timeline without it.")
        }
    }

    /// R6 review round 1: the backup holds the pipeline's ORIGINAL, written once and never
    /// overwritten, and does not end in `.json` (folder scanners would read it as a second meeting).
    @Test func aBackupIsWrittenOnceAndKeepsTheOriginal() async throws {
        let (t, _, cleanup) = try makeTwoChunkRecording(); defer { cleanup() }
        let before = try Data(contentsOf: t)
        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: FakeDiarizer())
        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 2, diarizer: FakeDiarizer())
        let backup = t.appendingPathExtension("bak")
        #expect(backup.lastPathComponent == "t.json.bak")
        #expect(try Data(contentsOf: backup) == before)
        #expect(try Data(contentsOf: t) != before)
    }

    /// R6 review round 1: a re-detect must not drop words — no second VAD pass.
    @Test func theUnflaggedSegmentCountIsUnchanged() async throws {
        let (t, _, cleanup) = try makeTwoChunkRecording(); defer { cleanup() }
        func unflagged() throws -> Int {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: t)) as? [String: Any]
            return (json?["segments"] as? [[String: Any]] ?? []).filter { !TranscriptAssembler.isFlagged($0) }.count
        }
        let before = try unflagged()
        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: FakeDiarizer())
        #expect(try unflagged() == before)
    }

    /// R6 review round 1: without a speech map the "low diarizer quality → Unknown" step was
    /// skipped; a full-coverage map keeps it (and filters nothing).
    @Test func lowDiarizerQualityStillReadsUnknown() async throws {
        let (t, _, cleanup) = try makeTwoChunkRecording(); defer { cleanup() }
        struct LowQualityDiarizer: DiarizationProvider {
            func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult { result }
            func diarize(audio: [Float], numSpeakers: Int?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult { result }
            var result: DiarizationResult {
                DiarizationResult(segments: [DiarizedSegment(start: 0, end: 5, speaker: "S2", qualityScore: 0.9),
                                             DiarizedSegment(start: 10, end: 11, speaker: "S1", qualityScore: 0.1)],
                                  speakerDatabase: ["S1": [1, 0, 0], "S2": [0, 1, 0]])
            }
        }
        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 2, diarizer: LowQualityDiarizer())
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: t)) as? [String: Any]
        let seg = try #require((json?["segments"] as? [[String: Any]])?.first { $0["text"] as? String == "hi" })
        #expect(seg["speaker"] as? String == "Remote Unknown")
    }

    /// P10/P11: a flagged segment (echo / filtered) is not relabeled and keeps its flag — otherwise
    /// a re-detect would silently bring hidden echo text back into the TXT, SRT and summary.
    @Test func flaggedSegmentsSurviveARedetectUnchanged() async throws {
        let (t, _, cleanup) = try makeTwoChunkRecording(); defer { cleanup() }
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: t)) as? [String: Any])
        var segments = try #require(json["segments"] as? [[String: Any]])
        segments.append(["start": 10.3, "end": 10.7, "text": "bleed", "speaker": "Remote Unknown", "source": "remote", "filtered": true])
        segments.append(["start": 10.75, "end": 10.9, "text": "hi", "speaker": "Remote Speaker 1", "source": "remote", "duplicate": true])
        json["segments"] = segments
        try JSONSerialization.data(withJSONObject: json).write(to: t)

        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: FakeDiarizer())

        let after = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: t)) as? [String: Any])
        let out = try #require(after["segments"] as? [[String: Any]])
        let flagged = try #require(out.first { $0["text"] as? String == "bleed" })
        #expect(flagged["filtered"] as? Bool == true)
        #expect(flagged["speaker"] as? String == "Remote Unknown")
        #expect(out.filter { $0["duplicate"] as? Bool == true }.count == 1, "a duplicate keeps its flag too")
        #expect(out.count == 3)
    }

    /// R5 review round 1: a re-detect at a stated count undoes the absorption on that channel, so
    /// its `clusters_absorbed` issue goes — the rename dialog's hint would otherwise stay stale.
    @Test func aRedetectClearsTheChannelsAbsorptionIssue() async throws {
        let (t, _, cleanup) = try makeTwoChunkRecording(); defer { cleanup() }
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: t)) as? [String: Any])
        var metadata = try #require(json["metadata"] as? [String: Any])
        metadata["processing_issues"] = [
            ["chunk": 0, "code": "clusters_absorbed", "track": "remote", "count": 1],
            ["chunk": 0, "code": "clusters_absorbed", "track": "local", "count": 1],
            ["chunk": 1, "code": "asr_failed", "track": "remote"],
        ]
        json["metadata"] = metadata
        try JSONSerialization.data(withJSONObject: json).write(to: t)

        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: FakeDiarizer())

        let after = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: t)) as? [String: Any])
        let issues = try #require((after["metadata"] as? [String: Any])?["processing_issues"] as? [[String: Any]])
        #expect(issues.map { "\($0["code"]!)/\($0["track"]!)" } == ["clusters_absorbed/local", "asr_failed/remote"])
    }

    // MARK: - Pipeline-produced transcripts (R6 review round 1)

    /// Labels S1, S2, … one per contiguous stretch of non-zero samples, so the labels show where the
    /// diarizer SAW the audio.
    struct EnergyDiarizer: DiarizationProvider {
        func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult { DiarizationResult(segments: []) }
        func diarize(audio: [Float], numSpeakers: Int?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult {
            let window = 1_600
            var segments: [DiarizedSegment] = []
            var db: [String: [Float]] = [:]
            var runStart: Int?
            func close(_ end: Int) {
                guard let s = runStart else { return }
                let name = "S\(segments.count + 1)"
                segments.append(DiarizedSegment(start: Double(s) / 16_000, end: Double(end) / 16_000, speaker: name))
                db[name] = segments.count == 1 ? [1, 0, 0] : [0, 1, 0]
                runStart = nil
            }
            var i = 0
            while i < audio.count {
                let upper = min(audio.count, i + window)
                let active = audio[i..<upper].contains { $0 != 0 }
                if active, runStart == nil { runStart = i }
                if !active { close(i) }
                i = upper
            }
            close(audio.count)
            return DiarizationResult(segments: segments, speakerDatabase: db)
        }
    }

    private func writeToneWav(at url: URL, seconds: Double) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * 16000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(sin(2.0 * .pi * 440 * Double(i) / 16000)) * 0.5 }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }

    /// Finalize a session whose chunks fell back to WAV, the way the pipeline writes it.
    @MainActor
    private func finalizedTranscript(in dir: URL, chunks: [ProcessedChunk], meetingStart: Date, gaps: [CaptureGap] = []) async throws -> URL {
        let state = SessionState(sessionId: "call", meetingStart: meetingStart, engine: "fluid_audio", chunkDurationMinutes: 10,
                                 chunks: chunks, gaps: gaps)
        return try await TranscriptionRunner().finalize(sessionState: state, outputDirectory: dir, config: .default).jsonPath
    }

    /// (a) finalize stamps `chunk_durations` (and offsets), so a skipped chunk is padded without
    /// any hand-written metadata.
    @Test func aPipelineTranscriptIsPaddedAcrossASkippedChunk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rediar-pipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeToneWav(at: dir.appendingPathComponent("call-0_mic.wav"), seconds: 10)
        try writeToneWav(at: dir.appendingPathComponent("call-1.wav"), seconds: 1)
        let t0 = Date(timeIntervalSince1970: 0)
        let t = try await finalizedTranscript(in: dir, chunks: [
            ProcessedChunk(index: 0, startTime: t0, audioPath: "call-0_mic.wav",
                           segments: [.init(start: 1, end: 2, text: "mine", speaker: "Local Speaker 1", source: "local")],
                           speakerDatabase: [:], localSpeakerDatabase: ["Local Speaker 1": [1, 0, 0]], isDualStream: true),
            ProcessedChunk(index: 1, startTime: t0.addingTimeInterval(10), audioPath: "call-1.wav",
                           segments: [.init(start: 0.2, end: 0.8, text: "hi", speaker: "Remote Speaker 1", source: "remote")],
                           speakerDatabase: ["Remote Speaker 1": [0, 1, 0]], isDualStream: true),
        ], meetingStart: t0)
        let meta = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: t)) as? [String: Any])?["metadata"] as? [String: Any])
        #expect((meta["chunk_durations"] as? [Double])?.count == 2)
        let d = CountingDiarizer()
        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: d)
        #expect(d.samplesSeen == 11 * 16_000)
    }

    /// R6 review round 1: a 60 s relaunch gap between two chunks. The transcript places chunk 1 at
    /// its wall-clock offset; re-detect must too, or its labels land on the wrong words.
    @Test func aCaptureGapKeepsLabelsOnTheRightWords() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rediar-gap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeToneWav(at: dir.appendingPathComponent("call-0.wav"), seconds: 2)
        try writeToneWav(at: dir.appendingPathComponent("call-1.wav"), seconds: 2)
        let t0 = Date(timeIntervalSince1970: 0)
        let t = try await finalizedTranscript(in: dir, chunks: [
            ProcessedChunk(index: 0, startTime: t0, audioPath: "call-0.wav",
                           segments: [.init(start: 0.5, end: 1.5, text: "first", speaker: "Speaker 1", source: "remote")],
                           speakerDatabase: ["Speaker 1": [1, 0, 0]]),
            ProcessedChunk(index: 1, startTime: t0.addingTimeInterval(62), audioPath: "call-1.wav",
                           segments: [.init(start: 0.5, end: 1.5, text: "second", speaker: "Speaker 1", source: "remote")],
                           speakerDatabase: ["Speaker 1": [0, 1, 0]]),
        ], meetingStart: t0,
           // The relaunch records the hole it leaves (L7), which is what makes 62 s a plausible offset.
           gaps: [CaptureGap(start: t0.addingTimeInterval(2), end: t0.addingTimeInterval(62), reason: "app relaunch")])
        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 2, diarizer: EnergyDiarizer())
        let segs = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: t)) as? [String: Any])?["segments"] as? [[String: Any]])
        let first = try #require(segs.first { $0["text"] as? String == "first" })
        let second = try #require(segs.first { $0["text"] as? String == "second" })
        #expect(first["speaker"] as? String == "Remote Speaker 1")
        #expect(second["speaker"] as? String == "Remote Speaker 2")
    }

    /// Without recorded offsets, a transcript with capture gaps cannot be re-timed: refuse.
    @Test func gapsWithoutOffsetsAreRefused() async throws {
        let (t, _, cleanup) = try makeTwoChunkRecording(); defer { cleanup() }
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: t)) as? [String: Any])
        var metadata = try #require(json["metadata"] as? [String: Any])
        metadata["capture"] = ["gaps": [["start": "1970-01-01T00:00:10Z", "end": "1970-01-01T00:01:10Z", "seconds": 60.0, "reason": "app relaunch"]]]
        json["metadata"] = metadata
        try JSONSerialization.data(withJSONObject: json).write(to: t)
        await #expect(throws: TranscriptRediarizer.RediarizeError.self) {
            _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: FakeDiarizer())
        }
    }

    // MARK: - Bounded offsets (round 4)

    private func setMetadata(_ t: URL, _ change: (inout [String: Any]) -> Void, segments extra: [[String: Any]] = []) throws {
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: t)) as? [String: Any])
        var metadata = json["metadata"] as? [String: Any] ?? [:]
        change(&metadata)
        json["metadata"] = metadata
        if !extra.isEmpty { json["segments"] = (json["segments"] as? [[String: Any]] ?? []) + extra }
        try JSONSerialization.data(withJSONObject: json).write(to: t)
    }

    /// A chunk re-indexed after a collision is listed out of time order: re-detect orders by offset.
    @Test func chunksAreOrderedByOffsetNotByListOrder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rediar-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let early = dir.appendingPathComponent("call-0.wav"), late = dir.appendingPathComponent("call-5.wav")
        try writeToneWav(at: early, seconds: 2); try writeToneWav(at: late, seconds: 2)
        let t = dir.appendingPathComponent("t.json")
        try JSONSerialization.data(withJSONObject: [
            "metadata": ["audio_paths": [late.path, early.path], "chunk_durations": [2.0, 2.0], "chunk_offsets": [62.0, 0.0],
                         "capture": ["gaps": [["seconds": 60.0, "reason": "app relaunch"]]]],
            "segments": [["start": 0.5, "end": 1.5, "text": "first", "speaker": "Remote Speaker 1", "source": "remote"],
                         ["start": 62.5, "end": 63.5, "text": "second", "speaker": "Remote Speaker 1", "source": "remote"]],
        ]).write(to: t)
        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 2, diarizer: EnergyDiarizer())
        let segs = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: t)) as? [String: Any])?["segments"] as? [[String: Any]])
        #expect(segs.first { $0["text"] as? String == "first" }?["speaker"] as? String == "Remote Speaker 1")
        #expect(segs.first { $0["text"] as? String == "second" }?["speaker"] as? String == "Remote Speaker 2")
    }

    /// A corrupted offset or length must be refused, never trap or allocate gigabytes.
    /// Round 6: implausible offsets get their OWN error — the timing WAS recorded, it is corrupt.
    @Test func outOfRangeOffsetsAreRefusedAsImplausible() async throws {
        for bad: [Double] in [[0, 1e300], [0, -5], [0, 1e6]] {
            let (t, _, cleanup) = try makeTwoChunkRecording(); defer { cleanup() }
            try setMetadata(t) { m in m["chunk_offsets"] = bad }
            do {
                _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: FakeDiarizer())
                Issue.record("expected chunkTimingImplausible for \(bad)")
            } catch TranscriptRediarizer.RediarizeError.chunkTimingImplausible {
            }
        }
        #expect(TranscriptRediarizer.RediarizeError.chunkTimingImplausible.errorDescription
                == "The recording's chunk timing looks corrupted, so re-detect can't place the audio safely.")
    }

    /// A corrupt cached length is not trusted: the file's real length is used instead.
    @Test func anImplausibleCachedLengthFallsBackToTheFile() async throws {
        let (t, _, cleanup) = try makeTwoChunkRecording(); defer { cleanup() }
        try setMetadata(t) { m in m["chunk_durations"] = [1e12, 1] }
        let d = CountingDiarizer()
        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: d)
        #expect(d.samplesSeen == 11 * 16_000)
    }

    /// Round 6 N1: a recording that kept running well past the last word (the user forgot to stop)
    /// is valid — the bound comes from the AUDIO, not from where the words end.
    @Test func chunksFarPastTheLastWordAreAccepted() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rediar-late-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = (0..<3).map { dir.appendingPathComponent("call-\($0).wav") }
        for f in files { try writeToneWav(at: f, seconds: 6) }
        let t = dir.appendingPathComponent("t.json")
        try JSONSerialization.data(withJSONObject: [
            "metadata": ["audio_paths": files.map(\.path), "chunk_durations": [6.0, 6.0, 6.0], "chunk_offsets": [0.0, 6.0, 12.0]],
            "segments": [["start": 0.2, "end": 1.0, "text": "only words", "speaker": "Remote Speaker 1", "source": "remote"]],
        ]).write(to: t)
        let d = CountingDiarizer()
        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: d)
        #expect(d.samplesSeen == 18 * 16_000)
    }

    /// Round 6 N1: a huge (corrupt) segment end no longer widens the bound — no trap.
    @Test func aHugeSegmentEndWithACorruptOffsetDoesNotTrap() async throws {
        let (t, _, cleanup) = try makeTwoChunkRecording(); defer { cleanup() }
        try setMetadata(t, { m in m["chunk_offsets"] = [0.0, 1e200] },
                        segments: [["start": 1e300, "end": 1e300, "text": "corrupt", "speaker": "Remote Speaker 1", "source": "remote"]])
        await #expect(throws: TranscriptRediarizer.RediarizeError.self) {
            _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: FakeDiarizer())
        }
    }

    /// Round 4 item 3: the full-coverage map filters nothing — a zero-length segment included.
    @Test func aZeroLengthSegmentSurvivesARedetect() async throws {
        let (t, _, cleanup) = try makeTwoChunkRecording(); defer { cleanup() }
        try setMetadata(t, { _ in }, segments: [["start": 10.5, "end": 10.5, "text": "blip", "speaker": "Remote Speaker 1", "source": "remote"]])
        // Low diarizer quality under the blip: with the gate ON a zero-length segment has no speech
        // overlap, and low speech + low quality is exactly what the gate filters.
        struct LowQuality: DiarizationProvider {
            func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult { result }
            func diarize(audio: [Float], numSpeakers: Int?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult { result }
            var result: DiarizationResult {
                DiarizationResult(segments: [DiarizedSegment(start: 0, end: 5, speaker: "S2", qualityScore: 0.9),
                                             DiarizedSegment(start: 10, end: 11, speaker: "S1", qualityScore: 0.1)],
                                  speakerDatabase: ["S1": [1, 0, 0], "S2": [0, 1, 0]])
            }
        }
        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 2, diarizer: LowQuality())
        let segs = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: t)) as? [String: Any])?["segments"] as? [[String: Any]])
        let blip = try #require(segs.first { $0["text"] as? String == "blip" })
        #expect(!TranscriptAssembler.isFlagged(blip))
    }

    // MARK: - The timeline bound (round 7)

    /// A real overnight gap (> 1 day) is honoured; the gap TOTAL is capped at the recording's
    /// wall-clock span, so a pile of corrupt gaps cannot widen the bound without limit.
    @Test func theBoundHonoursLongGapsButCapsTheirTotal() {
        let overnight = TranscriptRediarizer.timelineBound(fileLengths: [6, 6], cachedDurations: [], gapSeconds: [89_994], offsets: [0, 90_000])
        #expect(overnight >= 90_000)
        let piled = TranscriptRediarizer.timelineBound(fileLengths: [6, 6], cachedDurations: [], gapSeconds: [1e6, 1e6, .infinity, -3], offsets: [0, 100])
        #expect(piled == 12 + 106 + 6)
        let noOffsets = TranscriptRediarizer.timelineBound(fileLengths: [6, 6], cachedDurations: [], gapSeconds: [1e9], offsets: nil)
        #expect(noOffsets == 12 + 7 * 86_400 + 6)
    }

    /// An unreadable chunk file does not shrink the bound: its cached length counts, else one chunk.
    @Test func unreadableChunksStillCountTowardTheBound() {
        #expect(TranscriptRediarizer.timelineBound(fileLengths: [nil, 6], cachedDurations: [10, 6], gapSeconds: [], offsets: nil) == 16 + 10)
        #expect(TranscriptRediarizer.timelineBound(fileLengths: [nil, 6], cachedDurations: [], gapSeconds: [], offsets: nil) == 12 + 6)
    }
}

/// R2b item 5.
@Suite struct TranscriptRediarizerTimelessSegmentTests {
    private func seg(_ start: Double, _ end: Double, _ speaker: String, _ source: String, _ text: String) -> [String: Any] {
        ["start": start, "end": end, "speaker": speaker, "source": source, "text": text, "confidence": 0.9]
    }
    private func labeled(_ start: Double, _ end: Double, _ speaker: String, _ text: String) -> LabeledSegment {
        LabeledSegment(start: start, end: end, speaker: speaker, text: text, source: "local", confidence: 0.9)
    }

    /// R2b item 5: re-detect replaced the channel wholesale and its relabel input skipped a segment
    /// with no time, so the words were DROPPED. It is kept untouched, after the timed ones (never at 0).
    @Test("a segment without a time is kept untouched, never dropped or moved to 0")
    func aTimelessSegmentSurvivesRedetect() {
        var timeless = seg(0, 0, "Local Speaker 1", "local", "no time")
        timeless["start"] = NSNull(); timeless["end"] = NSNull(); timeless["time_unknown"] = true
        let original = [seg(3, 5, "Local Speaker 1", "local", "a"), timeless, seg(5, 10, "Remote Speaker 1", "remote", "b")]
        let merged = TranscriptRediarizer.mergeRelabeled(into: original, source: "local", relabeled: [labeled(3, 5, "Local Speaker 2", "a")])
        #expect(merged.map { $0["text"] as? String } == ["a", "b", "no time"])
        #expect(merged.last?["speaker"] as? String == "Local Speaker 1" && merged.last?["start"] is NSNull)
    }
}
