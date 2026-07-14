import AVFoundation
import Foundation

/// Deterministic multi-speaker audio generated at test time with macOS's built-in `say`.
///
/// This exists because the previous multi-speaker fixture (AMI ES2004a) was 33 MB, git-ignored,
/// and fetched by a script — so the plain CI `test` job never had it, the diarization guard
/// skipped silently, and the suite reported green while asserting nothing about speaker
/// separation. `say` ships on every Mac (including CI runners): fixtures are synthesized on
/// demand, cost zero bytes in git, and need no network.
///
/// Determinism: fixed voices, fixed texts, fixed rate, fixed output format. On a given
/// machine/OS the output is bit-identical across runs; across OS versions the voices may render
/// differently, which is fine — the tests assert *relations* (speaker counts, timestamp shifts),
/// not waveforms.
enum SyntheticSpeech {

    enum SynthesisError: Error, CustomStringConvertible {
        case sayFailed(voice: String, exitCode: Int32)
        case notEnoughVoices(wanted: Int, available: [String])

        var description: String {
            switch self {
            case .sayFailed(let voice, let code):
                return "`say -v \(voice)` exited with \(code)"
            case .notEnoughVoices(let wanted, let available):
                return "needed \(wanted) distinct TTS voices, found only \(available)"
            }
        }
    }

    /// All fixtures are 16 kHz mono Int16 — the layout the diarizer's models run at.
    static let sampleRate: Double = 16_000

    /// Preference-ordered voices, most acoustically distinct first (female/male, US/UK/IE
    /// accents). Alex is deliberately absent: it is a Siri-era download, not preinstalled on
    /// fresh macOS or CI runners. Everything here ships with the OS.
    private static let preferredVoices = [
        "Samantha", "Daniel", "Karen", "Moira", "Rishi", "Tessa", "Fred", "Kathy", "Ralph", "Albert",
    ]

    /// Words-per-minute passed to `say -r`, pinned so a voice's default rate changing across
    /// OS versions cannot move segment timings.
    private static let speakingRate = 175

    // MARK: - Voice discovery

    /// Voice names installed on this machine, parsed from `say -v '?'`.
    /// Line format: `Samantha            en_US    # Hello! My name is Samantha.`
    /// (names may contain spaces, e.g. "Bad News", hence the language-code anchor).
    static func availableVoices() throws -> Set<String> {
        let output = try run("/usr/bin/say", arguments: ["-v", "?"])
        var names: Set<String> = []
        for line in output.split(separator: "\n") {
            guard let range = line.range(of: #"\s+[a-z]{2,3}_[A-Z]"#, options: .regularExpression) else { continue }
            names.insert(String(line[line.startIndex..<range.lowerBound]))
        }
        return names
    }

    /// The first `count` preferred voices installed on this machine, in preference order.
    static func voices(_ count: Int) throws -> [String] {
        let installed = try availableVoices()
        let picked = preferredVoices.filter { installed.contains($0) }.prefix(count)
        guard picked.count == count else {
            throw SynthesisError.notEnoughVoices(wanted: count, available: Array(picked))
        }
        return Array(picked)
    }

    // MARK: - Synthesis

    /// Synthesize `text` with `voice` into a 16 kHz mono Int16 WAV at `url`.
    static func synthesize(text: String, voice: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-v", voice,
            "-r", String(speakingRate),
            "-o", url.path,
            "--data-format=LEI16@\(Int(sampleRate))",
            text,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SynthesisError.sayFailed(voice: voice, exitCode: process.terminationStatus)
        }
    }

    // MARK: - Editing (concatenate / pad)

    /// Concatenate WAVs into one, optionally inserting `gap` seconds of silence between clips
    /// and `leadingSilence` seconds before the first. All inputs must be 16 kHz mono Int16
    /// (what `synthesize` produces).
    static func concatenate(
        _ sources: [URL],
        to url: URL,
        gap: Double = 0.3,
        leadingSilence: Double = 0
    ) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true
        )!
        let output = try AVAudioFile(
            forWriting: url, settings: format.settings,
            commonFormat: .pcmFormatInt16, interleaved: true
        )

        func writeSilence(_ seconds: Double) throws {
            let frames = AVAudioFrameCount(seconds * sampleRate)
            guard frames > 0 else { return }
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames  // samples are zero-initialized
            try output.write(from: buffer)
        }

        try writeSilence(leadingSilence)
        for (index, source) in sources.enumerated() {
            if index > 0 { try writeSilence(gap) }
            let input = try AVAudioFile(
                forReading: source, commonFormat: .pcmFormatInt16, interleaved: true
            )
            let frames = AVAudioFrameCount(input.length)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            try input.read(into: buffer)
            try output.write(from: buffer)
        }
    }

    /// Mix `sources` into one clip by summing samples (each attenuated to avoid clipping),
    /// starting each source at its paired offset (seconds). Output length covers the longest
    /// source. This is how a real mixed mono meeting stream looks to the diarizer: OVERLAPPING
    /// voices — which concatenation alone can never produce, and which the
    /// `embeddingExcludeOverlap` collapse needs in order to manifest.
    static func mix(_ sources: [(url: URL, offset: Double)], to url: URL) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true
        )!
        var tracks: [(samples: [Int16], startFrame: Int)] = []
        for source in sources {
            let input = try AVAudioFile(
                forReading: source.url, commonFormat: .pcmFormatInt16, interleaved: true
            )
            let frames = AVAudioFrameCount(input.length)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            try input.read(into: buffer)
            let samples = Array(UnsafeBufferPointer(
                start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)
            ))
            tracks.append((samples, Int(source.offset * sampleRate)))
        }

        let totalFrames = tracks.map { $0.startFrame + $0.samples.count }.max() ?? 0
        let gain = 1.0 / Double(max(tracks.count, 1))
        var mixed = [Double](repeating: 0, count: totalFrames)
        for track in tracks {
            for (i, sample) in track.samples.enumerated() {
                mixed[track.startFrame + i] += Double(sample) * gain
            }
        }

        let output = try AVAudioFile(
            forWriting: url, settings: format.settings,
            commonFormat: .pcmFormatInt16, interleaved: true
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames))!
        buffer.frameLength = AVAudioFrameCount(totalFrames)
        let data = buffer.int16ChannelData![0]
        for i in 0..<totalFrames {
            data[i] = Int16(max(Double(Int16.min), min(Double(Int16.max), mixed[i])))
        }
        try output.write(from: buffer)
    }

    // MARK: - Shared fixtures

    /// Scripts long enough that each speaker yields a healthy number of embedding windows.
    /// Distinct topics so ASR-based tests can also tell the clips apart by content.
    static let scripts = [
        "The quarterly numbers look strong, and I believe we should expand the pilot program to "
            + "the northern region before the end of the fiscal year. Early feedback from customers "
            + "has been encouraging, and the support team reports very few open issues.",
        "I disagree with that assessment. The supply chain constraints have not been resolved, and "
            + "expanding now would stretch the logistics team far too thin. We should wait until the "
            + "new warehouse is fully operational before taking on any additional commitments.",
        "Perhaps there is a middle path. We could expand to two cities instead of ten, measure the "
            + "results for a full quarter, and then decide together whether the wider rollout makes "
            + "sense. That limits the downside while keeping the momentum we have built.",
    ]

    /// One single-speaker clip per requested voice, synthesized once per test run and shared.
    /// `static let` initialization is thread-safe, so parallel tests share one synthesis pass.
    private static let generated: Result<[URL], Error> = Result {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parley-synthetic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try voices(3).enumerated().map { index, voice in
            let url = dir.appendingPathComponent("speaker\(index)-\(voice).wav")
            try synthesize(text: scripts[index], voice: voice, to: url)
            return url
        }
    }

    /// `count` single-speaker clips (16 kHz mono WAV), each a different voice.
    static func speakerClips(_ count: Int) throws -> [URL] {
        let clips = try generated.get()
        precondition(count <= clips.count, "only \(clips.count) shared clips are pre-generated")
        return Array(clips.prefix(count))
    }

    /// A fresh output URL next to the shared clips.
    static func scratchURL(_ name: String) throws -> URL {
        try generated.get()[0].deletingLastPathComponent()
            .appendingPathComponent("\(name)-\(UUID().uuidString).wav")
    }

    // MARK: - Private

    private static func run(_ launchPath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
