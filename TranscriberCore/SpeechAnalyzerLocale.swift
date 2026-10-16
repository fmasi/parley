import Foundation

/// Locale resolution for the SpeechAnalyzer engine, kept apart from `SpeechAnalyzerEngine` (which is
/// `@available(macOS 26.0, *)`) so it is pure logic, testable without the Speech framework.
///
/// Why this exists: SpeechAnalyzer (unlike FluidAudio/Parakeet) cannot auto-detect the spoken
/// language — it transcribes in whatever locale it's given. The old engine defaulted a `nil`
/// language to `Locale.autoupdatingCurrent` (the user's *system* locale), so it silently
/// transcribed e.g. Portuguese as English. This resolver never guesses from the system: a bare
/// code maps to a sensible default region, and a caller that already knows the exact variant
/// (e.g. "pt-PT" vs "pt-BR") is honored verbatim.
/// Errors the SpeechAnalyzer engine surfaces to the caller (and, via #134, to the user) instead
/// of silently producing wrong-language output.
public enum SpeechAnalyzerError: LocalizedError {
    case languageRequired
    case localeNotSupported(String)
    case assetInstallFailed(String, String)
    /// The locale's model is not installed, and a transcription never downloads it (L review 229): only an explicit user
    /// action installs one.
    case assetNotInstalled(String)

    public var errorDescription: String? {
        switch self {
        case .languageRequired:
            return "SpeechAnalyzer needs a language — it cannot auto-detect one. Set a language, or use the FluidAudio engine (which auto-detects)."
        case .localeNotSupported(let locale):
            return "SpeechAnalyzer does not support the \(locale) locale on this Mac."
        case .assetInstallFailed(let locale, let reason):
            return "SpeechAnalyzer could not install the \(locale) language model: \(reason)"
        case .assetNotInstalled(let locale):
            return "SpeechAnalyzer's \(locale) speech model is not installed on this Mac, and Parley never downloads one while it records or recovers"
        }
    }
}

/// The on-device speech models SpeechAnalyzer transcribes with (L review 229): which locales are installed — a look, never
/// a download — and installing one, a NETWORK download that only an explicit user action may start (Setup, Settings), never
/// a recording or a salvage: the airgap. Injectable, so tests fake it; production's is `SpeechAnalyzerEngine`'s own.
public protocol SpeechAssetInventory: Sendable {
    /// The locales whose model is installed on this Mac, BCP-47.
    func installedLocales() async -> [String]
    /// The locales SpeechAnalyzer supports on this Mac, BCP-47.
    func supportedLocales() async -> [String]
    /// Download and install `locale`'s model. Only from an explicit user action.
    func install(locale: String) async throws
}

public enum SpeechAnalyzerLocale {

    /// Default region per bare language code (used only when the caller passes no region).
    static let defaultRegion: [String: String] = [
        "en": "en-US", "pt": "pt-BR", "es": "es-ES", "fr": "fr-FR", "de": "de-DE",
        "it": "it-IT", "nl": "nl-NL", "ja": "ja-JP", "ko": "ko-KR", "zh": "zh-CN",
        "tr": "tr-TR", "ru": "ru-RU", "ar": "ar-SA", "hi": "hi-IN",
    ]

    /// Resolve a language string to a concrete BCP-47 locale identifier.
    /// - A value that already carries a region ("pt-PT", "pt_BR", "en-US") is normalized and kept.
    /// - A bare code ("pt", "ja") maps to `defaultRegion`, or is used as-is if unknown.
    public static func resolve(_ language: String) -> String {
        let trimmed = language.trimmingCharacters(in: .whitespaces)
        let normalized = trimmed.replacingOccurrences(of: "_", with: "-")
        if normalized.contains("-") {
            // Already qualified — normalize each subtag by BCP-47 position, preserving script AND
            // region (e.g. "zh-Hant-TW" must NOT collapse to "zh-HANT" — that breaks zh-TW/zh-HK).
            let parts = normalized.split(separator: "-").map(String.init)
            let normalizedParts = parts.enumerated().map { index, part -> String in
                if index == 0 { return part.lowercased() }                 // language
                if part.count == 4, part.allSatisfy(\.isLetter) {           // script subtag -> Titlecase
                    return part.prefix(1).uppercased() + part.dropFirst().lowercased()
                }
                return part.uppercased()                                    // region subtag
            }
            return normalizedParts.joined(separator: "-")
        }
        return defaultRegion[normalized.lowercased()] ?? normalized
    }
}

extension SpeechAnalyzerLocale {
    /// Whether `language`'s model is among `locales` (BCP-47), matched as the resolved locale (L review 229). No language is
    /// never ready: SpeechAnalyzer cannot detect one.
    public static func isAmong(_ language: String?, _ locales: [String]) -> Bool {
        guard let language, !language.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let wanted = bcp47(resolve(language))
        return locales.contains { bcp47($0) == wanted }
    }

    static func bcp47(_ identifier: String) -> String { Locale(identifier: identifier).identifier(.bcp47) }
}
