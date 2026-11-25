import AVFoundation
import Foundation
import Testing
@testable import TranscriberCore

/// #265 with the real diarizer, on synthetic speech (`say`): the scripted tests in
/// `TranscriptRediarizerTests` assume a diarizer that blends the echo voice into the user when asked
/// for the people alone and separates it when given room for one more. This pins that FluidAudio
/// does so, and that a clean channel comes out of re-detect as it did before.
///
/// The rule is asserted, not this Mac's exact line assignment: a CI VM can move a line or two. Fred
/// (the user) and Kathy (the other side) are MacinTalk voices, bundled with every macOS (no download);
/// on this pair, with the far side mixed into the mic at -6, -12 and -18 dB, FluidAudio's stock config
/// returned one blended cluster at 1 and two at 2 (2026-11-17), and re-detect at 1 before #265 judged
/// that one blended cluster echo: the user counted as nobody, their lines under the echo voice.
///
/// One clip set, synthesised once for the suite; one diarizer, so each forced count loads its models
/// once. `.serialized`: CoreML and `say` are clients of shared media daemons (see
/// `SyntheticDiarizationTests`).
@Suite(.serialized, .timeLimit(.minutes(5))) struct RedetectRealDiarizerTests {
    static let rate = 16_000.0

    /// 24 lines a side, about 90 s of each voice.
    static let own = [
        "I think we should review the budget before the next board meeting.",
        "The design team needs another week to finish the prototype.",
        "Can you send me the latest version of the contract tomorrow?",
        "Our customers in the south keep asking about faster delivery.",
        "Let's move the launch date until the testing is complete.",
        "I spoke with the supplier and they agreed to lower the price.",
        "We still have three open positions in the support department.",
        "The new office should be ready by the end of the month.",
        "Please make sure the slides include the regional numbers.",
        "I am worried that the server costs will grow too quickly.",
        "Marketing wants a short video for the trade show in spring.",
        "We could ask the legal team to check the privacy terms first.",
        "The training sessions for the new hires start on Monday morning.",
        "I would rather keep the old pricing until the survey is finished.",
        "Our partners in Spain asked for a demo of the mobile version.",
        "The quarterly report needs a clearer chart of the churn rate.",
        "Let's invite the warehouse manager to the planning session.",
        "I noticed the invoices from last month were sent out twice.",
        "We should test the backup system before the holiday break.",
        "The customer panel liked the new colours on the dashboard.",
        "I can draft the press release if someone checks the figures.",
        "Our travel budget is almost spent for the rest of the year.",
        "The security audit found two small issues in the login page.",
        "Let's agree on the agenda before we send the invitations.",
    ]
    static let far = [
        "That sounds reasonable, but the finance group must approve it.",
        "Honestly the prototype looked good when I saw it on Friday.",
        "Sure, I will forward the signed copy as soon as it arrives.",
        "Delivery times improved a lot after we changed the carrier.",
        "If we wait too long the competition will beat us to market.",
        "Great news, that discount will help our margins this quarter.",
        "Recruiting has been slow because of the summer holidays.",
        "The landlord promised the keys before the first of the month.",
        "I already added the regional figures to the appendix.",
        "We can switch to reserved instances to keep the bill down.",
        "A one minute clip would be enough for the booth screens.",
        "Good idea, they reviewed something similar last year.",
        "I will book the large meeting room for the whole morning.",
        "The survey closes next Thursday, so that timing works well.",
        "Their sales lead mentioned they prefer a recorded walkthrough.",
        "Maybe a simple bar chart by region would make it obvious.",
        "She already said she can join if we start after ten.",
        "Finance caught that too, and the duplicates were refunded.",
        "Remember the restore test failed last spring for an hour.",
        "People kept asking whether the dark mode would come back.",
        "Send me the draft and I will check it against the ledger.",
        "Most of it went on the conference in Berlin, I believe.",
        "The team already fixed one of them in yesterday's release.",
        "Fine by me, as long as the budget review comes first.",
    ]

    /// The voices, and every clip in them, made once for the suite.
    struct Clips {
        let user: String, other: String
        let own: [[Float]], far: [[Float]]
    }
    static let clips: Result<Clips, Error> = Result {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("redetect-real-clips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pair = try measuredPair(installed: SyntheticSpeech.availableVoices())
        return Clips(user: pair[0], other: pair[1],
                     own: try own.map { try clip($0, voice: pair[0], in: dir) },
                     far: try far.map { try clip($0, voice: pair[1], in: dir) })
    }

    /// The (user, other side) pairs measured on 2026-11-17 — one blended cluster at 1, two at 2, with
    /// the far side 6, 12 and 18 dB down — each a man's and a woman's voice. Fred and Kathy first: both
    /// MacinTalk voices, bundled with every macOS. A pair that is not one of these was never measured,
    /// so none is substituted: the suite fails, it never skips.
    static let measuredPairs = [["Fred", "Kathy"], ["Kathy", "Ralph"], ["Albert", "Karen"], ["Karen", "Fred"]]

    struct NoMeasuredVoicePair: Error, CustomStringConvertible {
        let installed: Set<String>
        var description: String {
            "None of the measured voice pairs \(RedetectRealDiarizerTests.measuredPairs) is installed (found \(installed.sorted())). "
                + "Fred and Kathy ship with macOS (MacinTalk): check `say -v '?'` on this machine."
        }
    }

    static func measuredPair(installed: Set<String>) throws -> [String] {
        guard let pair = measuredPairs.first(where: { installed.isSuperset(of: $0) }) else {
            throw NoMeasuredVoicePair(installed: installed)
        }
        return pair
    }

    /// One diarizer for the suite: each forced count loads its models once.
    static let diarizer = FluidAudioDiarizer()

    /// One clip of `text` in `voice`, 16 kHz mono, its leading and trailing silence trimmed.
    private static func clip(_ text: String, voice: String, in dir: URL) throws -> [Float] {
        let url = dir.appendingPathComponent("\(voice)-\(UUID().uuidString).wav")
        try SyntheticSpeech.synthesize(text: text, voice: voice, to: url)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CocoaError(.fileReadUnknown)
        }
        try file.read(into: buffer)
        guard let channel = buffer.int16ChannelData else { throw CocoaError(.fileReadUnknown) }
        let samples = UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)).map { Float($0) / 32768 }
        let first = samples.firstIndex { abs($0) > 0.01 } ?? 0
        let last = samples.lastIndex { abs($0) > 0.01 } ?? max(samples.count - 1, 0)
        return Array(samples[first...max(first, last)])
    }

    private static func writeWav(_ samples: [Float], to url: URL) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true))
        let out = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try #require(buffer.int16ChannelData)
        for i in samples.indices { channel[0][i] = Int16(max(-32768, min(32767, samples[i] * 32767))) }
        try out.write(from: buffer)
    }

    private static func place(_ clip: [Float], at t: Double, gain: Float, into track: inout [Float]) {
        let start = Int(t * rate)
        if track.count < start + clip.count { track += [Float](repeating: 0, count: start + clip.count - track.count) }
        for i in clip.indices { track[start + i] += clip[i] * gain }
    }

    /// A one-to-one call, turn by turn: the user on the mic, the other side on the system channel.
    /// With `bleed`, the mic also hears the other side through the loudspeakers (6 dB down, 50 ms
    /// late), and its transcript has those lines too, as ASR would hear them. Written as a legacy
    /// dual-stream pair (`m.wav`, `m_mic.wav`) with its transcript (`t.json`).
    private static func recording(_ clips: Clips, bleed: Bool, in dir: URL) throws -> URL {
        var mic: [Float] = [], system: [Float] = [], segments: [[String: Any]] = []
        var t = 0.5
        for i in own.indices {
            let mine = clips.own[i], theirs = clips.far[i]
            place(mine, at: t, gain: 0.8, into: &mic)
            segments.append(["start": t, "end": t + Double(mine.count) / rate, "text": own[i], "source": "local", "speaker": "Local Speaker 1", "confidence": 0.9])
            t += Double(mine.count) / rate + 0.6
            place(theirs, at: t, gain: 0.8, into: &system)
            segments.append(["start": t, "end": t + Double(theirs.count) / rate, "text": far[i], "source": "remote", "speaker": "Remote Speaker 1", "confidence": 0.9])
            if bleed {
                place(theirs, at: t + 0.05, gain: 0.4, into: &mic)
                segments.append(["start": t + 0.05, "end": t + 0.05 + Double(theirs.count) / rate, "text": far[i], "source": "local", "speaker": "Local Speaker 1", "confidence": 0.9])
            }
            t += Double(theirs.count) / rate + 0.6
        }
        let length = max(mic.count, system.count)
        mic += [Float](repeating: 0, count: length - mic.count)
        system += [Float](repeating: 0, count: length - system.count)
        let systemURL = dir.appendingPathComponent("m.wav"), micURL = dir.appendingPathComponent("m_mic.wav")
        try writeWav(system, to: systemURL)
        try writeWav(mic, to: micURL)
        let transcript = dir.appendingPathComponent("t.json")
        try JSONSerialization.data(withJSONObject: ["metadata": ["audio_paths": [systemURL.path, micURL.path]], "segments": segments])
            .write(to: transcript)
        return transcript
    }

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("redetect-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func read(_ transcript: URL) throws -> (local: [[String: Any]], metadata: [String: Any]) {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: transcript)) as? [String: Any])
        let segments = try #require(json["segments"] as? [[String: Any]])
        return (segments.filter { $0["source"] as? String == "local" }, try #require(json["metadata"] as? [String: Any]))
    }

    @Test("a speaker-bleed mic re-detected at 1: one person, the echo voice kept apart, none of its lines under the person")
    func aBleedMicAtOneKeepsTheEchoVoiceApart() async throws {
        guard try await TestModels.ensureDiarization() else { return }
        let clips = try Self.clips.get()
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = try Self.recording(clips, bleed: true, in: dir)

        let outcome = try await TranscriptRediarizer.rediarize(
            transcript: transcript, source: "local", speakerCount: 1, diarizer: Self.diarizer, echoCanceller: nil)

        let (local, metadata) = try read(transcript)
        let echoVoices = Set(EchoNotice.Findings(metadata: metadata).voices.map(\.label))
        let mine = local.filter { Self.own.contains($0["text"] as? String ?? "") }
        let theirs = local.filter { Self.far.contains($0["text"] as? String ?? "") }
        #expect(outcome.speakerCount == 1 && metadata["speaker_count_local"] as? Int == 1)
        #expect(outcome.echoClusters >= 1)
        // The user: one person's label carries at least 11 lines in 12 of theirs, and none is hidden.
        let byLabel = Dictionary(grouping: mine) { $0["speaker"] as? String ?? "" }.mapValues(\.count)
        let person = try #require(byLabel.max { $0.value < $1.value })
        #expect(!echoVoices.contains(person.key) && person.key != "Local Unknown", "the user's lines: \(byLabel)")
        #expect(person.value * 12 >= mine.count * 11, "the user's lines: \(byLabel)")
        #expect(!mine.contains { $0["echo"] as? Bool == true })
        // The other side: none of its lines visible under the person.
        let underThePerson = theirs.filter { $0["echo"] as? Bool != true && $0["speaker"] as? String == person.key }
        #expect(underThePerson.isEmpty, "\(underThePerson.count) of the other side's lines under the user")
    }

    @Test("the voices are a measured pair, Fred and Kathy first; without one the suite fails, never substitutes")
    func theVoicesAreAMeasuredPair() throws {
        #expect(try Self.measuredPair(installed: ["Fred", "Kathy", "Ralph", "Karen"]) == ["Fred", "Kathy"])
        #expect(try Self.measuredPair(installed: ["Kathy", "Ralph"]) == ["Kathy", "Ralph"])
        #expect(throws: NoMeasuredVoicePair.self) { try Self.measuredPair(installed: ["Fred", "Ralph", "Samantha"]) }
    }

    /// At 1 only: the other counts are the scripted tests' (`aCleanChannelIsAsBefore`), and every
    /// real diarizer pass here costs CI time.
    @Test("a clean mic re-detected at 1 comes out as the stated count alone gives it")
    func aCleanMicIsAsBefore() async throws {
        guard try await TestModels.ensureDiarization() else { return }
        let clips = try Self.clips.get()
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = try Self.recording(clips, bleed: false, in: dir)
        let before = dir.appendingPathComponent("before.json")
        try FileManager.default.copyItem(at: now, to: before)

        let outcome = try await TranscriptRediarizer.rediarize(
            transcript: now, source: "local", speakerCount: 1, diarizer: Self.diarizer, echoCanceller: nil)
        let today = try await TranscriptRediarizer.rediarize(
            transcript: before, source: "local", speakerCount: 1, diarizer: OnlyAt(count: 1, inner: Self.diarizer), echoCanceller: nil)

        let (local, _) = try read(now), (expected, _) = try read(before)
        #expect(local.map { $0["speaker"] as? String } == expected.map { $0["speaker"] as? String })
        #expect(outcome.echoClusters == 0 && today.echoClusters == 0)
        #expect(outcome.speakerCount == today.speakerCount)
        #expect(!local.contains { $0["echo"] as? Bool == true })
    }

    /// Re-detect as it was before #265: the diarizer is asked for the stated count, whatever count it is handed.
    struct OnlyAt: DiarizationProvider {
        let count: Int
        let inner: FluidAudioDiarizer
        func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult {
            try await inner.diarize(audioPath: audioPath, numSpeakers: count)
        }
        func diarize(audio: [Float], numSpeakers: Int?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult {
            try await inner.diarize(audio: audio, numSpeakers: count, progress: progress)
        }
    }
}
