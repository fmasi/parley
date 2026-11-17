import AVFoundation
import Foundation
import Testing
@testable import TranscriberCore

/// #265 with the real diarizer, on synthetic speech (`say`): the scripted tests in
/// `TranscriptRediarizerTests` assume a diarizer that blends the echo voice into the user when asked
/// for the people alone and separates it when given room for one more. This pins that FluidAudio
/// does so, and that a clean channel comes out of re-detect as it did before.
///
/// Measured on this fixture (2026-11-17, FluidAudio's stock config, Karen as the user and Fred as the
/// other side): the bleed mic is one cluster at 1 and two at 2 (54 % / 46 %), and re-detect at 1
/// before #265 judged that one blended cluster echo — the user counted as nobody, their lines under
/// the echo voice. The clean mic is one cluster at 1 and at 2.
///
/// `.serialized`: CoreML and `say` are clients of shared media daemons (see
/// `SyntheticDiarizationTests`).
@Suite(.serialized) struct RedetectRealDiarizerTests {
    static let rate = 16_000.0

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
    ]

    /// One clip of `text` in `voice`, 16 kHz mono, its leading and trailing silence trimmed.
    private static func clip(_ text: String, voice: String, in dir: URL) throws -> [Float] {
        let url = dir.appendingPathComponent("\(voice)-\(UUID().uuidString).wav")
        try SyntheticSpeech.synthesize(text: text, voice: voice, to: url)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.int16ChannelData)
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

    /// A one-to-one call, turn by turn: `user` on the mic, `farVoice` on the system channel. With
    /// `bleed`, the mic also hears the far side through the loudspeakers (at half its level, 50 ms
    /// late), and its transcript has those lines too, as ASR would hear them. Written as a legacy
    /// dual-stream pair (`m.wav`, `m_mic.wav`) with its transcript (`t.json`).
    private static func recording(user: String, farVoice: String, bleed: Bool, in dir: URL) throws -> URL {
        var mic: [Float] = [], system: [Float] = [], segments: [[String: Any]] = []
        var t = 0.5
        for i in own.indices {
            let mine = try clip(own[i], voice: user, in: dir)
            place(mine, at: t, gain: 0.8, into: &mic)
            segments.append(["start": t, "end": t + Double(mine.count) / rate, "text": own[i], "source": "local", "speaker": "Local Speaker 1", "confidence": 0.9])
            t += Double(mine.count) / rate + 0.6
            let theirs = try clip(far[i], voice: farVoice, in: dir)
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

    /// The pair the numbers above were measured with, when installed; else the first two `say` offers.
    private static func voices() throws -> [String] {
        let installed = try SyntheticSpeech.availableVoices()
        return installed.isSuperset(of: ["Karen", "Fred"]) ? ["Karen", "Fred"] : try SyntheticSpeech.voices(2)
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
        let voices = try Self.voices()
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = try Self.recording(user: voices[0], farVoice: voices[1], bleed: true, in: dir)

        let outcome = try await TranscriptRediarizer.rediarize(
            transcript: transcript, source: "local", speakerCount: 1, diarizer: FluidAudioDiarizer(), echoCanceller: nil)

        let (local, metadata) = try read(transcript)
        let echoVoices = Set(EchoNotice.Findings(metadata: metadata).voices.map(\.label))
        let mine = local.filter { Self.own.contains($0["text"] as? String ?? "") }
        let theirs = local.filter { Self.far.contains($0["text"] as? String ?? "") }
        #expect(outcome.speakerCount == 1 && metadata["speaker_count_local"] as? Int == 1)
        #expect(outcome.echoClusters == 1)
        // The user's lines: one person's label, none hidden as echo.
        let user = Set(mine.compactMap { $0["speaker"] as? String })
        #expect(user.count == 1 && user.isDisjoint(with: echoVoices) && !user.contains("Local Unknown"))
        #expect(!mine.contains { $0["echo"] as? Bool == true })
        // The other side's lines: none visible under the person.
        let underThePerson = theirs.filter { $0["echo"] as? Bool != true && user.contains($0["speaker"] as? String ?? "") }
        #expect(underThePerson.isEmpty, "\(underThePerson.count) of the other side's lines under the user")
    }

    /// At 1 only: the other counts are the scripted tests' (`aCleanChannelIsAsBefore`), and every
    /// real diarizer pass here costs CI time.
    @Test("a clean mic re-detected at 1 comes out as the stated count alone gives it")
    func aCleanMicIsAsBefore() async throws {
        guard try await TestModels.ensureDiarization() else { return }
        let voices = try Self.voices()
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = try Self.recording(user: voices[0], farVoice: voices[1], bleed: false, in: dir)
        let before = dir.appendingPathComponent("before.json")
        try FileManager.default.copyItem(at: now, to: before)

        let outcome = try await TranscriptRediarizer.rediarize(
            transcript: now, source: "local", speakerCount: 1, diarizer: FluidAudioDiarizer(), echoCanceller: nil)
        let today = try await TranscriptRediarizer.rediarize(
            transcript: before, source: "local", speakerCount: 1, diarizer: OnlyAt(count: 1), echoCanceller: nil)

        let (local, _) = try read(now), (expected, _) = try read(before)
        #expect(local.map { $0["speaker"] as? String } == expected.map { $0["speaker"] as? String })
        #expect(outcome.echoClusters == 0 && today.echoClusters == 0)
        #expect(outcome.speakerCount == today.speakerCount)
        #expect(!local.contains { $0["echo"] as? Bool == true })
    }

    /// Re-detect as it was before #265: the diarizer is asked for the stated count, whatever count it is handed.
    struct OnlyAt: DiarizationProvider {
        let count: Int
        func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult {
            try await FluidAudioDiarizer().diarize(audioPath: audioPath, numSpeakers: count)
        }
        func diarize(audio: [Float], numSpeakers: Int?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult {
            try await FluidAudioDiarizer().diarize(audio: audio, numSpeakers: count, progress: progress)
        }
    }
}
