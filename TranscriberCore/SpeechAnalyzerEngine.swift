import Foundation
import os
import AVFoundation
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

    public func transcribe(audioPath: URL, language: String? = nil) async throws -> [TranscriptSegment] {
        let startTime = ContinuousClock.now

        Logger.transcription.info("Transcribing: \(audioPath.lastPathComponent, privacy: .public) with SpeechAnalyzer")

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
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            }
        }

        // Collect final results from the async stream
        for try await result in transcriber.results {
            if result.isFinal {
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

                // Fall back to 0 if no time range was found
                if segStart == .greatestFiniteMagnitude { segStart = 0 }

                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    segments.append(TranscriptSegment(
                        start: segStart,
                        end: segEnd,
                        text: trimmed,
                        language: language ?? locale.language.languageCode?.identifier
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
