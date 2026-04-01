import Foundation
import AVFoundation

// ── Engine imports ──
import WhisperKit
import SwiftWhisper
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
    let error: String?

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
    converter.convert(to: outputBuffer, error: &error) { _, outStatus in
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

// ── Engine: WhisperKit ──

func benchmarkWhisperKit(audioPath: URL, audioDuration: Double) async -> BenchmarkResult {
    print("  Loading WhisperKit model...")
    let start = ContinuousClock.now

    do {
        let kit = try await WhisperKit(
            model: "large-v3-turbo",
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

        return BenchmarkResult(
            engine: "WhisperKit (CoreML, large-v3-turbo)",
            wallClockSeconds: seconds,
            segmentCount: segments.count,
            sampleSegments: Array(segments.prefix(3)),
            audioDurationSeconds: audioDuration,
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
            error: error.localizedDescription
        )
    }
}

// ── Engine: SwiftWhisper (whisper.cpp) ──

func benchmarkWhisperCpp(audioPath: URL, audioDuration: Double) async -> BenchmarkResult {
    let start = ContinuousClock.now

    do {
        // SwiftWhisper needs a GGML model file
        let modelDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".audio-transcribe/models")
        let ggmlModel = modelDir.appendingPathComponent("ggml-large-v3-turbo.bin")

        if !FileManager.default.fileExists(atPath: ggmlModel.path) {
            return BenchmarkResult(
                engine: "SwiftWhisper (whisper.cpp, large-v3-turbo)",
                wallClockSeconds: 0,
                segmentCount: 0,
                sampleSegments: [],
                audioDurationSeconds: audioDuration,
                error: "GGML model not found at \(ggmlModel.path). Download with: curl -L -o '\(ggmlModel.path)' 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin'"
            )
        }

        print("  Loading whisper.cpp model...")
        let whisper = try Whisper(fromFileURL: ggmlModel)

        print("  Loading audio...")
        let (samples, _) = try loadAudioAsFloats(url: audioPath)

        print("  Transcribing...")
        let segments = try await whisper.transcribe(audioFrames: samples)

        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        let sampleSegs = segments.prefix(3).map { seg in
            (Double(seg.startTime) / 1000.0, Double(seg.endTime) / 1000.0, seg.text)
        }

        return BenchmarkResult(
            engine: "SwiftWhisper (whisper.cpp, large-v3-turbo)",
            wallClockSeconds: seconds,
            segmentCount: segments.count,
            sampleSegments: Array(sampleSegs),
            audioDurationSeconds: audioDuration,
            error: nil
        )
    } catch {
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds)
        return BenchmarkResult(
            engine: "SwiftWhisper (whisper.cpp, large-v3-turbo)",
            wallClockSeconds: seconds,
            segmentCount: 0,
            sampleSegments: [],
            audioDurationSeconds: audioDuration,
            error: error.localizedDescription
        )
    }
}

// ── Engine: FluidAudio ──

func benchmarkFluidAudio(audioPath: URL, audioDuration: Double) async -> BenchmarkResult {
    let start = ContinuousClock.now

    do {
        print("  Downloading/loading FluidAudio model...")
        let _ = try await AsrModels.downloadAndLoad()
        let manager = AsrManager()

        print("  Transcribing...")
        let result = try await manager.transcribe(audioPath, source: .system)

        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        let timings = result.tokenTimings ?? []
        // Group token timings into approximate segments (by sentence boundaries or fixed chunks)
        let sampleSegs = timings.prefix(3).map { t in
            (t.startTime, t.endTime, t.token)
        }

        return BenchmarkResult(
            engine: "FluidAudio (Parakeet, CoreML/ANE)",
            wallClockSeconds: seconds,
            segmentCount: timings.count,
            sampleSegments: Array(sampleSegs),
            audioDurationSeconds: audioDuration,
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
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: "en_US"),
            preset: .transcription
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        print("  Transcribing...")
        let audioFile = try AVAudioFile(forReading: audioPath)
        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        }

        var segmentCount = 0
        var sampleTexts: [(Double, Double, String)] = []

        for try await result in transcriber.results {
            if result.isFinal {
                segmentCount += 1
                let text = String(result.text.characters)
                if sampleTexts.count < 3 {
                    sampleTexts.append((0, 0, text))
                }
            }
        }

        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        return BenchmarkResult(
            engine: "SpeechAnalyzer (macOS 26, on-device)",
            wallClockSeconds: seconds,
            segmentCount: segmentCount,
            sampleSegments: sampleTexts,
            audioDurationSeconds: audioDuration,
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
            error: error.localizedDescription
        )
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
    print("  Sample segments:")
    for (i, seg) in r.sampleSegments.enumerated() {
        let startTs = String(format: "%02d:%02d", Int(seg.start) / 60, Int(seg.start) % 60)
        let endTs = String(format: "%02d:%02d", Int(seg.end) / 60, Int(seg.end) % 60)
        print("    [\(startTs)-\(endTs)] \(seg.text.prefix(80))")
    }
}

func writeReport(results: [BenchmarkResult], audioPath: URL, outputPath: URL) {
    var lines: [String] = []
    lines.append("ASR Engine Benchmark Report")
    lines.append("==========================")
    lines.append("Date: \(Date())")
    lines.append("Audio: \(audioPath.lastPathComponent)")
    lines.append("Duration: \(String(format: "%.0f", results.first?.audioDurationSeconds ?? 0))s")
    lines.append("")

    // Summary table
    lines.append(String(format: "%-45s %10s %8s %8s", "Engine", "Time", "Segs", "RTF"))
    lines.append(String(repeating: "─", count: 75))
    for r in results {
        if r.error != nil {
            lines.append(String(format: "%-45s %10s", r.engine, "ERROR"))
        } else {
            let time = "\(Int(r.wallClockSeconds) / 60)m \(Int(r.wallClockSeconds) % 60)s"
            lines.append(String(format: "%-45s %10s %8d %7.1fx", r.engine, time, r.segmentCount, r.realtimeFactor))
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
            lines.append("Sample output:")
            for seg in r.sampleSegments {
                lines.append("  [\(String(format: "%.1f", seg.start))-\(String(format: "%.1f", seg.end))] \(seg.text)")
            }
        }
        lines.append("")
    }

    try? lines.joined(separator: "\n").write(to: outputPath, atomically: true, encoding: .utf8)
}

// ── Main ──

@main
struct EngineBenchmarkCLI {
    static func main() async {
        let args = CommandLine.arguments

        guard args.count >= 2 else {
            print("Usage: EngineBenchmark <audio.wav> [--engines whisperkit,whisper-cpp,fluid,speech]")
            print("")
            print("Engines:")
            print("  whisperkit   — WhisperKit (CoreML, large-v3-turbo)")
            print("  whisper-cpp  — SwiftWhisper / whisper.cpp (Metal GPU)")
            print("  fluid        — FluidAudio (Parakeet, CoreML/ANE)")
            print("  speech       — macOS 26 SpeechAnalyzer (on-device)")
            print("  all          — run all engines (default)")
            Foundation.exit(1)
        }

        let audioPath = URL(fileURLWithPath: args[1])
        guard FileManager.default.fileExists(atPath: audioPath.path) else {
            print("ERROR: Audio file not found: \(audioPath.path)")
            Foundation.exit(1)
        }

        // Parse --engines flag
        var engines = Set(["whisperkit", "whisper-cpp", "fluid", "speech"])
        if let idx = args.firstIndex(of: "--engines"), idx + 1 < args.count {
            engines = Set(args[idx + 1].split(separator: ",").map(String.init))
        }

        let audioDuration = getAudioDuration(url: audioPath)

        print("╔═══════════════════════════════════════════╗")
        print("║  ASR Engine Benchmark                     ║")
        print("╚═══════════════════════════════════════════╝")
        print("")
        print("Audio: \(audioPath.lastPathComponent)")
        print("Duration: \(Int(audioDuration) / 60)m \(Int(audioDuration) % 60)s")
        print("Engines: \(engines.sorted().joined(separator: ", "))")

        // ── Preparation: download models and warm up before timing ──
        print("\n══════ Preparing models (not timed) ══════")

        if engines.contains("whisperkit") {
            print("\n  WhisperKit: downloading/compiling model if needed...")
            do {
                let _ = try await WhisperKit(model: "large-v3-turbo", verbose: false, prewarm: true)
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
                print("\n  SwiftWhisper: GGML model found")
            } else {
                print("\n  SwiftWhisper: GGML model NOT found. Downloading (~1.6GB)...")
                let downloadURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
                let result = await Task.detached {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                    proc.arguments = ["-L", "-o", ggmlModel.path, "--progress-bar", downloadURL]
                    try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
                    try? proc.run()
                    proc.waitUntilExit()
                    return proc.terminationStatus
                }.value
                if result == 0 {
                    print("  SwiftWhisper: download complete")
                } else {
                    print("  SwiftWhisper: download failed — will skip benchmark")
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

        // Summary
        print("\n══════ Summary ══════")
        print(String(format: "\n%-45s %10s %8s %8s", "Engine", "Time", "Segs", "RTF"))
        print(String(repeating: "─", count: 75))
        for r in results {
            if r.error != nil {
                print(String(format: "%-45s %10s", r.engine, "ERROR"))
            } else {
                let time = "\(Int(r.wallClockSeconds) / 60)m \(Int(r.wallClockSeconds) % 60)s"
                print(String(format: "%-45s %10s %8d %7.1fx", r.engine, time, r.segmentCount, r.realtimeFactor))
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
