import Foundation
import os
import AVFoundation

// SpeechAnalyzer/SpeechTranscriber require the macOS 26 SDK (Swift 6.2+).
// CI runs on macos-15 (Swift 6.0) where these types don't exist in headers.
// Remove this guard once GitHub Actions offers a macOS 26 runner.
#if compiler(>=6.2)
import Speech

/// Transcription engine backed by Apple's SpeechAnalyzer (macOS 26+).
/// On-device, Apple-maintained, broad language support, possible code-switching awareness.
/// No model download required — uses system framework.
@available(macOS 26.0, *)
public actor SpeechAnalyzerEngine: TranscriptionEngine {
    public nonisolated let name = "SpeechAnalyzer"

    public init() {}

    public nonisolated func isReady() -> Bool {
        // System framework, always available on macOS 26+
        true
    }

    public func prepare() async throws {
        // No preparation needed — SpeechAnalyzer is a system framework
    }

    public func transcribe(audioPath: URL, language: String? = nil, audioSource: AudioSourceType = .system) async throws -> [TranscriptSegment] {
        let startTime = ContinuousClock.now

        Logger.transcription.info("Transcribing: \(audioPath.lastPathComponent, privacy: .private) with SpeechAnalyzer")

        let locale: Locale
        if let lang = language {
            locale = Locale(identifier: lang)
        } else {
            locale = Locale.autoupdatingCurrent
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: SpeechTranscriber.Preset(
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [.audioTimeRange]
            )
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let audioFile = try AVAudioFile(forReading: audioPath)

        var segments: [TranscriptSegment] = []

        // Start analysis concurrently
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

        // Collect final results from the async stream
        for try await result in transcriber.results {
            if result.isFinal {
                let text = String(result.text.characters)

                // Extract timestamp range from AttributedString runs. Retain each run's own
                // timing + text as a WordTiming so the assignment layer can split a segment that
                // spans a diarization speaker boundary (issue #120) — the same shared mechanism
                // FluidAudio feeds with its token timings.
                var segStart: Double = .greatestFiniteMagnitude
                var segEnd: Double = 0
                var words: [WordTiming] = []
                // If ANY run lacks audioTimeRange, `words` cannot represent the segment's full text —
                // reconstructing split pieces from `words` alone would silently drop that run's text.
                // Track completeness and disable splitting (words: nil) for this segment rather than
                // risk text loss; the full, untouched `text` field below is unaffected either way.
                var allRunsTimed = true
                for run in result.text.runs {
                    if let timeRange = run.audioTimeRange {
                        let s = CMTimeGetSeconds(timeRange.start)
                        let e = CMTimeGetSeconds(timeRange.end)
                        if s < segStart { segStart = s }
                        if e > segEnd { segEnd = e }
                        let runText = String(result.text[run.range].characters)
                        words.append(WordTiming(start: s, end: e, text: runText))
                    } else {
                        allRunsTimed = false
                    }
                }

                // Fall back to 0 if no time range was found
                if segStart == .greatestFiniteMagnitude { segStart = 0 }

                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    segments.append(TranscriptSegment(
                        start: segStart,
                        end: segEnd,
                        text: trimmed,
                        language: language ?? locale.language.languageCode?.identifier,
                        words: (allRunsTimed && !words.isEmpty) ? words : nil
                    ))
                }
            }
        }

        try await analysisTask.value

        let elapsed = ContinuousClock.now - startTime
        let seconds = elapsed.components.seconds

        Logger.transcription.info("SpeechAnalyzer complete: \(segments.count) segments in \(seconds)s")

        return SpeakerAssignment.deduplicate(segments)
    }
}
#endif // compiler(>=6.2)
