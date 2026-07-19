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

        Logger.transcription.info("Transcribing: \(audioPath.lastPathComponent, privacy: .sensitive) with SpeechAnalyzer")

        // SpeechAnalyzer cannot auto-detect language — it transcribes in whatever locale it's
        // given. Refuse a missing language rather than defaulting to the system locale, which
        // silently transcribed non-English audio as English (e.g. Portuguese → gibberish).
        guard let language, !language.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw SpeechAnalyzerError.languageRequired
        }
        let localeID = SpeechAnalyzerLocale.resolve(language)
        let locale = Locale(identifier: localeID)

        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: SpeechTranscriber.Preset(
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [.audioTimeRange]
            )
        )

        // The locale must be supported AND its on-device model installed, or transcription returns
        // empty/garbage. Check + install, surfacing failures (e.g. the ko-KR download SFSpeechError
        // Code=11) instead of swallowing them.
        func matches(_ a: Locale, _ b: Locale) -> Bool { a.identifier(.bcp47) == b.identifier(.bcp47) }
        guard await SpeechTranscriber.supportedLocales.contains(where: { matches($0, locale) }) else {
            throw SpeechAnalyzerError.localeNotSupported(locale.identifier(.bcp47))
        }
        if !(await SpeechTranscriber.installedLocales).contains(where: { matches($0, locale) }) {
            Logger.transcription.info("SpeechAnalyzer: installing \(locale.identifier(.bcp47), privacy: .public) model...")
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                throw SpeechAnalyzerError.assetInstallFailed(locale.identifier(.bcp47), error.localizedDescription)
            }
        }

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

                // Extract timestamp range + text from AttributedString runs. Whether these runs can
                // safely support boundary-splitting (issue #120) is decided by the pure, independently
                // unit-tested SpeakerAssignment.speechAnalyzerWordTimings — kept out of this actor
                // (macOS 26+/Swift 6.2+ only, compiled out entirely on CI's Swift 6.0 runner) so the
                // decision logic itself stays testable everywhere.
                var segStart: Double = .greatestFiniteMagnitude
                var segEnd: Double = 0
                var runsData: [(text: String, start: Double?, end: Double?)] = []
                for run in result.text.runs {
                    let runText = String(result.text[run.range].characters)
                    if let timeRange = run.audioTimeRange {
                        let s = CMTimeGetSeconds(timeRange.start)
                        let e = CMTimeGetSeconds(timeRange.end)
                        if s < segStart { segStart = s }
                        if e > segEnd { segEnd = e }
                        runsData.append((text: runText, start: s, end: e))
                    } else {
                        runsData.append((text: runText, start: nil, end: nil))
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
                        language: localeID,
                        words: SpeakerAssignment.speechAnalyzerWordTimings(
                            runs: runsData, trimmedSegmentText: trimmed
                        )
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
