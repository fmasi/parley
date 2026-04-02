import Foundation
import AVFoundation

// ── Engine imports ──
import WhisperKit
import WhisperCppKit
import FluidAudio
import Speech  // macOS 26 SpeechAnalyzer

// ──────────────────────────────────────────────
// ASR Engine Benchmark Tool
//
// Usage: swift run EngineBenchmark <audio.wav> [--engines whisperkit,whisper-cpp,fluid,speech]
//
// Transcribes the same audio file with each engine and reports:
//   - Wall clock time
//   - Segment count
//   - First 3 segments (for quality comparison)
//   - Real-time factor (audio duration / transcription time)
// ──────────────────────────────────────────────

struct BenchmarkResult {
    let engine: String
    let wallClockSeconds: Double
    let segmentCount: Int
    let sampleSegments: [(start: Double, end: Double, text: String)]
    let audioDurationSeconds: Double
    let fullText: String
    let error: String?
    var wer: Double?  // set after benchmarking if ground truth available

    var realtimeFactor: Double {
        guard wallClockSeconds > 0 else { return 0 }
        return audioDurationSeconds / wallClockSeconds
    }
}

// ── Audio utilities ──

func loadAudioAsFloats(url: URL, targetSampleRate: Double = 16000) throws -> (samples: [Float], duration: Double) {
    let file = try AVAudioFile(forReading: url)
    let originalRate = file.processingFormat.sampleRate
    let frameCount = AVAudioFrameCount(file.length)

    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
        throw NSError(domain: "Benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create buffer"])
    }
    try file.read(into: buffer)

    let duration = Double(file.length) / originalRate

    // Convert to mono Float32 at target sample rate
    let outputFormat = AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: 1)!
    guard let converter = AVAudioConverter(from: file.processingFormat, to: outputFormat) else {
        throw NSError(domain: "Benchmark", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create converter"])
    }

    let outputFrameCount = AVAudioFrameCount(duration * targetSampleRate)
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
        throw NSError(domain: "Benchmark", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create output buffer"])
    }

    var error: NSError?
    var inputProvided = false
    converter.convert(to: outputBuffer, error: &error) { _, outStatus in
        if inputProvided {
            outStatus.pointee = .endOfStream
            return nil
        }
        inputProvided = true
        outStatus.pointee = .haveData
        return buffer
    }
    if let error { throw error }

    let floatPtr = outputBuffer.floatChannelData![0]
    let samples = Array(UnsafeBufferPointer(start: floatPtr, count: Int(outputBuffer.frameLength)))

    return (samples, duration)
}

func getAudioDuration(url: URL) -> Double {
    guard let file = try? AVAudioFile(forReading: url) else { return 0 }
    return Double(file.length) / file.processingFormat.sampleRate
}

// ── WER (Word Error Rate) ──

/// Detect if text is predominantly CJK (Japanese, Korean, Chinese) — these need character-level comparison.
func isCJK(_ text: String) -> Bool {
    let cjkCount = text.unicodeScalars.filter { s in
        (0x3000...0x9FFF).contains(s.value) ||  // CJK Unified, Hiragana, Katakana
        (0xAC00...0xD7AF).contains(s.value) ||  // Hangul syllables
        (0xF900...0xFAFF).contains(s.value)      // CJK Compatibility
    }.count
    return cjkCount > text.unicodeScalars.count / 3
}

/// Normalize text for WER comparison: lowercase, strip punctuation, collapse whitespace.
func normalizeForWER(_ text: String) -> String {
    let lowered = text.lowercased()
    // Keep apostrophes (contractions), remove other punctuation
    let cleaned = lowered.unicodeScalars.map { s -> Character in
        if CharacterSet.punctuationCharacters.contains(s) && s != "'" {
            return " "
        }
        return Character(s)
    }
    return String(cleaned)
        .components(separatedBy: .whitespaces)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

/// Compute WER (word-level) or CER (character-level for CJK) using Levenshtein distance.
/// Returns (substitutions + deletions + insertions) / reference_count.
func computeWER(reference: String, hypothesis: String) -> Double {
    let refNorm = normalizeForWER(reference)
    let hypNorm = normalizeForWER(hypothesis)

    // For CJK languages, compare character-by-character (CER)
    let refTokens: [String]
    let hypTokens: [String]
    if isCJK(refNorm) {
        refTokens = refNorm.replacingOccurrences(of: " ", with: "").map(String.init)
        hypTokens = hypNorm.replacingOccurrences(of: " ", with: "").map(String.init)
    } else {
        refTokens = refNorm.split(separator: " ").map(String.init)
        hypTokens = hypNorm.split(separator: " ").map(String.init)
    }

    guard !refTokens.isEmpty else { return hypTokens.isEmpty ? 0 : 1 }

    let n = refTokens.count
    let m = hypTokens.count

    // 2-row DP for edit distance
    var prev = Array(0...m)
    var curr = [Int](repeating: 0, count: m + 1)

    for i in 1...n {
        curr[0] = i
        for j in 1...m {
            if refTokens[i - 1] == hypTokens[j - 1] {
                curr[j] = prev[j - 1]
            } else {
                curr[j] = 1 + min(prev[j - 1], prev[j], curr[j - 1])
            }
        }
        prev = curr
    }

    return Double(prev[m]) / Double(n)
}

/// Load ground truth from JSON file. Returns dict mapping filename -> reference text.
func loadGroundTruth(path: URL) -> [String: String] {
    guard let data = try? Data(contentsOf: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        print("WARNING: Could not load ground truth from \(path.path)")
        return [:]
    }

    var result: [String: String] = [:]
    for (_, value) in json {
        if value is String {
            // Bare string entry (e.g. "English clean": "Four score...")
            // Can't match by filename, skip — these are informational only
            continue
        }
        if let entries = value as? [[String: Any]] {
            for entry in entries {
                if let file = entry["file"] as? String,
                   let text = entry["text"] as? String {
                    result[file] = text
                }
            }
        }
    }
    return result
}

// ── Engine: WhisperKit ──

func benchmarkWhisperKit(audioPath: URL, audioDuration: Double) async -> BenchmarkResult {
    print("  Loading WhisperKit model...")
    let start = ContinuousClock.now

    do {
        let kit = try await WhisperKit(
            model: "large-v3_turbo",
            verbose: false,
            prewarm: true
        )

        let options = DecodingOptions(
            skipSpecialTokens: true,
            wordTimestamps: true,
            compressionRatioThreshold: 1.8 as Float,
            noSpeechThreshold: 0.8 as Float
        )

        print("  Transcribing...")
        let results = try await kit.transcribe(audioPath: audioPath.path, decodeOptions: options)

        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        var segments: [(Double, Double, String)] = []
        for result in results {
            for seg in result.segments {
                segments.append((Double(seg.start), Double(seg.end), seg.text))
            }
        }

        let fullText = segments.map(\.2).joined(separator: " ")

        return BenchmarkResult(
            engine: "WhisperKit (CoreML, large-v3-turbo)",
            wallClockSeconds: seconds,
            segmentCount: segments.count,
            sampleSegments: Array(segments.prefix(3)),
            audioDurationSeconds: audioDuration,
            fullText: fullText,
            error: nil
        )
    } catch {
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds)
        return BenchmarkResult(
            engine: "WhisperKit (CoreML, large-v3-turbo)",
            wallClockSeconds: seconds,
            segmentCount: 0,
            sampleSegments: [],
            audioDurationSeconds: audioDuration,
            fullText: "",
            error: error.localizedDescription
        )
    }
}

// ── Engine: WhisperCppKit (whisper.cpp) ──

func benchmarkWhisperCpp(audioPath: URL, audioDuration: Double) async -> BenchmarkResult {
    let start = ContinuousClock.now

    do {
        let modelDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".audio-transcribe/models")
        let ggmlModel = modelDir.appendingPathComponent("ggml-large-v3-turbo.bin")

        guard FileManager.default.fileExists(atPath: ggmlModel.path) else {
            return BenchmarkResult(
                engine: "WhisperCppKit (whisper.cpp, large-v3-turbo)",
                wallClockSeconds: 0,
                segmentCount: 0,
                sampleSegments: [],
                audioDurationSeconds: audioDuration,
                fullText: "",
                error: "GGML model not found at \(ggmlModel.path)"
            )
        }

        print("  Loading whisper.cpp model...")
        let ctx = try WhisperContext(modelPath: ggmlModel.path)

        print("  Loading audio...")
        let (samples, _) = try loadAudioAsFloats(url: audioPath)

        print("  Transcribing (language=auto)...")
        var options = WhisperOptions()
        options.language = nil  // auto-detect
        options.translateToEnglish = false
        let segments = try ctx.transcribe(pcm16k: samples, options: options)

        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        let fullText = segments.map(\.text).joined(separator: " ")
        let sampleSegs = segments.prefix(3).map { seg in
            (seg.startTime, seg.endTime, seg.text)
        }

        return BenchmarkResult(
            engine: "WhisperCppKit (whisper.cpp, large-v3-turbo)",
            wallClockSeconds: seconds,
            segmentCount: segments.count,
            sampleSegments: Array(sampleSegs),
            audioDurationSeconds: audioDuration,
            fullText: fullText,
            error: nil
        )
    } catch {
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds)
        return BenchmarkResult(
            engine: "WhisperCppKit (whisper.cpp, large-v3-turbo)",
            wallClockSeconds: seconds,
            segmentCount: 0,
            sampleSegments: [],
            audioDurationSeconds: audioDuration,
            fullText: "",
            error: error.localizedDescription
        )
    }
}

// ── Engine: FluidAudio ──

func benchmarkFluidAudio(audioPath: URL, audioDuration: Double) async -> BenchmarkResult {
    let start = ContinuousClock.now

    do {
        print("  Downloading/loading FluidAudio model...")
        let models = try await AsrModels.downloadAndLoad()
        let manager = AsrManager()
        try await manager.initialize(models: models)

        print("  Transcribing...")
        let result = try await manager.transcribe(audioPath, source: .system)

        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        // Group token timings into sentence-like segments by splitting on punctuation
        // (matches FluidAudioEngine.groupTokensIntoSegments in the app)
        let timings = result.tokenTimings ?? []
        let confidence = result.confidence
        var sentences: [(start: Double, end: Double, text: String)] = []
        var currentText = ""
        var segStart: Double = 0
        var segEnd: Double = 0

        for (i, t) in timings.enumerated() {
            if currentText.isEmpty { segStart = t.startTime }
            currentText += t.token
            segEnd = t.endTime
            let endsWithPunct = t.token.last.map { ".!?".contains($0) } ?? false
            // Don't split on "." when the next token starts with a digit (e.g. "1." + "5 million")
            let isDecimalDot: Bool = endsWithPunct && t.token.last == "." && i + 1 < timings.count
                && timings[i + 1].token.first?.isNumber == true
            let isSentenceEnd = (endsWithPunct && !isDecimalDot) || i == timings.count - 1
            if isSentenceEnd {
                let trimmed = currentText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    sentences.append((segStart, segEnd, trimmed))
                }
                currentText = ""
            }
        }

        print("  Confidence: \(confidence)")

        let sampleSegs = Array(sentences.prefix(3))

        print("  Full text preview: \(result.text.prefix(200))")

        return BenchmarkResult(
            engine: "FluidAudio (Parakeet, CoreML/ANE)",
            wallClockSeconds: seconds,
            segmentCount: sentences.count,
            sampleSegments: sampleSegs,
            audioDurationSeconds: audioDuration,
            fullText: result.text,
            error: nil
        )
    } catch {
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds)
        return BenchmarkResult(
            engine: "FluidAudio (Parakeet, CoreML/ANE)",
            wallClockSeconds: seconds,
            segmentCount: 0,
            sampleSegments: [],
            audioDurationSeconds: audioDuration,
            fullText: "",
            error: error.localizedDescription
        )
    }
}

// ── Engine: macOS 26 SpeechAnalyzer ──

@available(macOS 26.0, *)
func benchmarkSpeechAnalyzer(audioPath: URL, audioDuration: Double) async -> BenchmarkResult {
    let start = ContinuousClock.now

    do {
        print("  Setting up SpeechAnalyzer...")
        // Use preset with audioTimeRange to get timestamps
        let transcriber = SpeechTranscriber(
            locale: Locale.autoupdatingCurrent,
            preset: SpeechTranscriber.Preset(
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [.audioTimeRange]
            )
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        print("  Transcribing...")
        let audioFile = try AVAudioFile(forReading: audioPath)

        // Collect results and finalize concurrently
        var segmentCount = 0
        var sampleTexts: [(Double, Double, String)] = []
        var allText = ""

        // Start analysis (matches SpeechAnalyzerEngine in the app)
        let analysisTask = Task {
            do {
                if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        }

        for try await result in transcriber.results {
            if result.isFinal {
                segmentCount += 1
                let text = String(result.text.characters)

                // Extract timestamp range from AttributedString runs
                var segStart: Double = .greatestFiniteMagnitude
                var segEnd: Double = 0
                for run in result.text.runs {
                    if let timeRange = run.audioTimeRange {
                        let s = CMTimeGetSeconds(timeRange.start)
                        let e = CMTimeGetSeconds(timeRange.end)
                        if s < segStart { segStart = s }
                        if e > segEnd { segEnd = e }
                    }
                }
                if segStart == .greatestFiniteMagnitude { segStart = 0 }

                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if sampleTexts.count < 3 && !trimmed.isEmpty {
                    sampleTexts.append((segStart, segEnd, trimmed))
                }
                allText += text + " "
            }
        }

        try await analysisTask.value
        print("  Full text preview: \(allText.prefix(200))")

        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        let fullText = allText.trimmingCharacters(in: .whitespaces)
        return BenchmarkResult(
            engine: "SpeechAnalyzer (macOS 26, on-device)",
            wallClockSeconds: seconds,
            segmentCount: segmentCount,
            sampleSegments: sampleTexts,
            audioDurationSeconds: audioDuration,
            fullText: fullText,
            error: nil
        )
    } catch {
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds)
        return BenchmarkResult(
            engine: "SpeechAnalyzer (macOS 26, on-device)",
            wallClockSeconds: seconds,
            segmentCount: 0,
            sampleSegments: [],
            audioDurationSeconds: audioDuration,
            fullText: "",
            error: error.localizedDescription
        )
    }
}

// ── Engine: Python / mlx-whisper ──

func benchmarkMlxWhisper(audioPath: URL, audioDuration: Double) async -> BenchmarkResult {
    let start = ContinuousClock.now

    // Extract transcribe.py from main branch
    let scriptPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("benchmark-transcribe.py")
    // transcribe.py always writes master JSON to <input>.with_suffix(".json")
    // so we use a copy of the audio in /tmp to control the output location
    let outputPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bench-mlx-output.json")

    do {
        let gitResult = Process()
        gitResult.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        gitResult.arguments = ["show", "main:transcribe.py"]
        let gitPipe = Pipe()
        gitResult.standardOutput = gitPipe
        gitResult.standardError = Pipe()
        try gitResult.run()
        gitResult.waitUntilExit()

        let scriptData = gitPipe.fileHandleForReading.readDataToEndOfFile()
        guard !scriptData.isEmpty else {
            return BenchmarkResult(
                engine: "mlx-whisper (Python, large-v3, MLX GPU)",
                wallClockSeconds: 0, segmentCount: 0, sampleSegments: [],
                audioDurationSeconds: audioDuration, fullText: "",
                error: "Cannot extract transcribe.py from main branch"
            )
        }
        try scriptData.write(to: scriptPath)

        // Find python in conda env or PATH
        let pythonPath: String
        if let conda = ProcessInfo.processInfo.environment["CONDA_PREFIX"] {
            pythonPath = conda + "/bin/python"
        } else {
            pythonPath = "/usr/bin/python3"
        }

        // Remove stale output
        try? FileManager.default.removeItem(at: outputPath)

        print("  Running mlx-whisper via Python...")
        print("  Script: \(scriptPath.path)")
        print("  Output: \(outputPath.path)")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [
            scriptPath.path,
            "-i", audioPath.path,
            "-f", "json",
            "-o", outputPath.path,
            "--no-diarize",
        ]
        // Pass through environment (conda, HF_TOKEN, etc.)
        proc.environment = ProcessInfo.processInfo.environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        try proc.run()
        proc.waitUntilExit()

        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        let stdoutStr = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrStr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if !stdoutStr.isEmpty { print("  stdout: \(stdoutStr.prefix(500))") }
        if !stderrStr.isEmpty { print("  stderr: \(stderrStr.prefix(500))") }

        guard proc.terminationStatus == 0 else {
            return BenchmarkResult(
                engine: "mlx-whisper (Python, large-v3, MLX GPU)",
                wallClockSeconds: seconds, segmentCount: 0, sampleSegments: [],
                audioDurationSeconds: audioDuration, fullText: "",
                error: "Exit code \(proc.terminationStatus): \(stderrStr.prefix(300))"
            )
        }

        // transcribe.py writes master JSON alongside input file too
        // Check both the -o path and the input-derived path
        var jsonPath = outputPath
        if !FileManager.default.fileExists(atPath: jsonPath.path) {
            // Fall back to input file with .json extension
            let inputDerived = audioPath.deletingPathExtension().appendingPathExtension("json")
            if FileManager.default.fileExists(atPath: inputDerived.path) {
                jsonPath = inputDerived
                print("  Output found at: \(jsonPath.path)")
            }
        }

        // Parse output JSON
        let data = try Data(contentsOf: jsonPath)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let segments = json?["segments"] as? [[String: Any]] ?? []
        let sampleSegs = segments.prefix(3).map { seg in
            (seg["start"] as? Double ?? 0, seg["end"] as? Double ?? 0, seg["text"] as? String ?? "")
        }
        let fullText = (json?["text"] as? String)
            ?? segments.compactMap { $0["text"] as? String }.joined(separator: " ")

        // Cleanup
        try? FileManager.default.removeItem(at: scriptPath)
        try? FileManager.default.removeItem(at: outputPath)

        return BenchmarkResult(
            engine: "mlx-whisper (Python, large-v3, MLX GPU)",
            wallClockSeconds: seconds,
            segmentCount: segments.count,
            sampleSegments: Array(sampleSegs),
            audioDurationSeconds: audioDuration,
            fullText: fullText,
            error: nil
        )
    } catch {
        try? FileManager.default.removeItem(at: scriptPath)
        try? FileManager.default.removeItem(at: outputPath)
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds)
        return BenchmarkResult(
            engine: "mlx-whisper (Python, large-v3, MLX GPU)",
            wallClockSeconds: seconds, segmentCount: 0, sampleSegments: [],
            audioDurationSeconds: audioDuration, fullText: "",
            error: error.localizedDescription
        )
    }
}

// ── Table formatting (avoids String(format: %s) crash in Swift 6) ──

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

func rpad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
}

func tableRow(_ engine: String, _ time: String, _ segs: String, _ rtf: String, _ wer: String = "") -> String {
    var row = "\(pad(engine, 45)) \(rpad(time, 10)) \(rpad(segs, 8)) \(rpad(rtf, 8))"
    if !wer.isEmpty { row += " \(rpad(wer, 8))" }
    return row
}

// ── Logging (tee to file + stdout) ──

nonisolated(unsafe) var logFileHandle: FileHandle?

func log(_ message: String) {
    print(message)
    if let handle = logFileHandle {
        let line = message + "\n"
        handle.write(Data(line.utf8))
    }
}

// ── Report ──

func printResult(_ r: BenchmarkResult) {
    print("")
    print("  \(r.engine)")
    if let error = r.error {
        print("  ERROR: \(error)")
        return
    }
    let minutes = Int(r.wallClockSeconds) / 60
    let seconds = Int(r.wallClockSeconds) % 60
    print("  Wall clock: \(minutes)m \(seconds)s (\(String(format: "%.1f", r.wallClockSeconds))s)")
    print("  Segments: \(r.segmentCount)")
    print("  Real-time factor: \(String(format: "%.1f", r.realtimeFactor))x real-time")
    if let wer = r.wer {
        let label = isCJK(r.fullText) ? "CER" : "WER"
        print("  \(label): \(String(format: "%.1f", wer * 100))%")
    }
    print("  Sample segments:")
    for seg in r.sampleSegments {
        let startTs = String(format: "%02d:%02d", Int(seg.start) / 60, Int(seg.start) % 60)
        let endTs = String(format: "%02d:%02d", Int(seg.end) / 60, Int(seg.end) % 60)
        print("    [\(startTs)-\(endTs)] \(seg.text.prefix(80))")
    }
}

func writeReport(results: [BenchmarkResult], audioPath: URL, outputPath: URL) {
    let hasWER = results.contains { $0.wer != nil }
    var lines: [String] = []
    lines.append("ASR Engine Benchmark Report")
    lines.append("==========================")
    lines.append("Date: \(Date())")
    lines.append("Audio: \(audioPath.lastPathComponent)")
    lines.append("Duration: \(String(format: "%.0f", results.first?.audioDurationSeconds ?? 0))s")
    lines.append("")

    // Summary table
    lines.append(tableRow("Engine", "Time", "Segs", "RTF", hasWER ? "WER" : ""))
    lines.append(String(repeating: "─", count: hasWER ? 85 : 75))
    for r in results {
        if r.error != nil {
            lines.append(tableRow(r.engine, "ERROR", "-", "-", hasWER ? "-" : ""))
        } else {
            let time = "\(Int(r.wallClockSeconds) / 60)m \(Int(r.wallClockSeconds) % 60)s"
            let werStr = r.wer.map { String(format: "%.1f%%", $0 * 100) } ?? "-"
            lines.append(tableRow(r.engine, time, "\(r.segmentCount)", String(format: "%.1fx", r.realtimeFactor), hasWER ? werStr : ""))
        }
    }

    lines.append("")
    for r in results {
        lines.append("─── \(r.engine) ───")
        if let error = r.error {
            lines.append("ERROR: \(error)")
        } else {
            lines.append("Wall clock: \(String(format: "%.1f", r.wallClockSeconds))s")
            lines.append("Segments: \(r.segmentCount)")
            lines.append("Real-time factor: \(String(format: "%.1f", r.realtimeFactor))x")
            if let wer = r.wer {
                let label = isCJK(r.fullText) ? "CER" : "WER"
                lines.append("\(label): \(String(format: "%.1f", wer * 100))%")
            }
            lines.append("Sample output:")
            for seg in r.sampleSegments {
                lines.append("  [\(String(format: "%.1f", seg.start))-\(String(format: "%.1f", seg.end))] \(seg.text)")
            }
        }
        lines.append("")
    }

    try? lines.joined(separator: "\n").write(to: outputPath, atomically: true, encoding: .utf8)
}

// ── Diarization Benchmarking ──

struct DiarizationBenchmarkResult {
    let engine: String
    let wallClockSeconds: Double
    let segmentCount: Int
    let speakerCount: Int
    let sampleSegments: [(start: Double, end: Double, speaker: String, quality: Double)]
    let audioDurationSeconds: Double
    let error: String?

    var realtimeFactor: Double {
        guard wallClockSeconds > 0 else { return 0 }
        return audioDurationSeconds / wallClockSeconds
    }
}

func benchmarkFluidDiarization(audioPath: URL, audioDuration: Double) async -> DiarizationBenchmarkResult {
    let start = ContinuousClock.now

    do {
        print("  Loading diarization models...")
        let mgr = OfflineDiarizerManager()
        try await mgr.prepareModels()

        print("  Diarizing...")
        let result = try await mgr.process(audioPath)

        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        let segments = result.segments.map { seg in
            (Double(seg.startTimeSeconds), Double(seg.endTimeSeconds), seg.speakerId, Double(seg.qualityScore))
        }
        let speakerCount = Set(result.segments.map(\.speakerId)).count

        return DiarizationBenchmarkResult(
            engine: "FluidAudio Diarization (pyannote + WeSpeaker + VBx)",
            wallClockSeconds: seconds,
            segmentCount: segments.count,
            speakerCount: speakerCount,
            sampleSegments: Array(segments.prefix(5)),
            audioDurationSeconds: audioDuration,
            error: nil
        )
    } catch {
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds)
        return DiarizationBenchmarkResult(
            engine: "FluidAudio Diarization (pyannote + WeSpeaker + VBx)",
            wallClockSeconds: seconds,
            segmentCount: 0,
            speakerCount: 0,
            sampleSegments: [],
            audioDurationSeconds: audioDuration,
            error: error.localizedDescription
        )
    }
}

func printDiarizationResult(_ r: DiarizationBenchmarkResult) {
    print("")
    print("  \(r.engine)")
    if let error = r.error {
        print("  ERROR: \(error)")
        return
    }
    let minutes = Int(r.wallClockSeconds) / 60
    let seconds = Int(r.wallClockSeconds) % 60
    print("  Wall clock: \(minutes)m \(seconds)s (\(String(format: "%.1f", r.wallClockSeconds))s)")
    print("  Speakers: \(r.speakerCount)")
    print("  Segments: \(r.segmentCount)")
    print("  Real-time factor: \(String(format: "%.1f", r.realtimeFactor))x real-time")
    print("  Sample segments:")
    for seg in r.sampleSegments {
        let startTs = String(format: "%02d:%02d", Int(seg.start) / 60, Int(seg.start) % 60)
        let endTs = String(format: "%02d:%02d", Int(seg.end) / 60, Int(seg.end) % 60)
        print("    [\(startTs)-\(endTs)] Speaker \(seg.speaker) (quality: \(String(format: "%.2f", seg.quality)))")
    }
    // TODO: Add DER (Diarization Error Rate) scoring when RTTM ground truth is available
}

// ── Diarization Threshold Sweep ──

struct ThresholdSweepResult {
    let threshold: Double
    let speakerCount: Int
    let segmentCount: Int
    let wallClockSeconds: Double
    let speakers: [String: Int]  // speaker -> segment count
}

func runDiarizationSweep(audioPath: URL, audioDuration: Double, thresholds: [Double]) async {
    print("\n╔═══════════════════════════════════════════╗")
    print("║  Diarization Threshold Sweep              ║")
    print("╚═══════════════════════════════════════════╝")
    print("Audio: \(audioPath.lastPathComponent)")
    print("Duration: \(Int(audioDuration) / 60)m \(Int(audioDuration) % 60)s")
    print("Thresholds: \(thresholds.map { String(format: "%.2f", $0) }.joined(separator: ", "))")
    print("")

    // Pre-load models once (shared cache on disk, each manager reuses compiled models)
    print("Preparing diarization models (one-time)...")
    let modelLoadStart = ContinuousClock.now
    let warmupMgr = OfflineDiarizerManager()
    do {
        try await warmupMgr.prepareModels()
    } catch {
        print("ERROR: Failed to load models: \(error.localizedDescription)")
        return
    }
    let modelLoadElapsed = ContinuousClock.now - modelLoadStart
    print("Models ready in \(String(format: "%.1f", Double(modelLoadElapsed.components.seconds)))s\n")

    var results: [ThresholdSweepResult] = []

    for threshold in thresholds {
        print("── Threshold: \(String(format: "%.2f", threshold)) ──")
        let config = OfflineDiarizerConfig(clusteringThreshold: threshold)
        let mgr = OfflineDiarizerManager(config: config)
        do {
            try await mgr.prepareModels()  // fast — models already cached
            let runStart = ContinuousClock.now
            let result = try await mgr.process(audioPath)
            let elapsed = ContinuousClock.now - runStart
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

            var speakerCounts: [String: Int] = [:]
            for seg in result.segments {
                speakerCounts[seg.speakerId, default: 0] += 1
            }
            let speakerCount = speakerCounts.count

            let sweepResult = ThresholdSweepResult(
                threshold: threshold,
                speakerCount: speakerCount,
                segmentCount: result.segments.count,
                wallClockSeconds: seconds,
                speakers: speakerCounts
            )
            results.append(sweepResult)

            print("  Speakers: \(speakerCount), Segments: \(result.segments.count), Time: \(String(format: "%.1f", seconds))s")
            for (speaker, count) in speakerCounts.sorted(by: { $0.value > $1.value }) {
                print("    \(speaker): \(count) segments")
            }
        } catch {
            print("  ERROR: \(error.localizedDescription)")
        }
        print("")
    }

    // Summary table
    print("══════ Sweep Summary ══════\n")
    print("  Threshold | Speakers | Segments | Time")
    print("  ----------|----------|----------|------")
    for r in results {
        print("  \(String(format: "%.2f", r.threshold))      | \(String(format: "%8d", r.speakerCount)) | \(String(format: "%8d", r.segmentCount)) | \(String(format: "%.1f", r.wallClockSeconds))s")
    }

    // Save report
    let reportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".audio-transcribe/benchmark")
    try? FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let reportPath = reportDir.appendingPathComponent("diarize-sweep-\(formatter.string(from: Date())).txt")

    var lines = [
        "Diarization Threshold Sweep",
        "Audio: \(audioPath.lastPathComponent)",
        "Duration: \(Int(audioDuration) / 60)m \(Int(audioDuration) % 60)s",
        "",
        "Threshold | Speakers | Segments | Time | Speakers",
    ]
    for r in results {
        let speakerList = r.speakers.sorted(by: { $0.value > $1.value }).map { "\($0.key):\($0.value)" }.joined(separator: ", ")
        lines.append("\(String(format: "%.2f", r.threshold)) | \(r.speakerCount) | \(r.segmentCount) | \(String(format: "%.1f", r.wallClockSeconds))s | \(speakerList)")
    }
    try? lines.joined(separator: "\n").write(to: reportPath, atomically: true, encoding: .utf8)
    print("\nReport saved: \(reportPath.path)")
}

// ── Engine-Language Compatibility ──

/// FluidAudio Parakeet v3 supports 25 European languages.
/// Turkish is NOT supported despite Turkey being partially European — confirmed by 100% WER in benchmarks.
/// WhisperKit, WhisperCppKit, SpeechAnalyzer, and mlx-whisper support 99+ languages.
let fluidAudioLanguages: Set<String> = [
    "en", "fr", "pt", "es", "fi", "de", "it", "nl", "pl",
    "sv", "da", "no", "cs", "sk", "hu", "ro", "bg", "hr", "sl",
    "lt", "lv", "et", "el", "uk",
]

/// WhisperCppKit crashes with a fatal Range error on Korean text output (upstream bug).
/// Skip Korean until the bug is fixed in WhisperCppKit.
let whisperCppSkipLanguages: Set<String> = ["ko"]

/// Returns true if the engine supports the given language code.
func engineSupportsLanguage(_ engine: String, _ lang: String) -> Bool {
    if engine == "fluid" {
        return fluidAudioLanguages.contains(lang)
    }
    if engine == "whisper-cpp" {
        return !whisperCppSkipLanguages.contains(lang)
    }
    return true  // all other engines support all languages
}

/// Infer language code from audio filename (e.g. "fr-fr-fleurs-00.wav" -> "fr", "en-clean-gettysburg.mp3" -> "en").
func inferLanguage(from filename: String) -> String {
    let name = filename.lowercased()
    if name.hasPrefix("en") { return "en" }
    if name.hasPrefix("fr") { return "fr" }
    if name.hasPrefix("pt") { return "pt" }
    if name.hasPrefix("es") { return "es" }
    if name.hasPrefix("tr") { return "tr" }
    if name.hasPrefix("fi") { return "fi" }
    if name.hasPrefix("ko") { return "ko" }
    if name.hasPrefix("ja") { return "ja" }
    if name.hasPrefix("de") { return "de" }
    if name.hasPrefix("it") { return "it" }
    if name.hasPrefix("zh") { return "zh" }
    // Default to English
    return "en"
}

/// Map language code to Locale for SpeechAnalyzer.
func localeForLanguage(_ lang: String) -> Locale {
    let localeMap: [String: String] = [
        "en": "en-US", "fr": "fr-FR", "pt": "pt-BR", "es": "es-ES",
        "tr": "tr-TR", "fi": "fi-FI", "ko": "ko-KR", "ja": "ja-JP",
        "de": "de-DE", "it": "it-IT", "zh": "zh-CN",
    ]
    return Locale(identifier: localeMap[lang] ?? "en-US")
}

// ── Batch Benchmark ──

struct BatchResult {
    let filename: String
    let language: String
    let engineResults: [BenchmarkResult]
}

/// Run benchmarks across all audio files in a directory.
/// Loads each engine model once, reuses across files.
func runBatchBenchmark(
    directory: URL,
    engines: Set<String>,
    groundTruth: [String: String]
) async -> [BatchResult] {
    let fm = FileManager.default
    let extensions: Set<String> = ["wav", "mp3", "flac", "m4a"]

    guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
        print("ERROR: Cannot read directory \(directory.path)")
        return []
    }

    let audioFiles = contents
        .filter { extensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    guard !audioFiles.isEmpty else {
        print("ERROR: No audio files found in \(directory.path)")
        return []
    }

    print("Found \(audioFiles.count) audio files in \(directory.path)")

    // ── Pre-load models once ──
    print("\n══════ Loading models (one-time) ══════")

    var whisperKitInstance: WhisperKit?
    if engines.contains("whisperkit") {
        print("  WhisperKit...")
        whisperKitInstance = try? await WhisperKit(model: "large-v3_turbo", verbose: false, prewarm: true)
        print("  WhisperKit: \(whisperKitInstance != nil ? "ready" : "failed")")
    }

    var fluidManager: AsrManager?
    if engines.contains("fluid") {
        print("  FluidAudio...")
        do {
            let models = try await AsrModels.downloadAndLoad()
            let mgr = AsrManager()
            try await mgr.initialize(models: models)
            fluidManager = mgr
            _ = models  // models retained by manager
            print("  FluidAudio: ready")
        } catch {
            print("  FluidAudio: failed — \(error.localizedDescription)")
        }
    }

    var whisperCtx: WhisperContext?
    if engines.contains("whisper-cpp") {
        let modelPath = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".audio-transcribe/models/ggml-large-v3-turbo.bin")
        if fm.fileExists(atPath: modelPath.path) {
            print("  WhisperCppKit...")
            whisperCtx = try? WhisperContext(modelPath: modelPath.path)
            print("  WhisperCppKit: \(whisperCtx != nil ? "ready" : "failed")")
        } else {
            print("  WhisperCppKit: GGML model not found, skipping")
        }
    }

    // ── Run benchmarks per file ──
    print("\n══════ Running batch benchmarks ══════")
    var batchResults: [BatchResult] = []

    for audioFile in audioFiles {
        let filename = audioFile.lastPathComponent
        let lang = inferLanguage(from: filename)
        let duration = getAudioDuration(url: audioFile)

        print("\n━━━ \(filename) (\(lang), \(Int(duration))s) ━━━")

        var fileResults: [BenchmarkResult] = []

        // WhisperKit (reuse instance)
        if engines.contains("whisperkit"), let kit = whisperKitInstance {
            print("  WhisperKit...")
            let start = ContinuousClock.now
            do {
                let options = DecodingOptions(
                    skipSpecialTokens: true, wordTimestamps: true,
                    compressionRatioThreshold: 1.8, noSpeechThreshold: 0.8
                )
                let results = try await kit.transcribe(audioPath: audioFile.path, decodeOptions: options)
                let elapsed = ContinuousClock.now - start
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                var segments: [(Double, Double, String)] = []
                for r in results { for s in r.segments { segments.append((Double(s.start), Double(s.end), s.text)) } }
                let fullText = segments.map(\.2).joined(separator: " ")
                fileResults.append(BenchmarkResult(
                    engine: "WhisperKit", wallClockSeconds: seconds,
                    segmentCount: segments.count, sampleSegments: Array(segments.prefix(3)),
                    audioDurationSeconds: duration, fullText: fullText, error: nil
                ))
            } catch {
                let s = Double((ContinuousClock.now - start).components.seconds)
                fileResults.append(BenchmarkResult(
                    engine: "WhisperKit", wallClockSeconds: s,
                    segmentCount: 0, sampleSegments: [], audioDurationSeconds: duration,
                    fullText: "", error: error.localizedDescription
                ))
            }
        }

        // FluidAudio (reuse manager — skip if language unsupported)
        if engines.contains("fluid"), engineSupportsLanguage("fluid", lang), let mgr = fluidManager {
            print("  FluidAudio...")
            let start = ContinuousClock.now
            do {
                let result = try await mgr.transcribe(audioFile, source: .system)
                let elapsed = ContinuousClock.now - start
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                fileResults.append(BenchmarkResult(
                    engine: "FluidAudio", wallClockSeconds: seconds,
                    segmentCount: result.tokenTimings?.count ?? 0,
                    sampleSegments: [], audioDurationSeconds: duration,
                    fullText: result.text, error: nil
                ))
            } catch {
                let s = Double((ContinuousClock.now - start).components.seconds)
                fileResults.append(BenchmarkResult(
                    engine: "FluidAudio", wallClockSeconds: s,
                    segmentCount: 0, sampleSegments: [], audioDurationSeconds: duration,
                    fullText: "", error: error.localizedDescription
                ))
            }
        } else if engines.contains("fluid") && !engineSupportsLanguage("fluid", lang) {
            print("  FluidAudio: skipped (language \(lang) not supported)")
        }

        // WhisperCppKit (reuse context)
        if engines.contains("whisper-cpp"), let ctx = whisperCtx {
            print("  WhisperCppKit...")
            let start = ContinuousClock.now
            do {
                let (samples, _) = try loadAudioAsFloats(url: audioFile)
                var options = WhisperOptions()
                options.language = lang == "en" ? "en" : nil  // auto-detect for non-English
                options.translateToEnglish = false
                let segments = try ctx.transcribe(pcm16k: samples, options: options)
                let elapsed = ContinuousClock.now - start
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                let fullText = segments.map(\.text).joined(separator: " ")
                let sampleSegs = segments.prefix(3).map { ($0.startTime, $0.endTime, $0.text) }
                fileResults.append(BenchmarkResult(
                    engine: "WhisperCppKit", wallClockSeconds: seconds,
                    segmentCount: segments.count, sampleSegments: Array(sampleSegs),
                    audioDurationSeconds: duration, fullText: fullText, error: nil
                ))
            } catch {
                let s = Double((ContinuousClock.now - start).components.seconds)
                fileResults.append(BenchmarkResult(
                    engine: "WhisperCppKit", wallClockSeconds: s,
                    segmentCount: 0, sampleSegments: [], audioDurationSeconds: duration,
                    fullText: "", error: error.localizedDescription
                ))
            }
        }

        // SpeechAnalyzer (no pre-loaded state needed, but set locale per language)
        if engines.contains("speech") {
            if #available(macOS 26.0, *) {
                print("  SpeechAnalyzer...")
                let locale = localeForLanguage(lang)
                let start = ContinuousClock.now
                do {
                    let transcriber = SpeechTranscriber(
                        locale: locale,
                        preset: SpeechTranscriber.Preset(
                            transcriptionOptions: [],
                            reportingOptions: [.volatileResults],
                            attributeOptions: [.audioTimeRange]
                        )
                    )
                    let analyzer = SpeechAnalyzer(modules: [transcriber])
                    let audioFileObj = try AVAudioFile(forReading: audioFile)

                    let analysisTask = Task {
                        do {
                            if let lastSample = try await analyzer.analyzeSequence(from: audioFileObj) {
                                try await analyzer.finalizeAndFinish(through: lastSample)
                            } else { await analyzer.cancelAndFinishNow() }
                        } catch { await analyzer.cancelAndFinishNow(); throw error }
                    }

                    var allText = ""
                    var segCount = 0
                    for try await result in transcriber.results {
                        if result.isFinal {
                            segCount += 1
                            allText += String(result.text.characters) + " "
                        }
                    }
                    try await analysisTask.value

                    let elapsed = ContinuousClock.now - start
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    fileResults.append(BenchmarkResult(
                        engine: "SpeechAnalyzer", wallClockSeconds: seconds,
                        segmentCount: segCount, sampleSegments: [],
                        audioDurationSeconds: duration,
                        fullText: allText.trimmingCharacters(in: .whitespaces), error: nil
                    ))
                } catch {
                    let s = Double((ContinuousClock.now - start).components.seconds)
                    fileResults.append(BenchmarkResult(
                        engine: "SpeechAnalyzer", wallClockSeconds: s,
                        segmentCount: 0, sampleSegments: [], audioDurationSeconds: duration,
                        fullText: "", error: error.localizedDescription
                    ))
                }
            }
        }

        // Compute WER for each result
        if let reference = groundTruth[filename] {
            for i in fileResults.indices {
                if fileResults[i].error == nil && !fileResults[i].fullText.isEmpty {
                    fileResults[i].wer = computeWER(reference: reference, hypothesis: fileResults[i].fullText)
                }
            }
        }

        // Print per-file summary
        for r in fileResults {
            if let error = r.error {
                print("    \(r.engine): ERROR — \(error.prefix(60))")
            } else {
                let werStr = r.wer.map { String(format: "%.1f%%", $0 * 100) } ?? "-"
                print("    \(r.engine): \(String(format: "%.1f", r.realtimeFactor))x RT, WER \(werStr)")
            }
        }

        batchResults.append(BatchResult(filename: filename, language: lang, engineResults: fileResults))
    }

    return batchResults
}

/// Write a markdown matrix report from batch results.
func writeMatrixReport(batchResults: [BatchResult], outputPath: URL) {
    var lines: [String] = []
    lines.append("# ASR Engine Benchmark Matrix")
    lines.append("")
    lines.append("Date: \(Date())")
    lines.append("")

    // Collect all unique engines across all results
    var allEngines: [String] = []
    for br in batchResults {
        for er in br.engineResults {
            if !allEngines.contains(er.engine) { allEngines.append(er.engine) }
        }
    }

    // Header row
    var header = "| File | Lang |"
    for e in allEngines { header += " \(e) WER | \(e) RTF |" }
    lines.append(header)

    var sep = "|------|------|"
    for _ in allEngines { sep += "---:|---:|" }
    lines.append(sep)

    // Data rows
    for br in batchResults {
        var row = "| \(br.filename) | \(br.language) |"
        for engineName in allEngines {
            if let er = br.engineResults.first(where: { $0.engine == engineName }) {
                if er.error != nil {
                    row += " ERR | - |"
                } else {
                    let werStr = er.wer.map { String(format: "%.1f%%", $0 * 100) } ?? "-"
                    row += " \(werStr) | \(String(format: "%.1fx", er.realtimeFactor)) |"
                }
            } else {
                row += " - | - |"
            }
        }
        lines.append(row)
    }

    // Per-language averages
    lines.append("")
    lines.append("## Average by Language")
    lines.append("")
    lines.append("| Language |" + allEngines.map { " \($0) WER |" }.joined())
    lines.append("|----------|" + allEngines.map { _ in "---:|" }.joined())

    let languages = Array(Set(batchResults.map(\.language))).sorted()
    for lang in languages {
        let langResults = batchResults.filter { $0.language == lang }
        var row = "| \(lang) |"
        for engineName in allEngines {
            let wers = langResults.flatMap(\.engineResults)
                .filter { $0.engine == engineName && $0.wer != nil }
                .compactMap(\.wer)
            if wers.isEmpty {
                row += " - |"
            } else {
                let avg = wers.reduce(0, +) / Double(wers.count)
                row += " \(String(format: "%.1f%%", avg * 100)) |"
            }
        }
        lines.append(row)
    }

    try? lines.joined(separator: "\n").write(to: outputPath, atomically: true, encoding: .utf8)
}

// ── Main ──

@main
struct EngineBenchmarkCLI {
    static func main() async {
        let args = CommandLine.arguments

        guard args.count >= 2 else {
            print("Usage: EngineBenchmark <audio.wav> [options]")
            print("       EngineBenchmark --batch <directory> [options]")
            print("")
            print("Engines (--engines flag):")
            print("  whisperkit   — WhisperKit (CoreML, large-v3-turbo)")
            print("  whisper-cpp  — WhisperCppKit / whisper.cpp (Metal GPU)")
            print("  fluid        — FluidAudio (Parakeet, CoreML/ANE)")
            print("  speech       — macOS 26 SpeechAnalyzer (on-device)")
            print("  mlx          — mlx-whisper (Python, large-v3, MLX GPU)")
            print("  all          — run all engines (default)")
            print("")
            print("Options:")
            print("  --ground-truth <path>  JSON file with reference transcripts for WER scoring")
            print("  --batch <directory>    Run all audio files in directory (loads models once)")
            print("  --diarize              Also benchmark FluidAudio speaker diarization")
            print("  --diarize-sweep        Sweep clustering thresholds (0.35-0.70) for speaker count tuning")
            print("  --thresholds <list>    Custom thresholds for sweep (comma-separated, e.g. 0.4,0.5,0.6)")
            Foundation.exit(1)
        }

        // Parse --engines flag (shared between single and batch modes)
        var engines = Set(["whisperkit", "whisper-cpp", "fluid", "speech", "mlx"])
        if let idx = args.firstIndex(of: "--engines"), idx + 1 < args.count {
            engines = Set(args[idx + 1].split(separator: ",").map(String.init))
        }

        // Parse --ground-truth flag
        var groundTruth: [String: String] = [:]
        if let idx = args.firstIndex(of: "--ground-truth"), idx + 1 < args.count {
            let gtPath = URL(fileURLWithPath: args[idx + 1])
            groundTruth = loadGroundTruth(path: gtPath)
            if groundTruth.isEmpty {
                print("WARNING: No ground truth entries loaded from \(gtPath.path)")
            } else {
                print("Ground truth: \(groundTruth.count) entries loaded")
            }
        }

        // ── Batch mode ──
        if let idx = args.firstIndex(of: "--batch"), idx + 1 < args.count {
            let batchDir = URL(fileURLWithPath: args[idx + 1])

            // Auto-load ground truth from directory if not specified
            if groundTruth.isEmpty {
                let autoGT = batchDir.appendingPathComponent("ground-truth.json")
                if FileManager.default.fileExists(atPath: autoGT.path) {
                    groundTruth = loadGroundTruth(path: autoGT)
                    print("Ground truth: auto-loaded \(groundTruth.count) entries from \(autoGT.path)")
                }
            }

            // Exclude mlx from batch mode (subprocess overhead per file, no model reuse)
            var batchEngines = engines
            batchEngines.remove("mlx")

            log("╔═══════════════════════════════════════════╗")
            log("║  ASR Engine Benchmark — Batch Mode        ║")
            log("╚═══════════════════════════════════════════╝")

            let batchResults = await runBatchBenchmark(
                directory: batchDir,
                engines: batchEngines,
                groundTruth: groundTruth
            )

            // Save matrix report
            let reportDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".audio-transcribe/benchmark")
            try? FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
            let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
                .replacingOccurrences(of: "/", with: "-")
            let reportPath = reportDir.appendingPathComponent("matrix-\(dateStr).md")
            writeMatrixReport(batchResults: batchResults, outputPath: reportPath)
            print("\n══════ Complete ══════")
            print("Matrix report: \(reportPath.path)")
            return
        }

        // ── Single-file mode ──
        let audioPath = URL(fileURLWithPath: args[1])
        guard FileManager.default.fileExists(atPath: audioPath.path) else {
            print("ERROR: Audio file not found: \(audioPath.path)")
            Foundation.exit(1)
        }

        let audioDuration = getAudioDuration(url: audioPath)

        // Set up log file (tee output to file + stdout)
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".audio-transcribe/benchmark")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logPath = logDir.appendingPathComponent("engine-benchmark-\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none).replacingOccurrences(of: "/", with: "-")).log")
        FileManager.default.createFile(atPath: logPath.path, contents: nil)
        logFileHandle = FileHandle(forWritingAtPath: logPath.path)

        log("╔═══════════════════════════════════════════╗")
        log("║  ASR Engine Benchmark                     ║")
        log("╚═══════════════════════════════════════════╝")
        print("")
        print("Audio: \(audioPath.lastPathComponent)")
        print("Duration: \(Int(audioDuration) / 60)m \(Int(audioDuration) % 60)s")
        print("Engines: \(engines.sorted().joined(separator: ", "))")

        // ── Preparation: download models and warm up before timing ──
        print("\n══════ Preparing models (not timed) ══════")

        if engines.contains("whisperkit") {
            print("\n  WhisperKit: downloading/compiling model if needed...")
            do {
                let _ = try await WhisperKit(model: "large-v3_turbo", verbose: false, prewarm: true)
                print("  WhisperKit: ready")
            } catch {
                print("  WhisperKit: setup failed — \(error.localizedDescription)")
            }
        }

        if engines.contains("fluid") {
            print("\n  FluidAudio: downloading model if needed...")
            do {
                let _ = try await AsrModels.downloadAndLoad()
                print("  FluidAudio: ready")
            } catch {
                print("  FluidAudio: setup failed — \(error.localizedDescription)")
            }
        }

        if engines.contains("whisper-cpp") {
            let modelDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".audio-transcribe/models")
            let ggmlModel = modelDir.appendingPathComponent("ggml-large-v3-turbo.bin")
            if FileManager.default.fileExists(atPath: ggmlModel.path) {
                print("\n  WhisperCppKit: GGML model found")
            } else {
                print("\n  WhisperCppKit: GGML model NOT found. Downloading (~1.6GB)...")
                try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
                let downloadURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                proc.arguments = ["-L", "-o", ggmlModel.path, "--progress-bar", downloadURL]
                try? proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    print("  WhisperCppKit: download complete")
                } else {
                    print("  WhisperCppKit: download failed — will skip benchmark")
                    engines.remove("whisper-cpp")
                }
            }
        }

        if engines.contains("speech") {
            if #available(macOS 26.0, *) {
                print("\n  SpeechAnalyzer: system framework, no download needed")
            } else {
                print("\n  SpeechAnalyzer: requires macOS 26.0+, will skip")
            }
        }

        if engines.contains("mlx") {
            let conda = ProcessInfo.processInfo.environment["CONDA_PREFIX"] ?? ""
            if conda.isEmpty {
                print("\n  mlx-whisper: WARNING — no conda env active, may fail")
            } else {
                print("\n  mlx-whisper: conda env active (\(URL(fileURLWithPath: conda).lastPathComponent))")
            }
        }

        print("\n══════ Running benchmarks ══════")

        var results: [BenchmarkResult] = []

        if engines.contains("whisperkit") {
            print("\n── WhisperKit ──")
            let r = await benchmarkWhisperKit(audioPath: audioPath, audioDuration: audioDuration)
            printResult(r)
            results.append(r)
        }

        if engines.contains("fluid") {
            print("\n── FluidAudio ──")
            let r = await benchmarkFluidAudio(audioPath: audioPath, audioDuration: audioDuration)
            printResult(r)
            results.append(r)
        }

        if engines.contains("whisper-cpp") {
            print("\n── SwiftWhisper (whisper.cpp) ──")
            let r = await benchmarkWhisperCpp(audioPath: audioPath, audioDuration: audioDuration)
            printResult(r)
            results.append(r)
        }

        if engines.contains("speech") {
            print("\n── SpeechAnalyzer (macOS 26) ──")
            if #available(macOS 26.0, *) {
                let r = await benchmarkSpeechAnalyzer(audioPath: audioPath, audioDuration: audioDuration)
                printResult(r)
                results.append(r)
            } else {
                print("  SKIPPED: Requires macOS 26.0+")
            }
        }

        if engines.contains("mlx") {
            print("\n── mlx-whisper (Python) ──")
            let r = await benchmarkMlxWhisper(audioPath: audioPath, audioDuration: audioDuration)
            printResult(r)
            results.append(r)
        }

        // Diarization benchmark (single-file mode)
        if args.contains("--diarize") {
            print("\n── Diarization: FluidAudio ──")
            let dr = await benchmarkFluidDiarization(audioPath: audioPath, audioDuration: audioDuration)
            printDiarizationResult(dr)
        }

        // Diarization threshold sweep
        if args.contains("--diarize-sweep") {
            var thresholds = [0.35, 0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70]
            if let idx = args.firstIndex(of: "--thresholds"), idx + 1 < args.count {
                thresholds = args[idx + 1].split(separator: ",").compactMap { Double($0) }
            }
            await runDiarizationSweep(audioPath: audioPath, audioDuration: audioDuration, thresholds: thresholds)
            return  // sweep is standalone, skip summary
        }

        // Compute WER if ground truth available
        let audioFilename = audioPath.lastPathComponent
        if let reference = groundTruth[audioFilename] {
            print("\n══════ WER Scoring ══════")
            let label = isCJK(reference) ? "CER" : "WER"
            print("  Reference: \(reference.prefix(80))...")
            for i in results.indices {
                if results[i].error == nil && !results[i].fullText.isEmpty {
                    results[i].wer = computeWER(reference: reference, hypothesis: results[i].fullText)
                    print("  \(results[i].engine): \(label) = \(String(format: "%.1f", results[i].wer! * 100))%")
                }
            }
        } else if !groundTruth.isEmpty {
            print("\n  No ground truth match for \(audioFilename)")
        }

        // Summary
        let hasWER = results.contains { $0.wer != nil }
        log("\n══════ Summary ══════")
        log("\n" + tableRow("Engine", "Time", "Segs", "RTF", hasWER ? "WER" : ""))
        log(String(repeating: "─", count: hasWER ? 85 : 75))
        for r in results {
            if r.error != nil {
                log(tableRow(r.engine, "ERROR", "-", "-", hasWER ? "-" : ""))
            } else {
                let time = "\(Int(r.wallClockSeconds) / 60)m \(Int(r.wallClockSeconds) % 60)s"
                let werStr = r.wer.map { String(format: "%.1f%%", $0 * 100) } ?? "-"
                log(tableRow(r.engine, time, "\(r.segmentCount)", String(format: "%.1fx", r.realtimeFactor), hasWER ? werStr : ""))
            }
        }

        // Save report
        let reportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".audio-transcribe/benchmark")
        try? FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        let reportPath = reportDir.appendingPathComponent("engine-benchmark-\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none).replacingOccurrences(of: "/", with: "-")).txt")
        writeReport(results: results, audioPath: audioPath, outputPath: reportPath)
        print("\nReport saved: \(reportPath.path)")
    }
}
