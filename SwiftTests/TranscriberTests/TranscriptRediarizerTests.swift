import Testing
import Foundation
import AVFoundation
@testable import TranscriberCore

/// Rewriting one channel's speakers after a re-diarization (#67).
///
/// Re-diarization is NOT a relabel in place: word-level boundary splitting (#120) can turn one
/// ASR segment into two when a speaker change lands mid-segment. On a speakerphone call with two
/// people on one mic it turned 73 segments into 84. So the operation replaces one source's
/// segments wholesale and leaves the other source untouched.
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

    /// Round 4 item 6: the re-detect's backup and rewrite are durable.
    @Test("the backup and the rewritten transcript are fully synced")
    func rewritesAreDurable() async throws {
        let (transcript, cleanup) = try makeMicOnlyRecording()
        defer { cleanup() }
        let dir = transcript.deletingLastPathComponent()
        DurableFile.startRecordingSyncsForTesting(under: dir)
        defer { DurableFile.stopRecordingSyncsForTesting(under: dir) }
        let before = DurableFile.syncedForTesting.count
        _ = try await TranscriptRediarizer.rediarize(transcript: transcript, source: "local", speakerCount: 1, diarizer: FakeDiarizer())
        let synced = DurableFile.syncedForTesting.dropFirst(before)
        #expect(synced.contains(transcript.path))
        #expect(synced.contains(TranscriptRediarizer.backupURL(for: transcript).path))
    }

    /// #224 review: the storage limit can mark a transcript while a re-detect of it is diarizing.
    /// The re-detect read the file before that; its rewrite must keep the mark, not drop it.
    @Test("a storage-limit mark written while diarization runs survives the rewrite")
    func keepsAudioRemovedMarkWrittenMidway() async throws {
        let (transcript, cleanup) = try makeMicOnlyRecording()
        defer { cleanup() }
        let mark: [String: Any] = ["at": "2026-10-07T10:00:00Z", "files": ["090000.m4a"], "reason": "storage_limit"]
        let marked = MarkOnce(transcript: transcript, mark: mark)
        _ = try await TranscriptRediarizer.rediarize(
            transcript: transcript, source: "local", speakerCount: 1, diarizer: FakeDiarizer(),
            onProgress: { if $0.phase == .detectingSpeakers { marked.write() } })

        #expect(marked.wrote)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: transcript)) as? [String: Any]
        let kept = (json?["metadata"] as? [String: Any])?["audio_removed"] as? [String: Any]
        #expect(kept?["files"] as? [String] == ["090000.m4a"])
    }

    /// Writes the mark into the transcript once — what a storage-limit pass does mid re-detect.
    private final class MarkOnce: @unchecked Sendable {
        private let lock = NSLock()
        private let transcript: URL
        private let mark: [String: Any]
        private var done = false
        init(transcript: URL, mark: [String: Any]) { self.transcript = transcript; self.mark = mark }
        var wrote: Bool { lock.lock(); defer { lock.unlock() }; return done }
        func write() {
            lock.lock(); defer { lock.unlock() }
            guard !done,
                  let data = try? Data(contentsOf: transcript),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            var metadata = json["metadata"] as? [String: Any] ?? [:]
            metadata["audio_removed"] = mark
            json["metadata"] = metadata
            guard let out = try? JSONSerialization.data(withJSONObject: json) else { return }
            try? out.write(to: transcript)
            done = true
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

    /// R6 review round 1: a re-detect must not drop words — no second VAD pass. It is a relabel: the
    /// number of segments and every text are what they were (#243).
    @Test func theUnflaggedSegmentCountIsUnchanged() async throws {
        let (t, _, cleanup) = try makeTwoChunkRecording(); defer { cleanup() }
        try setMetadata(t, { _ in }, segments: [
            ["start": 10.3, "end": 10.6, "text": "kept apart", "speaker": "Remote Unknown", "source": "remote", "filtered": true],
            ["start": 2.0, "end": 3.0, "text": "this side", "speaker": "Local Speaker 1", "source": "local"],
        ])
        func segments() throws -> [[String: Any]] {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: t)) as? [String: Any]
            return json?["segments"] as? [[String: Any]] ?? []
        }
        func texts() throws -> [String] { try segments().compactMap { $0["text"] as? String }.sorted() }
        let before = try segments(), textsBefore = try texts()
        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: FakeDiarizer())
        #expect(try segments().filter { !TranscriptAssembler.isFlagged($0) }.count == before.filter { !TranscriptAssembler.isFlagged($0) }.count)
        #expect(try segments().count == before.count)
        #expect(try texts() == textsBefore)
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
        // ...but not the label an earlier diarization gave it (#296).
        #expect(out.first { $0["duplicate"] as? Bool == true }?["speaker"] as? String == "Remote Unknown")
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

// MARK: - The echo guard (#243)

/// Re-detect at a stated count must not hand the other side's words to the user.
///
/// With the far side on loudspeakers its voice comes back through the mic, and the diarizer finds it
/// as a second cluster on the local channel. A user who then says "one speaker on this side" got
/// that cluster merged into their own: on a real call about 2,400 of the other participant's words
/// took the user's name. Re-detect now runs the echo check on the RAW clusters, before the count is
/// enforced, and keeps the clusters it judges echo out of the merge.
///
/// Every fixture here is procedural: made-up words, no recording.
@Suite(.serialized)
struct TranscriptRediarizerEchoGuardTests {

    /// Answers every request with one fixed result — the clusters a real diarizer would have found.
    struct ScriptedDiarizer: DiarizationProvider {
        let result: DiarizationResult
        func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult { result }
        func diarize(audio: [Float], numSpeakers: Int?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult { result }
    }

    struct Line {
        let start: Double, end: Double, text: String
    }

    /// `count` made-up words that appear nowhere else: "own3x0 own3x1 …".
    static func words(_ tag: String, _ count: Int) -> String {
        (0..<count).map { "\(tag)x\($0)" }.joined(separator: " ")
    }

    /// `count` lines of `length` seconds, one every 20 s from `offset`, each with its own words.
    static func lines(_ tag: String, count: Int, offset: Double, length: Double, words wordCount: Int = 6) -> [Line] {
        (0..<count).map { i in
            Line(start: Double(i) * 20 + offset, end: Double(i) * 20 + offset + length, text: words("\(tag)\(i)", wordCount))
        }
    }

    static func segment(_ line: Line, _ speaker: String, _ source: String, echo: Bool = false) -> [String: Any] {
        var d: [String: Any] = ["start": line.start, "end": line.end, "speaker": speaker, "source": source, "text": line.text, "confidence": 0.9]
        if echo { d["echo"] = true }
        return d
    }

    static func turns(_ lines: [Line], _ speaker: String) -> [DiarizedSegment] {
        lines.map { DiarizedSegment(start: $0.start, end: $0.end, speaker: speaker, qualityScore: 0.9) }
    }

    /// A mic channel carrying two voices: the user's `own` lines, which nobody else says, and the far
    /// side's voice through the speakers — a copy of every `far` line at the moment the remote
    /// channel has it (50 s), plus `residue` the remote transcript has no match for (4 s). 0.93 of
    /// the second voice's duration repeats the other channel.
    struct TwoVoices {
        let own = lines("own", count: 10, offset: 0, length: 8)
        let far = lines("far", count: 10, offset: 10, length: 5)
        let residue = [Line(start: 200, end: 204, text: words("residue", 6))]

        /// The user's voice as S1, the echo voice as S2; `echoFirst` lists the echo's turns first, so
        /// it is the one numbered "Speaker 1".
        func diarization(echoFirst: Bool = false) -> DiarizationResult {
            let user = turns(own, "S1"), echo = turns(far + residue, "S2")
            return DiarizationResult(segments: echoFirst ? echo + user : user + echo,
                                     speakerDatabase: ["S1": [1, 0, 0], "S2": [0, 1, 0]])
        }

        func segments(own ownLabel: String, bleed bleedLabel: String, bleedFlagged: Bool = false) -> [[String: Any]] {
            own.map { segment($0, ownLabel, "local") }
                + far.map { segment($0, "Remote Speaker 1", "remote") }
                + far.map { segment($0, bleedLabel, "local", echo: bleedFlagged) }
                + residue.map { segment($0, bleedLabel, "local") }
        }
    }

    /// What an earlier pass left behind: this track's entries must be replaced, the rest kept.
    static let staleEchoMetadata: [String: Any] = [
        "echo_clusters": [
            ["track": "local", "chunk": 0, "label": "Local Speaker 7", "verdict": "kept", "segments": 3],
            ["track": "remote", "chunk": 0, "label": "Remote Speaker 7", "verdict": "kept", "segments": 5],
        ],
        "processing_issues": [
            ["chunk": 0, "code": "echo_flagged", "track": "local", "count": 3],
            ["chunk": 0, "code": "echo_cluster", "track": "local", "count": 4],
            ["chunk": 1, "code": "asr_failed", "track": "remote"],
        ],
    ]

    /// A recording with one second of audio per channel (a mic-only chunk, then a system-only one).
    /// The scripted diarizer never looks at it; re-detect only needs each channel to have audio.
    private func makeRecording(segments: [[String: Any]], metadata extra: [String: Any] = [:]) throws -> (transcript: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rediar-echo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let files = [dir.appendingPathComponent("call-0_mic.wav"), dir.appendingPathComponent("call-1.wav")]
        for file in files {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
            buffer.frameLength = 16000
            try AVAudioFile(forWriting: file, settings: format.settings).write(from: buffer)
        }
        var metadata: [String: Any] = ["audio_paths": files.map(\.path), "chunk_durations": [1.0, 1.0]]
        metadata.merge(extra) { _, new in new }
        let transcript = dir.appendingPathComponent("t.json")
        try JSONSerialization.data(withJSONObject: ["metadata": metadata, "segments": segments]).write(to: transcript)
        return (transcript, { try? FileManager.default.removeItem(at: dir) })
    }

    private func read(_ transcript: URL) throws -> (segments: [[String: Any]], metadata: [String: Any]) {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: transcript)) as? [String: Any])
        return (try #require(json["segments"] as? [[String: Any]]), try #require(json["metadata"] as? [String: Any]))
    }

    /// One channel's segments holding these lines' texts, in time order.
    private func found(_ lines: [Line], in segments: [[String: Any]], source: String = "local") -> [[String: Any]] {
        let texts = Set(lines.map(\.text))
        return segments.filter { $0["source"] as? String == source && texts.contains($0["text"] as? String ?? "") }
    }
    private func speakers(_ segments: [[String: Any]]) -> Set<String> { Set(segments.compactMap { $0["speaker"] as? String }) }
    private func echoCount(_ segments: [[String: Any]]) -> Int { segments.filter { $0["echo"] as? Bool == true }.count }

    /// Every segment's place and words, whatever its label or flags: what a relabel must not change.
    private func record(_ segments: [[String: Any]]) -> [String] {
        segments.map { "\($0["source"] as? String ?? "")|\($0["start"] as? Double ?? .nan)|\($0["end"] as? Double ?? .nan)|\($0["text"] as? String ?? "")" }.sorted()
    }

    private func clusters(_ metadata: [String: Any], track: String) -> [[String: Any]] {
        (metadata["echo_clusters"] as? [[String: Any]] ?? []).filter { $0["track"] as? String == track }
    }
    private func issues(_ metadata: [String: Any]) -> [String] {
        (metadata["processing_issues"] as? [[String: Any]] ?? []).map { issue in
            "\(issue["code"] ?? "")/\(issue["track"] ?? "")/\(issue["count"].map { "\($0)" } ?? "-")/\(issue["chunk"].map { "\($0)" } ?? "-")"
        }
    }

    /// The guarded result for `TwoVoices`, whatever labels the transcript started with.
    private func expectTheEchoVoiceKeptApart(
        _ transcript: URL, _ voices: TwoVoices, _ outcome: TranscriptRediarizer.Outcome, before: [[String: Any]],
        user: String = "Local Speaker 1", echo: String = "Local Speaker 2"
    ) throws {
        let (segments, metadata) = try read(transcript)
        // The user's own lines take the stated speaker.
        #expect(speakers(found(voices.own, in: segments)) == [user])
        #expect(echoCount(found(voices.own, in: segments)) == 0)
        // The echo cluster is not merged: its matched lines are flagged, the rest keep its label.
        #expect(speakers(found(voices.far, in: segments)) == [echo])
        #expect(echoCount(found(voices.far, in: segments)) == voices.far.count)
        #expect(speakers(found(voices.residue, in: segments)) == [echo])
        #expect(echoCount(found(voices.residue, in: segments)) == 0)
        // The other channel is as it was.
        #expect(speakers(found(voices.far, in: segments, source: "remote")) == ["Remote Speaker 1"])
        #expect(echoCount(found(voices.far, in: segments, source: "remote")) == 0)
        // A relabel: no segment gained, lost or reworded.
        #expect(record(segments) == record(before))

        // People, not clusters.
        #expect(metadata["speaker_count_local"] as? Int == 1)
        #expect(outcome.speakerCount == 1)
        #expect(outcome.echoClusters == 1)
        #expect(outcome.echoFlagged == voices.far.count)
        #expect(outcome.segmentsRelabeled == voices.own.count + voices.residue.count)
        #expect(metadata["echo_segments_flagged"] as? Int == voices.far.count)

        // This track's verdicts are the fresh ones — no chunk, the labels the segments now carry.
        let local = clusters(metadata, track: "local")
        #expect(local.compactMap { $0["label"] as? String }.sorted() == [user, echo].sorted())
        #expect(local.allSatisfy { $0["chunk"] == nil })
        let verdict = try #require(local.first { $0["label"] as? String == echo })
        #expect(verdict["verdict"] as? String == "echo")
        #expect(verdict["segments"] as? Int == voices.far.count + voices.residue.count)
        #expect(verdict["matched_segments"] as? Int == voices.far.count)
        #expect(verdict["seconds"] as? Double == 54)
        #expect(verdict["matched_seconds"] as? Double == 50)
        #expect((verdict["share"] as? Double ?? 0) >= 0.9)
        #expect(verdict["matched_remote"] as? [String: Double] == ["Remote Speaker 1": 50])
        #expect(local.first { $0["label"] as? String == user }?["verdict"] as? String == "kept")
        #expect(clusters(metadata, track: "remote").count == 1, "another track's entries are not this re-detect's to replace")
        #expect(issues(metadata) == ["asr_failed/remote/-/1", "echo_flagged/local/\(voices.far.count)/-", "echo_cluster/local/1/-"])
    }

    @Test("two raw clusters at a stated count of 1: the echo cluster is kept out of the merge")
    func theEchoClusterIsNotMergedIntoTheStatedSpeaker() async throws {
        let voices = TwoVoices()
        let before = voices.segments(own: "Local Speaker 1", bleed: "Local Speaker 2")
        let (t, cleanup) = try makeRecording(segments: before, metadata: Self.staleEchoMetadata); defer { cleanup() }
        let outcome = try await TranscriptRediarizer.rediarize(
            transcript: t, source: "local", speakerCount: 1, diarizer: ScriptedDiarizer(result: voices.diarization()))
        try expectTheEchoVoiceKeptApart(t, voices, outcome, before: before)
    }

    /// The repair path: a transcript an earlier re-detect already merged. Every local line is under
    /// the user's label; re-detecting again must find the echo voice and take it back out.
    @Test("re-detecting an already-merged transcript takes the echo voice back out")
    func anAlreadyMergedTranscriptIsRepaired() async throws {
        let voices = TwoVoices()
        let before = voices.segments(own: "Local Speaker 1", bleed: "Local Speaker 1")
        var metadata = Self.staleEchoMetadata
        metadata["speaker_count_local"] = 1
        let (t, cleanup) = try makeRecording(segments: before, metadata: metadata); defer { cleanup() }
        let outcome = try await TranscriptRediarizer.rediarize(
            transcript: t, source: "local", speakerCount: 1, diarizer: ScriptedDiarizer(result: voices.diarization()))
        try expectTheEchoVoiceKeptApart(t, voices, outcome, before: before)
    }

    /// The transcript the pipeline itself writes after such a call: the matched lines already carry
    /// `echo`, the residue does not. Judged on the residue alone the cluster would look like a person
    /// (nothing in it matches) and be merged — so the lines already flagged as echo count as evidence.
    @Test("lines already flagged as echo still count: the residue of an echo cluster is not merged")
    func alreadyFlaggedLinesAreEvidence() async throws {
        let voices = TwoVoices()
        let noise: [String: Any] = ["start": 205.0, "end": 206.0, "speaker": "Local Unknown", "source": "local", "text": Self.words("noise", 4), "filtered": true]
        let before = voices.segments(own: "Local Speaker 1", bleed: "Local Speaker 2", bleedFlagged: true) + [noise]
        let (t, cleanup) = try makeRecording(segments: before, metadata: Self.staleEchoMetadata); defer { cleanup() }
        // The echo voice is the first the diarizer lists, so the numbering flips: it is now
        // "Speaker 1", and the label its flagged lines carried ("Local Speaker 2") is the user's.
        let outcome = try await TranscriptRediarizer.rediarize(
            transcript: t, source: "local", speakerCount: 1, diarizer: ScriptedDiarizer(result: voices.diarization(echoFirst: true)))
        try expectTheEchoVoiceKeptApart(t, voices, outcome, before: before, user: "Local Speaker 2", echo: "Local Speaker 1")
        // A segment flagged for another reason is neither evidence nor touched.
        let kept = try #require(try read(t).segments.first { $0["filtered"] as? Bool == true })
        #expect(kept["speaker"] as? String == "Local Unknown")
        #expect(kept["echo"] == nil)
    }

    /// One blended cluster: the diarizer honoured the count, so there is no echo cluster to keep out.
    /// The per-segment rule still applies.
    @Test("one blended cluster: matches of 3+ words are flagged and unattributed; 1–2-word matches are untouched")
    func aBlendedClusterFlagsOnlyLongMatches() async throws {
        let own = Self.lines("own", count: 10, offset: 0, length: 8)
        let copies = Self.lines("far", count: 3, offset: 10, length: 5)
        let backchannels = [Line(start: 210, end: 211, text: Self.words("yes", 1)), Line(start: 230, end: 231, text: Self.words("fine", 2))]
        // A copy the diarizer gave no turn to: unattributed, and a stated count of 1 folds
        // unattributed speech into the stated speaker.
        let stray = [Line(start: 250, end: 255, text: Self.words("stray", 6))]
        let said = copies + backchannels + stray
        let before = own.map { Self.segment($0, "Local Speaker 1", "local") }
            + said.map { Self.segment($0, "Remote Speaker 1", "remote") }
            + said.map { Self.segment($0, "Local Speaker 2", "local") }
        let (t, cleanup) = try makeRecording(segments: before); defer { cleanup() }
        let blended = DiarizationResult(segments: Self.turns(own + copies + backchannels, "S1"), speakerDatabase: ["S1": [1, 0, 0]])

        let outcome = try await TranscriptRediarizer.rediarize(
            transcript: t, source: "local", speakerCount: 1, diarizer: ScriptedDiarizer(result: blended))

        let (segments, metadata) = try read(t)
        #expect(speakers(found(own, in: segments)) == ["Local Speaker 1"])
        // Flagged, and NOT relabelled to the stated speaker. Nor do they keep the label they had
        // (#277): they are the other side's words, so they belong to nobody on this side.
        #expect(echoCount(found(copies + stray, in: segments)) == 4)
        #expect(speakers(found(copies + stray, in: segments)) == ["Local Unknown"])
        // "Yes." on both sides at once is not an echo: relabelled like any other line.
        #expect(echoCount(found(backchannels, in: segments)) == 0)
        #expect(speakers(found(backchannels, in: segments)) == ["Local Speaker 1"])
        #expect(record(segments) == record(before))
        #expect(metadata["speaker_count_local"] as? Int == 1)
        #expect(outcome.speakerCount == 1)
        #expect(outcome.echoClusters == 0)
        #expect(outcome.echoFlagged == 4)
        #expect(outcome.segmentsRelabeled == own.count + backchannels.count)
        #expect(clusters(metadata, track: "local").allSatisfy { $0["verdict"] as? String == "kept" })
    }

    // MARK: A line flagged outside an echo cluster belongs to nobody on this side (#277)

    /// The user's voice and three copies of the other side in ONE cluster: the diarizer blended them,
    /// so there is no echo cluster and only the per-line rule can flag the copies. Every local line
    /// starts under `label` — what a transcript looks like after a re-detect merged the bleed into
    /// the user.
    struct BlendedVoice {
        let own = lines("own", count: 10, offset: 0, length: 8)
        let copies = lines("far", count: 3, offset: 10, length: 5)

        var diarization: DiarizationResult {
            DiarizationResult(segments: turns(own + copies, "S1"), speakerDatabase: ["S1": [1, 0, 0]])
        }

        func segments(label: String, copiesFlagged: Bool = false) -> [[String: Any]] {
            own.map { segment($0, label, "local") }
                + copies.map { segment($0, "Remote Speaker 1", "remote") }
                + copies.map { segment($0, label, "local", echo: copiesFlagged) }
        }
    }

    /// The defect: the line was flagged and hidden, but kept the label it had before the re-detect.
    /// After a repair that label is the user's, so the JSON paired the other side's words with the
    /// user's label. "Robin" is the same case after the user named the merged speaker.
    @Test("a line the per-line rule flags takes the channel's unattributed label, never a person's",
          arguments: ["Local Speaker 1", "Robin"])
    func aLineFlaggedOutsideAnEchoClusterIsUnattributed(label: String) async throws {
        let voice = BlendedVoice()
        let before = voice.segments(label: label)
        var metadata: [String: Any] = ["speaker_count_local": 1, "rediarized_channels": ["local"]]
        if label != "Local Speaker 1" { metadata["speaker_names"] = ["Local Speaker 1": label] }
        let (t, cleanup) = try makeRecording(segments: before, metadata: metadata); defer { cleanup() }

        let outcome = try await TranscriptRediarizer.rediarize(
            transcript: t, source: "local", speakerCount: 1, diarizer: ScriptedDiarizer(result: voice.diarization))

        let (segments, after) = try read(t)
        // Echo, and nobody's on this side.
        #expect(echoCount(found(voice.copies, in: segments)) == voice.copies.count)
        #expect(speakers(found(voice.copies, in: segments)) == ["Local Unknown"])
        // The user's own lines are the stated speaker, unflagged; the other channel is as it was.
        #expect(speakers(found(voice.own, in: segments)) == ["Local Speaker 1"])
        #expect(echoCount(found(voice.own, in: segments)) == 0)
        #expect(speakers(found(voice.copies, in: segments, source: "remote")) == ["Remote Speaker 1"])
        #expect(record(segments) == record(before))

        // The unattributed label is not a person and not a voice: nothing counts it.
        #expect(after["speaker_count_local"] as? Int == 1)
        #expect(outcome.speakerCount == 1)
        #expect(outcome.echoClusters == 0)
        #expect(outcome.echoFlagged == voice.copies.count)
        #expect(outcome.segmentsRelabeled == voice.own.count)
        #expect(after["echo_segments_flagged"] as? Int == voice.copies.count)
        let local = clusters(after, track: "local")
        #expect(local.compactMap { $0["label"] as? String } == ["Local Speaker 1"])
        #expect(local.allSatisfy { $0["verdict"] as? String == "kept" })
        #expect(EchoNotice.Findings(metadata: after).voices.isEmpty)
    }

    /// What reads the result: the rename dialog's rows, a rename, and the summary.
    @Test("an unattributed echo line is no row to rename, is not reached by a rename, and is no participant")
    func anUnattributedEchoLineIsNobodyDownstream() async throws {
        let voice = BlendedVoice()
        let (t, cleanup) = try makeRecording(segments: voice.segments(label: "Local Speaker 1")); defer { cleanup() }
        _ = try await TranscriptRediarizer.rediarize(
            transcript: t, source: "local", speakerCount: 1, diarizer: ScriptedDiarizer(result: voice.diarization))

        // The dialog offers the people, and the stepper counts one on this side.
        let rows = try TranscriptRenamer.collectSpeakerSamples(from: t, maxSamplesPerSpeaker: 1).map(\.id)
        #expect(Set(rows) == ["Local Speaker 1", "Remote Speaker 1"])
        #expect(EchoNotice.Findings.read(transcriptAt: t).people(on: "local", rows: rows.filter { $0.hasPrefix("Local ") }) == 1)

        // Naming the user does not put the name on the other side's words.
        #expect(TranscriptRenamer.applyRenames(["Local Speaker 1": "Robin"], jsonPath: t))
        let segments = try read(t).segments
        #expect(speakers(found(voice.own, in: segments)) == ["Robin"])
        #expect(speakers(found(voice.copies, in: segments)) == ["Local Unknown"])
        #expect(echoCount(found(voice.copies, in: segments)) == voice.copies.count)

        // The summary sees neither the lines nor a participant for them.
        let (prompt, summary) = try MeetingSummarizer.parseTranscriptForTesting(at: t)
        #expect(summary.speakers == ["Robin", "Remote Speaker 1"])
        #expect(Set(prompt.map(\.speaker)) == ["Robin", "Remote Speaker 1"])
        #expect(prompt.count == voice.own.count + voice.copies.count)
    }

    /// The line was flagged by an EARLIER pass (the pipeline's own per-line rule), and the user then
    /// named the speaker: on a channel that was never re-detected a rename reaches flagged lines too,
    /// so the other side's words sit under the name. This re-detect puts them in no echo cluster.
    /// `orphan` is such a line whose match the check can no longer see (nothing on the other channel).
    @Test("a line already flagged as echo, outside an echo cluster, becomes unattributed and stays flagged")
    func anAlreadyFlaggedLineOutsideAnEchoClusterIsUnattributed() async throws {
        let voice = BlendedVoice()
        let orphan = [Line(start: 215, end: 220, text: Self.words("orphan", 6))]
        let before = voice.segments(label: "Robin", copiesFlagged: true)
            + orphan.map { Self.segment($0, "Robin", "local", echo: true) }
        let (t, cleanup) = try makeRecording(segments: before, metadata: ["speaker_names": ["Local Speaker 1": "Robin"]]); defer { cleanup() }
        let diarization = DiarizationResult(segments: Self.turns(voice.own + voice.copies + orphan, "S1"), speakerDatabase: ["S1": [1, 0, 0]])

        let outcome = try await TranscriptRediarizer.rediarize(
            transcript: t, source: "local", speakerCount: 1, diarizer: ScriptedDiarizer(result: diarization))

        let (segments, metadata) = try read(t)
        // The flag is one-way; the label an earlier diarization (and a rename) left is not kept.
        #expect(echoCount(found(voice.copies + orphan, in: segments)) == voice.copies.count + 1)
        #expect(speakers(found(voice.copies + orphan, in: segments)) == ["Local Unknown"])
        #expect(speakers(found(voice.own, in: segments)) == ["Local Speaker 1"])
        #expect(echoCount(found(voice.own, in: segments)) == 0)
        #expect(record(segments) == record(before))
        #expect(metadata["speaker_count_local"] as? Int == 1)
        #expect(outcome.speakerCount == 1)
        #expect(outcome.echoClusters == 0)
        #expect(outcome.segmentsRelabeled == voice.own.count)
        #expect(metadata["echo_segments_flagged"] as? Int == voice.copies.count + 1)
        #expect(clusters(metadata, track: "local").compactMap { $0["label"] as? String } == ["Local Speaker 1"])
    }

    /// Both rules in one re-detect: an echo cluster, and one more copy of the other side inside the
    /// user's own cluster. The cluster's lines are untouched by #277; only the stray copy changes.
    @Test("an echo cluster's lines carry the cluster's label; a flagged line outside it is unattributed")
    func echoClusterLinesKeepTheClustersLabel() async throws {
        let voices = TwoVoices()
        let blended = [Line(start: 215, end: 220, text: Self.words("blended", 6))]
        let before = voices.segments(own: "Local Speaker 1", bleed: "Local Speaker 1")
            + blended.map { Self.segment($0, "Remote Speaker 1", "remote") }
            + blended.map { Self.segment($0, "Local Speaker 1", "local") }
        let (t, cleanup) = try makeRecording(segments: before); defer { cleanup() }
        let diarization = DiarizationResult(
            segments: Self.turns(voices.own + blended, "S1") + Self.turns(voices.far + voices.residue, "S2"),
            speakerDatabase: ["S1": [1, 0, 0], "S2": [0, 1, 0]])

        let outcome = try await TranscriptRediarizer.rediarize(
            transcript: t, source: "local", speakerCount: 1, diarizer: ScriptedDiarizer(result: diarization))

        let (segments, metadata) = try read(t)
        // The echo cluster: its own label on every line, matched lines flagged, the residue not.
        #expect(speakers(found(voices.far + voices.residue, in: segments)) == ["Local Speaker 2"])
        #expect(echoCount(found(voices.far, in: segments)) == voices.far.count)
        #expect(echoCount(found(voices.residue, in: segments)) == 0)
        // The copy inside the user's cluster: flagged, and nobody's.
        #expect(echoCount(found(blended, in: segments)) == 1)
        #expect(speakers(found(blended, in: segments)) == ["Local Unknown"])
        #expect(speakers(found(voices.own, in: segments)) == ["Local Speaker 1"])
        #expect(record(segments) == record(before))

        // One person, one echo voice; the unattributed label is neither.
        #expect(metadata["speaker_count_local"] as? Int == 1)
        #expect(outcome.speakerCount == 1)
        #expect(outcome.echoClusters == 1)
        #expect(outcome.echoFlagged == voices.far.count + 1)
        #expect(metadata["echo_segments_flagged"] as? Int == voices.far.count + 1)
        #expect(clusters(metadata, track: "local").compactMap { $0["label"] as? String }.sorted() == ["Local Speaker 1", "Local Speaker 2"])
        #expect(EchoNotice.Findings(metadata: metadata).voices.map(\.label) == ["Local Speaker 2"])
    }

    /// Speech the diarizer gave no turn to is grouped as "Unknown". When that group is mostly echo it
    /// is an echo cluster like any other: a stated count of 1 must not fold its residue into the user.
    @Test("unattributed speech judged echo is not folded into the stated speaker")
    func unattributedEchoIsNotFolded() async throws {
        let voices = TwoVoices()
        let before = voices.segments(own: "Local Speaker 1", bleed: "Local Speaker 1")
        let (t, cleanup) = try makeRecording(segments: before); defer { cleanup() }
        let ownOnly = DiarizationResult(segments: Self.turns(voices.own, "S1"), speakerDatabase: ["S1": [1, 0, 0]])

        let outcome = try await TranscriptRediarizer.rediarize(
            transcript: t, source: "local", speakerCount: 1, diarizer: ScriptedDiarizer(result: ownOnly))

        let (segments, metadata) = try read(t)
        #expect(speakers(found(voices.own, in: segments)) == ["Local Speaker 1"])
        #expect(speakers(found(voices.far + voices.residue, in: segments)) == ["Local Unknown"])
        #expect(echoCount(found(voices.far, in: segments)) == voices.far.count)
        #expect(echoCount(found(voices.residue, in: segments)) == 0)
        #expect(metadata["speaker_count_local"] as? Int == 1)
        #expect(outcome.echoClusters == 1)
    }

    /// The user only listened: the mic channel holds nothing but the other side's voice.
    @Test("a channel that is one echo cluster has no speakers of its own")
    func aChannelOfOnlyEchoCountsNobody() async throws {
        let voices = TwoVoices()
        let before = voices.far.map { Self.segment($0, "Remote Speaker 1", "remote") }
            + (voices.far + voices.residue).map { Self.segment($0, "Local Speaker 1", "local") }
        let (t, cleanup) = try makeRecording(segments: before); defer { cleanup() }
        let one = DiarizationResult(segments: Self.turns(voices.far + voices.residue, "S1"), speakerDatabase: ["S1": [1, 0, 0]])

        let outcome = try await TranscriptRediarizer.rediarize(
            transcript: t, source: "local", speakerCount: 1, diarizer: ScriptedDiarizer(result: one))

        let (segments, metadata) = try read(t)
        #expect(echoCount(found(voices.far, in: segments)) == voices.far.count)
        #expect(speakers(found(voices.far + voices.residue, in: segments)) == ["Local Speaker 1"])
        #expect(record(segments) == record(before))
        #expect(metadata["speaker_count_local"] as? Int == 0)
        #expect(outcome.speakerCount == 0)
        #expect(outcome.echoClusters == 1)
    }

    /// At re-detect there are no word timings, so labelling is one segment in, one out. If that ever
    /// stops holding, the flags could land on the wrong lines — the guard stands down instead and the
    /// re-detect does what it did before the guard existed.
    @Test("raw labelling that is not one-to-one skips the guard: the result is the unguarded one")
    func aLabellingMismatchSkipsTheGuard() async throws {
        let voices = TwoVoices()
        let before = voices.segments(own: "Local Speaker 1", bleed: "Local Speaker 2")
        let (t, cleanup) = try makeRecording(segments: before, metadata: Self.staleEchoMetadata); defer { cleanup() }

        var lostOne = false
        let outcome = try await TranscriptRediarizer.rediarize(
            transcript: t, source: "local", speakerCount: 1, diarizer: ScriptedDiarizer(result: voices.diarization()),
            rawLabeling: { segments, diarization in
                let full = TranscriptRediarizer.label(segments, against: diarization)
                lostOne = true
                return (Array(full.labeled.dropLast()), full.speakerDatabase)
            })

        #expect(lostOne, "the echo check labelled the raw clusters through the seam")
        let (segments, metadata) = try read(t)
        // The count is enforced as before: every local line is the one stated speaker, nothing flagged.
        #expect(speakers(segments.filter { $0["source"] as? String == "local" }) == ["Local Speaker 1"])
        #expect(echoCount(segments) == 0)
        // No words lost.
        #expect(record(segments) == record(before))
        #expect(metadata["speaker_count_local"] as? Int == 1)
        #expect(outcome.speakerCount == 1)
        #expect(outcome.segmentsRelabeled == voices.own.count + voices.far.count + voices.residue.count)
        #expect(outcome.echoClusters == 0)
        #expect(outcome.echoFlagged == 0)
        // No fresh verdicts, so what the transcript said about echo is left as it was.
        #expect(clusters(metadata, track: "local").compactMap { $0["label"] as? String } == ["Local Speaker 7"])
        #expect(issues(metadata) == ["echo_flagged/local/3/0", "echo_cluster/local/4/0", "asr_failed/remote/-/1"])
        #expect(metadata["echo_segments_flagged"] == nil)
    }

    /// The echo check judges the mic channel against the system channel: it knows nothing about the
    /// reverse. Re-detecting the other side is therefore exactly what it was — count enforced, no
    /// segment flagged, the transcript's echo verdicts untouched.
    @Test("re-detecting the remote channel runs no echo guard")
    func theRemoteChannelIsNotGuarded() async throws {
        // The same two voices with the channels swapped: a remote cluster repeating the local words.
        let voices = TwoVoices()
        func swapped(_ segment: [String: Any]) -> [String: Any] {
            var d = segment
            let local = segment["source"] as? String == "local"
            d["source"] = local ? "remote" : "local"
            d["speaker"] = (segment["speaker"] as? String ?? "")
                .replacingOccurrences(of: local ? "Local" : "Remote", with: local ? "Remote" : "Local")
            return d
        }
        let before = voices.segments(own: "Local Speaker 1", bleed: "Local Speaker 2").map(swapped)
        let (t, cleanup) = try makeRecording(segments: before, metadata: Self.staleEchoMetadata); defer { cleanup() }

        let outcome = try await TranscriptRediarizer.rediarize(
            transcript: t, source: "remote", speakerCount: 1, diarizer: ScriptedDiarizer(result: voices.diarization()))

        let (segments, metadata) = try read(t)
        #expect(speakers(segments.filter { $0["source"] as? String == "remote" }) == ["Remote Speaker 1"])
        #expect(echoCount(segments) == 0)
        #expect(record(segments) == record(before))
        #expect(metadata["speaker_count_remote"] as? Int == 1)
        #expect(outcome.speakerCount == 1)
        #expect(outcome.echoClusters == 0)
        #expect(outcome.echoFlagged == 0)
        #expect(clusters(metadata, track: "local").compactMap { $0["label"] as? String } == ["Local Speaker 7"])
        #expect(clusters(metadata, track: "remote").count == 1)
        #expect(issues(metadata) == ["echo_flagged/local/3/0", "echo_cluster/local/4/0", "asr_failed/remote/-/1"])
        #expect(metadata["rediarized_channels"] as? [String] == ["remote"])
    }

    // MARK: Every flagged line on a re-detected channel is unattributed (#296)

    /// `segment`, with one more flag set.
    static func segment(_ line: Line, _ speaker: String, _ source: String, flag: String) -> [String: Any] {
        var d = segment(line, speaker, source)
        d[flag] = true
        return d
    }

    /// The case seen on a real file: the remote channel re-detected at 1, and its `duplicate` lines
    /// still under `Remote Speaker 1` and `Remote Speaker 2` — labels of a diarization that no longer
    /// exists, one of them now another person's number. Every kind of flag, the same rule.
    @Test("remote re-detect: every flagged remote line takes Remote Unknown and keeps its flag")
    func everyFlaggedRemoteLineIsUnattributed() async throws {
        let talk = Self.lines("talk", count: 6, offset: 0, length: 8)
        let repeats = Self.lines("again", count: 4, offset: 9, length: 1)
        let noise = Line(start: 130, end: 131, text: Self.words("noise", 2))
        let bled = Line(start: 150, end: 152, text: Self.words("bled", 4))
        let untimed = Line(start: 0, end: 0, text: Self.words("untimed", 3))
        let mine = Line(start: 170, end: 175, text: Self.words("mine", 5))
        let mineAgain = Line(start: 176, end: 177, text: Self.words("mine0", 2))
        var untimedSegment = Self.segment(untimed, "Remote Speaker 2", "remote")
        untimedSegment["time_unknown"] = true
        let before = talk.enumerated().map { Self.segment($1, $0 < 3 ? "Remote Speaker 1" : "Remote Speaker 2", "remote") }
            + repeats.enumerated().map { Self.segment($1, $0 < 3 ? "Remote Speaker 1" : "Remote Speaker 2", "remote", flag: "duplicate") }
            + [Self.segment(noise, "Remote Speaker 2", "remote", flag: "filtered"),
               Self.segment(bled, "Remote Speaker 1", "remote", echo: true),
               untimedSegment,
               Self.segment(mine, "Local Speaker 1", "local"),
               Self.segment(mineAgain, "Local Speaker 2", "local", flag: "duplicate")]
        let (t, cleanup) = try makeRecording(segments: before); defer { cleanup() }
        let diarization = DiarizationResult(segments: Self.turns(talk, "S1"), speakerDatabase: ["S1": [1, 0, 0]])

        let outcome = try await TranscriptRediarizer.rediarize(
            transcript: t, source: "remote", speakerCount: 1, diarizer: ScriptedDiarizer(result: diarization))

        let (segments, metadata) = try read(t)
        let flagged = repeats + [noise, bled, untimed]
        #expect(speakers(found(talk, in: segments, source: "remote")) == ["Remote Speaker 1"])
        #expect(speakers(found(flagged, in: segments, source: "remote")) == ["Remote Unknown"])
        // Flag, never delete: every flag is where it was.
        let remote = segments.filter { $0["source"] as? String == "remote" }
        #expect(remote.filter { $0["duplicate"] as? Bool == true }.count == repeats.count)
        #expect(remote.filter { $0["filtered"] as? Bool == true }.count == 1)
        #expect(remote.filter { $0["echo"] as? Bool == true }.count == 1)
        #expect(remote.filter { $0["time_unknown"] as? Bool == true }.count == 1)
        #expect(remote.filter(TranscriptAssembler.isFlagged).count == flagged.count)
        #expect(record(segments) == record(before))
        // The other channel is not this re-detect's: its flagged line keeps its label.
        #expect(speakers(found([mine], in: segments)) == ["Local Speaker 1"])
        #expect(speakers(found([mineAgain], in: segments)) == ["Local Speaker 2"])
        // The unattributed label is nobody: not counted, and no row to rename.
        #expect(metadata["speaker_count_remote"] as? Int == 1)
        #expect(outcome.speakerCount == 1)
        #expect(outcome.segmentsRelabeled == talk.count)
        let rows = try TranscriptRenamer.collectSpeakerSamples(from: t, maxSamplesPerSpeaker: 1).map(\.id)
        #expect(Set(rows) == ["Local Speaker 1", "Remote Speaker 1"])

        // A rename after it names the person, and does not reach the flagged lines.
        #expect(TranscriptRenamer.applyRenames(["Remote Speaker 1": "Ana"], jsonPath: t))
        let renamed = try read(t).segments
        #expect(speakers(found(talk, in: renamed, source: "remote")) == ["Ana"])
        #expect(speakers(found(flagged, in: renamed, source: "remote")) == ["Remote Unknown"])
    }

    /// The mic channel, with the echo check running: a `filtered` or `duplicate` line is no evidence
    /// and no candidate, but its old label is just as stale. Here the numbering flips, so the label
    /// those lines carried ("Local Speaker 2") is the user's after the re-detect.
    @Test("local re-detect: filtered and duplicate lines take Local Unknown, not a number that is now the user's")
    func filteredAndDuplicateLocalLinesAreUnattributed() async throws {
        let voices = TwoVoices()
        let noise = Line(start: 220, end: 221, text: Self.words("noise", 4))
        let again = Line(start: 240, end: 241, text: Self.words("again", 4))
        let before = voices.segments(own: "Local Speaker 1", bleed: "Local Speaker 2", bleedFlagged: true)
            + [Self.segment(noise, "Local Speaker 2", "local", flag: "filtered"),
               Self.segment(again, "Local Speaker 2", "local", flag: "duplicate")]
        let (t, cleanup) = try makeRecording(segments: before, metadata: Self.staleEchoMetadata); defer { cleanup() }

        let outcome = try await TranscriptRediarizer.rediarize(
            transcript: t, source: "local", speakerCount: 1, diarizer: ScriptedDiarizer(result: voices.diarization(echoFirst: true)))

        // The echo cluster's lines carry the cluster's label: the one exception to the rule.
        try expectTheEchoVoiceKeptApart(t, voices, outcome, before: before, user: "Local Speaker 2", echo: "Local Speaker 1")
        let segments = try read(t).segments
        #expect(speakers(found([noise, again], in: segments)) == ["Local Unknown"])
        #expect(found([noise], in: segments).first?["filtered"] as? Bool == true)
        #expect(found([again], in: segments).first?["duplicate"] as? Bool == true)
    }

    /// When the echo check stands down the re-detect is the unguarded one — but a line already
    /// flagged does not keep the label it had either: there is no echo cluster to give it a label.
    @Test("with the echo check stood down, every flagged local line takes Local Unknown")
    func flaggedLinesAreUnattributedWhenTheCheckStandsDown() async throws {
        let voices = TwoVoices()
        let noise = Line(start: 220, end: 221, text: Self.words("noise", 4))
        let before = voices.segments(own: "Local Speaker 1", bleed: "Local Speaker 2", bleedFlagged: true)
            + [Self.segment(noise, "Local Speaker 1", "local", flag: "filtered")]
        let (t, cleanup) = try makeRecording(segments: before); defer { cleanup() }

        let outcome = try await TranscriptRediarizer.rediarize(
            transcript: t, source: "local", speakerCount: 1, diarizer: ScriptedDiarizer(result: voices.diarization()),
            rawLabeling: { segments, diarization in
                let full = TranscriptRediarizer.label(segments, against: diarization)
                return (Array(full.labeled.dropLast()), full.speakerDatabase)
            })

        let (segments, metadata) = try read(t)
        #expect(outcome.echoClusters == 0)
        #expect(speakers(found(voices.far + [noise], in: segments)) == ["Local Unknown"])
        #expect(echoCount(found(voices.far, in: segments)) == voices.far.count)
        #expect(found([noise], in: segments).first?["filtered"] as? Bool == true)
        // Unflagged lines are labelled exactly as before.
        #expect(speakers(found(voices.own + voices.residue, in: segments)) == ["Local Speaker 1"])
        #expect(record(segments) == record(before))
        #expect(metadata["speaker_count_local"] as? Int == 1)
        #expect(outcome.speakerCount == 1)
    }

    @Test("a re-detect never changes the number of segments or any text, at any stated count",
          arguments: [1, 2, 3])
    func aRedetectIsARelabel(stated: Int) async throws {
        let voices = TwoVoices()
        for flagged in [false, true] {
            let before = voices.segments(own: "Local Speaker 1", bleed: "Local Speaker 2", bleedFlagged: flagged)
            let (t, cleanup) = try makeRecording(segments: before); defer { cleanup() }
            _ = try await TranscriptRediarizer.rediarize(
                transcript: t, source: "local", speakerCount: stated, diarizer: ScriptedDiarizer(result: voices.diarization()))
            let after = try read(t).segments
            #expect(after.count == before.count)
            #expect(record(after) == record(before))
            // Kept out of the merge at every count, and never counted as a person.
            #expect(speakers(found(voices.residue, in: after)).isDisjoint(with: speakers(found(voices.own, in: after))))
            #expect(try read(t).metadata["speaker_count_local"] as? Int == 1)
        }
    }

    /// `metadata.rediarized_channels`: which channels a re-detect has rewritten. The rename path reads
    /// it to know a channel's labels are no longer the ones the pipeline wrote.
    @Test("rediarized_channels lists each re-detected channel once, in the order they were first re-detected")
    func rediarizedChannelsAreRecordedOnce() async throws {
        let before = [Self.segment(Line(start: 0.2, end: 0.8, text: Self.words("here", 3)), "Local Speaker 1", "local"),
                      Self.segment(Line(start: 1.2, end: 1.8, text: Self.words("there", 3)), "Remote Speaker 1", "remote")]
        let (t, cleanup) = try makeRecording(segments: before); defer { cleanup() }
        #expect(try read(t).metadata["rediarized_channels"] == nil)
        var seen: [[String]] = []
        for channel in ["local", "remote", "local"] {
            _ = try await TranscriptRediarizer.rediarize(transcript: t, source: channel, speakerCount: 1, diarizer: FakeDiarizer())
            seen.append(try #require(try read(t).metadata["rediarized_channels"] as? [String]))
        }
        #expect(seen == [["local"], ["local", "remote"], ["local", "remote"]])
    }
}
