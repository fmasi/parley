import AVFoundation
import Foundation
import os
import Testing
@testable import TranscriberCore

/// #341: the rename dialog keeps one channel's speaker analysis, and a Re-detect at another count
/// clusters it again instead of decoding the audio and running the models over it again.
@Suite struct SpeakerAnalysisCacheTests {
    static func key(_ source: String = "local", path: String = "/r/a.m4a", size: Int? = 10) -> SpeakerAnalysisCache.Key {
        SpeakerAnalysisCache.Key(source: source, provider: "p", files: [.init(path: path, size: size, modified: nil)],
                                 echoCanceller: nil, chunkDurations: [1], chunkOffsets: nil, gapSeconds: [], hasCaptureGaps: false)
    }
    static let analysis = PreparedSpeakerAnalysis(payload: 1, sampleCount: 16_000, embeddingCount: 3)

    @Test func aStoredAnalysisIsFoundByItsKey() async {
        let cache = SpeakerAnalysisCache()
        #expect(await cache.lookup(Self.key()) == nil)
        await cache.store(Self.analysis, for: Self.key())
        #expect(await cache.lookup(Self.key())?.embeddingCount == 3)
    }

    /// The bound: a miss releases what is held BEFORE the caller decodes and prepares another, so a
    /// long call's analysis is never held twice.
    @Test("a miss releases the analysis held for another channel or recording", arguments: [
        key("remote"), key(path: "/r/b.m4a"), key(size: 11), key(size: nil),
    ])
    func aMissReleasesWhatIsHeld(other: SpeakerAnalysisCache.Key) async {
        let cache = SpeakerAnalysisCache()
        await cache.store(Self.analysis, for: Self.key())
        #expect(await cache.lookup(other) == nil)
        #expect(await cache.heldKey == nil)
        #expect(await cache.lookup(Self.key()) == nil)
    }

    /// A Re-detect cancelled by the dialog's close can still finish preparing: it must not leave it held.
    @Test func aClosedCacheReleasesAndKeepsNothing() async {
        let cache = SpeakerAnalysisCache()
        await cache.store(Self.analysis, for: Self.key())
        await cache.close()
        #expect(await cache.heldKey == nil)
        await cache.store(Self.analysis, for: Self.key())
        #expect(await cache.lookup(Self.key()) == nil)
    }

    /// A release lets the analysis go but keeps the cache usable: the next lookup's store is kept.
    @Test func aReleaseKeepsTheCacheUsable() async {
        let cache = SpeakerAnalysisCache()
        await cache.store(Self.analysis, for: Self.key())
        await cache.release(.memoryPressure)
        #expect(await cache.heldKey == nil)
        await cache.store(Self.analysis, for: Self.key())
        #expect(await cache.heldKey == nil, "a store after the release and before a lookup is refused")
        #expect(await cache.lookup(Self.key()) == nil)
        await cache.store(Self.analysis, for: Self.key())
        #expect(await cache.heldKey == Self.key())
    }

    /// Every open cache is reached: what a recording's start and memory pressure call.
    @Test func releaseAllReachesEveryOpenCache() async {
        let a = SpeakerAnalysisCache(), b = SpeakerAnalysisCache()
        await a.store(Self.analysis, for: Self.key())
        await b.store(Self.analysis, for: Self.key("remote"))
        SpeakerAnalysisCache.releaseAll(.recordingStarted)
        for _ in 0..<1000 {
            let aHeld = await a.heldKey, bHeld = await b.heldKey
            if aHeld == nil && bHeld == nil { break }
            await Task.yield()
        }
        let aHeld = await a.heldKey, bHeld = await b.heldKey
        #expect(aHeld == nil && bHeld == nil)
    }

    @Test func aWarningOrWorseReleases() {
        #expect(SpeakerAnalysisCache.releasesOnPressure(.warning))
        #expect(SpeakerAnalysisCache.releasesOnPressure(.critical))
        #expect(SpeakerAnalysisCache.releasesOnPressure([.warning, .critical]))
        #expect(!SpeakerAnalysisCache.releasesOnPressure(.normal))
    }

    /// The prepare settings are in the key, the clustering settings are not: a forced count or a
    /// clustering threshold must not miss, the overlap rule or the compute units must.
    @Test func thePreparationIdentityHoldsThePrepareSettingsOnly() {
        let stock = FluidAudioDiarizer().preparationIdentity
        #expect(stock.contains("segmentation=") && stock.contains("embedding=") && stock.contains("computeUnits=all"))
        #expect(FluidAudioDiarizer(clusteringThreshold: 0.7, maxSpeakers: 3).preparationIdentity == stock)
        #expect(FluidAudioDiarizer(excludeOverlap: false).preparationIdentity != stock)
        #expect(FluidAudioDiarizer(computeUnits: .neuralEngine).preparationIdentity != stock)
        #expect(FluidAudioDiarizer(computeUnits: .cpuOnly).preparationIdentity != FluidAudioDiarizer(computeUnits: .neuralEngine).preparationIdentity)
    }

    @Test func aFileIsKeyedByItsSizeAndDate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("analysis-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(SpeakerAnalysisCache.Key.File.current(url).size == nil)
        try Data("abc".utf8).write(to: url)
        let before = SpeakerAnalysisCache.Key.File.current(url)
        #expect(before.size == 3 && before.modified != nil)
        try Data("abcd".utf8).write(to: url)
        #expect(SpeakerAnalysisCache.Key.File.current(url) != before)
    }
}

@Suite struct RedetectProgressThrottleTests {
    typealias P = TranscriptRediarizer.Progress
    let t0 = ContinuousClock.now

    @Test func aFractionPassesAtMostTenTimesASecond() {
        var throttle = RedetectProgressThrottle()
        func admit(_ p: P, at time: ContinuousClock.Instant) -> Bool { throttle.admit(p, at: time) }
        #expect(admit(P(phase: .detectingSpeakers, fraction: 0.1), at: t0))
        #expect(!admit(P(phase: .detectingSpeakers, fraction: 0.2), at: t0 + .milliseconds(50)))
        #expect(admit(P(phase: .detectingSpeakers, fraction: 0.3), at: t0 + .milliseconds(100)))
        #expect(!admit(P(phase: .detectingSpeakers, fraction: 0.4), at: t0 + .milliseconds(199)))
    }

    @Test func aPhaseChangeTheStartOfAFractionAndItsEndAlwaysPass() {
        var throttle = RedetectProgressThrottle()
        func admit(_ p: P, at time: ContinuousClock.Instant) -> Bool { throttle.admit(p, at: time) }
        #expect(admit(P(phase: .decodingAudio), at: t0))
        #expect(admit(P(phase: .decodingAudio, fraction: 0.5), at: t0))
        #expect(admit(P(phase: .decodingAudio, fraction: 1), at: t0))
        #expect(admit(P(phase: .detectingSpeakers), at: t0))
        #expect(admit(P(phase: .regroupingSpeakers), at: t0))
    }

    @Test func theSameReportNeverPassesTwiceInARow() {
        var throttle = RedetectProgressThrottle()
        func admit(_ p: P, at time: ContinuousClock.Instant) -> Bool { throttle.admit(p, at: time) }
        #expect(admit(P(phase: .regroupingSpeakers), at: t0))
        #expect(!admit(P(phase: .regroupingSpeakers), at: t0 + .seconds(5)))
        #expect(admit(P(phase: .detectingSpeakers, fraction: 1), at: t0))
        #expect(!admit(P(phase: .detectingSpeakers, fraction: 1), at: t0))
    }

    /// What the dialog installs: a thousand chunk reports in a burst reach it as a handful.
    @Test func theGatePassesOnOnlyWhatTheThrottleAdmits() {
        let seen = OSAllocatedUnfairLock(initialState: [P]())
        let start = t0
        let gate = RedetectProgressThrottle.gate(clock: { start }) { p in seen.withLock { $0.append(p) } }
        for i in 1...1000 { gate(P(phase: .detectingSpeakers, fraction: Double(i) / 1000)) }
        #expect(seen.withLock { $0 } == [P(phase: .detectingSpeakers, fraction: 0.001), P(phase: .detectingSpeakers, fraction: 1)])
    }
}

/// `TranscriptRediarizer.rediarize` with a dialog's analysis cache, against a diarizer that splits its
/// work (a fake: the AMI golden test in `DiarizationRegressionTests` pins the real one).
@Suite(.serialized) struct RedetectAnalysisReuseTests {
    /// Answers every count with that many speakers, two lines each in turn; counts what it was asked.
    final class ReusingDiarizer: SpeakerAnalysisReusing, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        var preparationIdentity: String { "fake" }
        /// What the cache held while `prepare` ran: must be nothing (the bound).
        private(set) var heldDuringPrepare: [SpeakerAnalysisCache.Key?] = []
        var cache: SpeakerAnalysisCache?
        var failFirstPrepare = false
        var closeCacheDuringPrepare = false
        var releaseCacheDuringPrepare: SpeakerAnalysisCache?

        var calls: [String] { lock.withLock { log } }
        private func note(_ s: String) { lock.withLock { log.append(s) } }

        static func answer(_ count: Int?) -> DiarizationResult {
            let n = max(count ?? 1, 1)
            let segments = (0..<8).map { i in
                DiarizedSegment(start: Double(i) * 2, end: Double(i) * 2 + 1.5, speaker: "S\(i % n + 1)", qualityScore: 0.9)
            }
            let database = Dictionary(uniqueKeysWithValues: (1...n).map { k in
                ("S\(k)", (1...n).map { $0 == k ? Float(1) : 0 })
            })
            return DiarizationResult(segments: segments, speakerDatabase: database)
        }

        func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult {
            note("path \(numSpeakers ?? 0)"); return Self.answer(numSpeakers)
        }
        func diarize(audio: [Float], numSpeakers: Int?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult {
            note("full \(numSpeakers ?? 0)"); progress?(1, 1); return Self.answer(numSpeakers)
        }
        func prepare(audio: [Float], speakerCountHint: Int?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> PreparedSpeakerAnalysis {
            note("prepare \(speakerCountHint ?? 0)")
            let held = await cache?.heldKey
            lock.withLock { heldDuringPrepare.append(held) }
            if closeCacheDuringPrepare { await cache?.close() }
            await releaseCacheDuringPrepare?.release(.recordingStarted)
            if failFirstPrepare, calls.filter({ $0.hasPrefix("prepare") }).count == 1 { throw CocoaError(.featureUnsupported) }
            progress?(1, 2); progress?(2, 2)
            return PreparedSpeakerAnalysis(payload: audio.count, sampleCount: audio.count, embeddingCount: 8)
        }
        func cluster(_ prepared: PreparedSpeakerAnalysis, numSpeakers: Int?) async throws -> DiarizationResult {
            note("cluster \(numSpeakers ?? 0)"); return Self.answer(numSpeakers)
        }
    }

    /// A plain diarizer giving the same answers: the path without reuse.
    struct PlainDiarizer: DiarizationProvider {
        func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult { ReusingDiarizer.answer(numSpeakers) }
        func diarize(audio: [Float], numSpeakers: Int?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult {
            ReusingDiarizer.answer(numSpeakers)
        }
    }

    final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [TranscriptRediarizer.Progress] = []
        func record(_ p: TranscriptRediarizer.Progress) { lock.withLock { stored.append(p) } }
        var phases: [TranscriptRediarizer.Progress.Phase] { lock.withLock { stored.map(\.phase) } }
    }

    static let segments: [[String: Any]] = {
        // Built in steps: CI's Swift 6.3 times out type-checking the one-expression form.
        var lines: [[String: Any]] = []
        for i in 0..<8 {
            let start = Double(i) * 2
            let line: [String: Any] = ["start": start, "end": start + 1.5, "text": "line \(i) said here",
                                       "speaker": "Local Speaker 1", "source": "local"]
            lines.append(line)
        }
        let far: [String: Any] = ["start": 0.0, "end": 1.0, "text": "far side", "speaker": "Remote Speaker 1", "source": "remote"]
        lines.append(far)
        return lines
    }()

    /// A chunked recording (a mic-only and a system-only chunk, 1 s each), or a two-file one.
    private func makeRecording(legacy: Bool = false) throws -> (transcript: URL, files: [URL], cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("analysis-reuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let files = legacy
            ? [dir.appendingPathComponent("m.wav"), dir.appendingPathComponent("m_mic.wav")]
            : [dir.appendingPathComponent("call-0_mic.wav"), dir.appendingPathComponent("call-1.wav")]
        for file in files {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
            buffer.frameLength = 16000
            try AVAudioFile(forWriting: file, settings: format.settings).write(from: buffer)
        }
        let transcript = dir.appendingPathComponent("t.json")
        try JSONSerialization.data(withJSONObject: [
            "metadata": ["audio_paths": files.map(\.path), "chunk_durations": [1.0, 1.0]], "segments": Self.segments,
        ]).write(to: transcript)
        return (transcript, files, { try? FileManager.default.removeItem(at: dir) })
    }

    private func redetect(_ t: URL, _ source: String = "local", at count: Int, with d: any DiarizationProvider,
                          cache: SpeakerAnalysisCache?, canceller: (any MicEchoSampleCancelling)? = nil,
                          log: ProgressLog? = nil) async throws -> TranscriptRediarizer.Outcome {
        try await TranscriptRediarizer.rediarize(transcript: t, source: source, speakerCount: count, diarizer: d,
                                                 speakerAnalysis: cache, echoCanceller: canceller,
                                                 onProgress: log.map { log in { log.record($0) } })
    }

    /// The flow #341 is for: try 2, then 3. The first prepares once, for #265's wider pass and the
    /// stated count's alike; the second only clusters — no decode, no model pass.
    @Test func aSecondRedetectAtAnotherCountOnlyClusters() async throws {
        let (t, _, cleanup) = try makeRecording(); defer { cleanup() }
        let cache = SpeakerAnalysisCache(), d = ReusingDiarizer()
        let first = ProgressLog(), second = ProgressLog()
        _ = try await redetect(t, at: 2, with: d, cache: cache, log: first)
        #expect(d.calls == ["prepare 3", "cluster 3", "cluster 2"])
        _ = try await redetect(t, at: 3, with: d, cache: cache, log: second)
        #expect(d.calls == ["prepare 3", "cluster 3", "cluster 2", "cluster 4", "cluster 3"])

        #expect(first.phases.first == .decodingAudio)
        #expect(first.phases.contains(.detectingSpeakers) && first.phases.last == .regroupingSpeakers)
        #expect(second.phases.allSatisfy { $0 == .regroupingSpeakers } && !second.phases.isEmpty)
    }

    /// Reuse changes how long it takes, never what it writes.
    @Test("the transcript written is the one a full pass writes", arguments: ["local", "remote"])
    func reuseWritesWhatAFullPassWrites(source: String) async throws {
        let (reused, _, cleanupA) = try makeRecording(); defer { cleanupA() }
        let (full, _, cleanupB) = try makeRecording(); defer { cleanupB() }
        let cache = SpeakerAnalysisCache(), d = ReusingDiarizer()
        for count in [2, 3, 1] {
            let a = try await redetect(reused, source, at: count, with: d, cache: cache)
            let b = try await redetect(full, source, at: count, with: PlainDiarizer(), cache: nil)
            #expect(a.speakerCount == b.speakerCount && a.segmentsRelabeled == b.segmentsRelabeled)
            let ja = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: reused)) as? NSDictionary)
            let jb = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: full)) as? NSDictionary)
            #expect(ja["segments"] as? NSArray == jb["segments"] as? NSArray)
            var ma = try #require(ja["metadata"] as? [String: Any]), mb = try #require(jb["metadata"] as? [String: Any])
            ma["audio_paths"] = nil; mb["audio_paths"] = nil
            #expect(NSDictionary(dictionary: ma) == NSDictionary(dictionary: mb))
        }
        #expect(d.calls.filter { $0.hasPrefix("prepare") }.count == 1)
    }

    /// The other channel is another analysis: the held one goes before the new one is prepared.
    @Test func anotherChannelReleasesTheHeldAnalysisFirst() async throws {
        let (t, _, cleanup) = try makeRecording(); defer { cleanup() }
        let cache = SpeakerAnalysisCache(), d = ReusingDiarizer()
        d.cache = cache
        _ = try await redetect(t, "local", at: 1, with: d, cache: cache)
        _ = try await redetect(t, "remote", at: 1, with: d, cache: cache)
        _ = try await redetect(t, "local", at: 2, with: d, cache: cache)
        #expect(d.calls.filter { $0.hasPrefix("prepare") } == ["prepare 2", "prepare 1", "prepare 3"])
        #expect(d.heldDuringPrepare.allSatisfy { $0 == nil })
        #expect(await cache.heldKey?.source == "local")
    }

    /// Audio that changed on disk (a rename of the session moves it, the storage limit removes it) is
    /// analysed again, never served from the old analysis.
    @Test func changedAudioIsAnalysedAgain() async throws {
        let (t, files, cleanup) = try makeRecording(); defer { cleanup() }
        let cache = SpeakerAnalysisCache(), d = ReusingDiarizer()
        _ = try await redetect(t, at: 1, with: d, cache: cache)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32000)!
        buffer.frameLength = 32000
        try FileManager.default.removeItem(at: files[0])
        try AVAudioFile(forWriting: files[0], settings: format.settings).write(from: buffer)
        _ = try await redetect(t, at: 1, with: d, cache: cache)
        #expect(d.calls.filter { $0.hasPrefix("prepare") }.count == 2)
    }

    /// A two-file transcript is streamed from disk by the diarizer: nothing is kept in memory for it.
    @Test func aTwoFileTranscriptIsNotKept() async throws {
        let (t, _, cleanup) = try makeRecording(legacy: true); defer { cleanup() }
        let cache = SpeakerAnalysisCache(), d = ReusingDiarizer()
        _ = try await redetect(t, at: 1, with: d, cache: cache)
        #expect(d.calls == ["path 2", "path 1"])
        #expect(await cache.heldKey == nil)
    }

    @Test func aDiarizerThatCannotSplitItsWorkRunsInFull() async throws {
        let (t, _, cleanup) = try makeRecording(); defer { cleanup() }
        let cache = SpeakerAnalysisCache()
        _ = try await redetect(t, at: 1, with: PlainDiarizer(), cache: cache)
        #expect(await cache.heldKey == nil)
    }

    /// The dialog closed while the analysis was being made: the re-detect finishes, nothing stays held.
    @Test func anAnalysisFinishedAfterTheCloseIsNotKept() async throws {
        let (t, _, cleanup) = try makeRecording(); defer { cleanup() }
        let cache = SpeakerAnalysisCache(), d = ReusingDiarizer()
        d.cache = cache
        d.closeCacheDuringPrepare = true
        _ = try await redetect(t, at: 1, with: d, cache: cache)
        #expect(await cache.heldKey == nil)
    }

    /// #265: a wider pass that fails falls back to the stated count. Its analysis failing is that
    /// pass failing: the stated count's pass analyses again, as a full pass would have.
    @Test func aFailedAnalysisInTheWiderPassIsTriedAgainAtTheStatedCount() async throws {
        let (t, _, cleanup) = try makeRecording(); defer { cleanup() }
        let cache = SpeakerAnalysisCache(), d = ReusingDiarizer()
        d.failFirstPrepare = true
        let outcome = try await redetect(t, at: 1, with: d, cache: cache)
        #expect(d.calls == ["prepare 2", "prepare 1", "cluster 1"])
        #expect(outcome.speakerCount == 1)
        #expect(await cache.heldKey != nil)
    }

    // MARK: - The echo canceller in the key (#341 review)

    /// Counts its calls; passes the mic through, or throws on the calls listed.
    final class CountingCanceller: MicEchoSampleCancelling, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let failing: Set<Int>
        init(failing: Set<Int> = []) { self.failing = failing }
        var calls: Int { lock.withLock { count } }
        func cancelEcho(microphone: [Float], reference: [Float]) throws -> (samples: [Float], framesReverted: Int) {
            let call = lock.withLock { count += 1; return count }
            if failing.contains(call) { throw CocoaError(.featureUnsupported) }
            return (microphone, 0)
        }
    }
    /// Another canceller: another analysis.
    struct OtherCanceller: MicEchoSampleCancelling {
        func cancelEcho(microphone: [Float], reference: [Float]) throws -> (samples: [Float], framesReverted: Int) { (microphone, 0) }
    }

    /// A recording as the app writes it — one stereo AAC chunk (L = mic, R = system) — whose mic was echo-cancelled.
    private func makeEchoCancelledRecording() async throws -> (transcript: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("analysis-echo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let system = dir.appendingPathComponent("call-0.wav"), mic = dir.appendingPathComponent("call-0_mic.wav")
        for file in [system, mic] {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
            buffer.frameLength = 16000
            for i in 0..<16000 { buffer.floatChannelData![0][i] = 0.1 * sin(Float(i) * 0.05) }
            try AVAudioFile(forWriting: file, settings: format.settings).write(from: buffer)
        }
        let archive = try await AudioArchiver.archive(systemAudio: system, micAudio: mic, outputDirectory: dir, bitrateKbps: 64)
        let transcript = dir.appendingPathComponent("t.json")
        try JSONSerialization.data(withJSONObject: [
            "metadata": ["audio_paths": [archive.archivePath.path], "chunk_durations": [1.0], "mic_echo_cancel": ["chunks": 1]],
            "segments": Self.segments,
        ]).write(to: transcript)
        return (transcript, { try? FileManager.default.removeItem(at: dir) })
    }

    /// The kept analysis is of the cancelled mic: a second Re-detect does not cancel again.
    @Test func aKeptAnalysisOfAnEchoCancelledMicSkipsTheCanceller() async throws {
        let (t, cleanup) = try await makeEchoCancelledRecording(); defer { cleanup() }
        let cache = SpeakerAnalysisCache(), d = ReusingDiarizer(), canceller = CountingCanceller()
        _ = try await redetect(t, at: 1, with: d, cache: cache, canceller: canceller)
        #expect(canceller.calls == 1)
        _ = try await redetect(t, at: 2, with: d, cache: cache, canceller: canceller)
        #expect(canceller.calls == 1)
        #expect(d.calls.filter { $0.hasPrefix("prepare") }.count == 1)
    }

    @Test func anotherCancellerIsAnotherAnalysis() async throws {
        let (t, cleanup) = try await makeEchoCancelledRecording(); defer { cleanup() }
        let cache = SpeakerAnalysisCache(), d = ReusingDiarizer()
        _ = try await redetect(t, at: 1, with: d, cache: cache, canceller: CountingCanceller())
        _ = try await redetect(t, at: 1, with: d, cache: cache, canceller: OtherCanceller())
        _ = try await redetect(t, at: 1, with: d, cache: cache, canceller: nil)
        #expect(d.calls.filter { $0.hasPrefix("prepare") }.count == 3)
    }

    /// A canceller that failed this time left the raw mic in the analysis: used for this re-detect,
    /// never kept, so the next Re-detect cancels and analyses again.
    @Test func anAnalysisOfAMicTheCancellerFailedOnIsNotKept() async throws {
        let (t, cleanup) = try await makeEchoCancelledRecording(); defer { cleanup() }
        let cache = SpeakerAnalysisCache(), d = ReusingDiarizer(), canceller = CountingCanceller(failing: [1])
        let first = try await redetect(t, at: 1, with: d, cache: cache, canceller: canceller)
        #expect(first.speakerCount == 1)
        #expect(await cache.heldKey == nil)
        _ = try await redetect(t, at: 2, with: d, cache: cache, canceller: canceller)
        #expect(canceller.calls == 2)
        #expect(d.calls.filter { $0.hasPrefix("prepare") }.count == 2)
        #expect(await cache.heldKey != nil)
    }

    // MARK: - Released while the dialog stays open (#341 review)

    /// A recording started, or memory pressure: the analysis goes, the dialog's next Re-detect misses
    /// and keeps the new one.
    @Test func aReleasedAnalysisIsMadeAgainByTheNextRedetect() async throws {
        let (t, _, cleanup) = try makeRecording(); defer { cleanup() }
        let cache = SpeakerAnalysisCache(), d = ReusingDiarizer()
        _ = try await redetect(t, at: 1, with: d, cache: cache)
        await cache.release(.recordingStarted)
        #expect(await cache.heldKey == nil)
        _ = try await redetect(t, at: 2, with: d, cache: cache)
        #expect(d.calls.filter { $0.hasPrefix("prepare") }.count == 2)
        #expect(await cache.heldKey != nil)
    }

    /// A re-detect already running when the release came does not put its analysis back.
    @Test func aReleaseDuringAnAnalysisKeepsNothing() async throws {
        let (t, _, cleanup) = try makeRecording(); defer { cleanup() }
        let cache = SpeakerAnalysisCache(), d = ReusingDiarizer()
        d.releaseCacheDuringPrepare = cache
        _ = try await redetect(t, at: 1, with: d, cache: cache)
        #expect(await cache.heldKey == nil)
    }
}

/// #341: the decoded channel can be kept as the dialog's analysis, so its buffer is sized from the
/// chunks' lengths instead of the first chunk's times the count (a long first chunk and a short last
/// one left most of a chunk's capacity held for nothing).
@Suite struct RedetectDecodeSizingTests {
    @Test func theLengthsLaidEndToEndWithoutOffsets() {
        #expect(TranscriptRediarizer.expectedSampleCount(lengths: [1800, 300], offsets: nil, contributes: [true, true])
                == 2100 * 16_000 + 2 * 16_000)
    }

    /// With offsets the end of the last chunk that contributes: a gap is inside it, a skipped chunk at the end is not.
    @Test func theEndOfTheLastContributingChunkOnTheTimeline() {
        #expect(TranscriptRediarizer.expectedSampleCount(lengths: [600, 600, 600], offsets: [0, 700, 1400], contributes: [true, true, false])
                == 1300 * 16_000 + 3 * 16_000)
    }

    @Test func anUnknownLengthLeavesTheEstimateToTheDecode() {
        #expect(TranscriptRediarizer.expectedSampleCount(lengths: [600, nil], offsets: nil, contributes: [true, true]) == nil)
        #expect(TranscriptRediarizer.expectedSampleCount(lengths: [600, .infinity], offsets: nil, contributes: [true, true]) == nil)
        // A chunk that contributes nothing needs no length.
        #expect(TranscriptRediarizer.expectedSampleCount(lengths: [600, nil], offsets: [0, 600], contributes: [true, false]) != nil)
    }
}
