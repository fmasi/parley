import Testing
@testable import TranscriberCore

/// SpeechAnalyzer must never silently fall back to the system locale (that transcribed Portuguese
/// as English). A bare code maps to a default region; an explicit variant is honored.
struct SpeechAnalyzerLocaleTests {

    @Test func bareCodeMapsToDefaultRegion() {
        #expect(SpeechAnalyzerLocale.resolve("pt") == "pt-BR")
        #expect(SpeechAnalyzerLocale.resolve("en") == "en-US")
        #expect(SpeechAnalyzerLocale.resolve("ja") == "ja-JP")
        #expect(SpeechAnalyzerLocale.resolve("ko") == "ko-KR")
        #expect(SpeechAnalyzerLocale.resolve("zh") == "zh-CN")
    }

    @Test func explicitVariantIsHonored() {
        // The user's own case: pt-PT (remote) must NOT be coerced to pt-BR.
        #expect(SpeechAnalyzerLocale.resolve("pt-PT") == "pt-PT")
        #expect(SpeechAnalyzerLocale.resolve("es-419") == "es-419")
    }

    @Test func underscoreAndCasingNormalized() {
        #expect(SpeechAnalyzerLocale.resolve("pt_BR") == "pt-BR")
        #expect(SpeechAnalyzerLocale.resolve("EN-us") == "en-US")
    }

    @Test func unknownCodePassesThrough() {
        #expect(SpeechAnalyzerLocale.resolve("xx") == "xx")
    }
}
