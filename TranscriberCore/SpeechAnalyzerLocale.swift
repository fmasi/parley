import Foundation

/// Locale resolution for the SpeechAnalyzer engine, kept OUTSIDE the `#if compiler(>=6.2)` guard
/// so it is testable on CI (macOS 15) even though `SpeechAnalyzerEngine` itself is macOS-26-only.
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

    public var errorDescription: String? {
        switch self {
        case .languageRequired:
            return "SpeechAnalyzer needs a language — it cannot auto-detect one. Set a language, or use the FluidAudio engine (which auto-detects)."
        case .localeNotSupported(let locale):
            return "SpeechAnalyzer does not support the \(locale) locale on this Mac."
        case .assetInstallFailed(let locale, let reason):
            return "SpeechAnalyzer could not install the \(locale) language model: \(reason)"
        }
    }
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
            // Already region-qualified — normalize the casing to lang-REGION.
            let parts = normalized.split(separator: "-")
            if parts.count >= 2 {
                return "\(parts[0].lowercased())-\(parts[1].uppercased())"
            }
            return normalized
        }
        return defaultRegion[normalized.lowercased()] ?? normalized
    }
}
