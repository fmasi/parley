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
/// No Parley model download — but each language's speech model must be INSTALLED on this Mac, and installing one is a
/// download: only `prepare()`, from an explicit user action, ever does it (L review 229).
@available(macOS 26.0, *)
public actor SpeechAnalyzerEngine: TranscriptionEngine {
    public nonisolated let name = "SpeechAnalyzer"
    /// The language to transcribe when a caller passes none — SpeechAnalyzer cannot detect one. nil until #223 gives it a
    /// setting.
    private nonisolated let language: String?
    private nonisolated let inventory: any SpeechAssetInventory

    public init(language: String? = nil, inventory: (any SpeechAssetInventory)? = nil) {
        self.language = language
        self.inventory = inventory ?? SystemSpeechAssetInventory()
    }

    /// Ready only when its language's model is INSTALLED on this Mac (L review 229): a look at the installed locales, never
    /// a download. Without a language it cannot transcribe, so it is never ready.
    public nonisolated func isReady() async -> Bool {
        SpeechAnalyzerLocale.isAmong(language, await inventory.installedLocales())
    }

    /// Why it is not ready, honestly (L review 270): a locale this Mac does not support at all is "not supported" — never
    /// "not installed", which a download would fix.
    public nonisolated func notReadyReason() async -> String {
        guard let language else { return "Apple Speech needs a language, and has no language setting yet (#223)" }
        let localeID = SpeechAnalyzerLocale.resolve(language)
        guard SpeechAnalyzerLocale.isAmong(localeID, await inventory.supportedLocales()) else {
            return "its \(localeID) speech model is not supported on this Mac"
        }
        return "its \(localeID) speech model is not installed on this Mac"
    }

    /// Installs the language's speech model — a NETWORK download: only from an explicit user action (Setup, Settings),
    /// never from a recording or a salvage, which only look (L review 229).
    public func prepare() async throws {
        guard let language else { throw SpeechAnalyzerError.languageRequired }
        let localeID = SpeechAnalyzerLocale.resolve(language)
        guard SpeechAnalyzerLocale.isAmong(localeID, await inventory.supportedLocales()) else {
            throw SpeechAnalyzerError.localeNotSupported(localeID)
        }
        guard !SpeechAnalyzerLocale.isAmong(localeID, await inventory.installedLocales()) else { return }
        Logger.transcription.info("SpeechAnalyzer: installing the \(localeID, privacy: .public) model, as the user asked")
        do {
            try await inventory.install(locale: localeID)
        } catch {
            throw SpeechAnalyzerError.assetInstallFailed(localeID, error.localizedDescription)
        }
    }

    public func transcribe(audioPath: URL, language: String? = nil, audioSource: AudioSourceType = .system) async throws -> [TranscriptSegment] {
        let startTime = ContinuousClock.now

        Logger.transcription.info("Transcribing: \(audioPath.lastPathComponent, privacy: .sensitive) with SpeechAnalyzer")

        // SpeechAnalyzer cannot auto-detect language — it transcribes in whatever locale it's
        // given. Refuse a missing language rather than defaulting to the system locale, which
        // silently transcribed non-English audio as English (e.g. Portuguese → gibberish).
        guard let language = language ?? self.language, !language.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw SpeechAnalyzerError.languageRequired
        }
        let localeID = SpeechAnalyzerLocale.resolve(language)
        let locale = Locale(identifier: localeID)

        // Its on-device model must be INSTALLED, or transcription returns empty/garbage — looked at FIRST (L review 254): an
        // installed model is a supported one, and needs no other look. Only a model that is not installed looks at what this
        // Mac supports, to say which it is (L review 270): "not supported on this Mac", or "not installed". It is NEVER
        // downloaded here (L review 229): a transcription runs in a recording or a salvage, and installing is a network
        // download only an explicit user action may start (`prepare`).
        guard SpeechAnalyzerLocale.isAmong(localeID, await inventory.installedLocales()) else {
            guard SpeechAnalyzerLocale.isAmong(localeID, await inventory.supportedLocales()) else {
                throw SpeechAnalyzerError.localeNotSupported(locale.identifier(.bcp47))
            }
            Logger.transcription.error("SpeechAnalyzer: the \(locale.identifier(.bcp47), privacy: .public) model is not installed — not transcribed, never downloaded")
            throw SpeechAnalyzerError.assetNotInstalled(locale.identifier(.bcp47))
        }

        let transcriber = Self.transcriber(for: locale)
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

        // Deduplication happens in the callers' transcribeStream, where the dropped count is recorded (P2).
        return segments
    }

    static func transcriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            preset: SpeechTranscriber.Preset(
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [.audioTimeRange]
            )
        )
    }
}

/// The system's speech models (L review 229): the installed and supported locales are looks; `install` downloads.
@available(macOS 26.0, *)
struct SystemSpeechAssetInventory: SpeechAssetInventory {
    func installedLocales() async -> [String] { await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) } }
    func supportedLocales() async -> [String] { await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) } }
    func install(locale: String) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [SpeechAnalyzerEngine.transcriber(for: Locale(identifier: locale))]) {
            try await request.downloadAndInstall()
        }
    }
}
#endif // compiler(>=6.2)
