import Testing
import Foundation
@testable import TranscriberCore

struct TokenRatioCacheTests {

    private func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("token-ratio-test-\(UUID().uuidString).json")
    }

    @Test func returnsNilForUnknownModel() {
        let cache = TokenRatioCache(cacheURL: tempCacheURL())
        #expect(cache.ratio(for: "some-model") == nil)
    }

    @Test func estimateTokensUsesDefaultWhenNotCalibrated() {
        let cache = TokenRatioCache(cacheURL: tempCacheURL())
        // 300 chars / 3.0 default = 100 tokens
        let text = String(repeating: "a", count: 300)
        #expect(cache.estimateTokens(text, model: "unknown") == 100)
    }

    @Test func estimateTokensUsesCalibratedRatio() {
        let url = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Seed with a measured entry
        let entries: [String: TokenRatioCache.Entry] = [
            "gemma-4": .init(ratio: 3.06, isSeed: false)
        ]
        try! JSONEncoder().encode(entries).write(to: url, options: .atomic)

        let cache = TokenRatioCache(cacheURL: url)
        // 612 chars / 3.06 = 200 tokens
        let text = String(repeating: "x", count: 612)
        #expect(cache.estimateTokens(text, model: "gemma-4") == 200)
    }

    @Test func probeTextHasCorrectLength() {
        #expect(TokenRatioCache.probeText.count == TokenRatioCache.probeChars)
    }

    @Test func handlesEmptyText() {
        let cache = TokenRatioCache(cacheURL: tempCacheURL())
        #expect(cache.estimateTokens("", model: "any") == 1)
    }

    @Test func handlesMissingCacheFile() {
        let cache = TokenRatioCache(cacheURL: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID()).json"))
        #expect(cache.ratio(for: "model") == nil)
        #expect(cache.estimateTokens("hello world", model: "model") > 0)
    }

    // MARK: - Seed vs measured

    @Test func firstRealMeasurementReplacesSeed() {
        let url = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Start with a seed
        let entries: [String: TokenRatioCache.Entry] = [
            "model-a": .init(ratio: 2.0, isSeed: true)
        ]
        try! JSONEncoder().encode(entries).write(to: url, options: .atomic)

        let cache = TokenRatioCache(cacheURL: url)
        #expect(cache.isSeed(for: "model-a") == true)

        // Refine with a real transcript (3000 chars, 1000 tokens = 3.0 ratio)
        cache.refine(model: "model-a", inputChars: 3000, actualInputTokens: 1000)

        // Should replace seed entirely, not blend
        #expect(cache.ratio(for: "model-a") == 3.0)
        #expect(cache.isSeed(for: "model-a") == false)
    }

    @Test func subsequentMeasurementsBlendViaEMA() {
        let url = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Start with a real measurement
        let entries: [String: TokenRatioCache.Entry] = [
            "model-a": .init(ratio: 3.0, isSeed: false)
        ]
        try! JSONEncoder().encode(entries).write(to: url, options: .atomic)

        let cache = TokenRatioCache(cacheURL: url)

        // Refine with another real measurement: 4000 chars / 1000 tokens = 4.0
        cache.refine(model: "model-a", inputChars: 4000, actualInputTokens: 1000)

        // EMA: 0.3 * 4.0 + 0.7 * 3.0 = 3.3
        let ratio = cache.ratio(for: "model-a")!
        #expect(abs(ratio - 3.3) < 0.01)
    }

    @Test func refineIgnoresSmallRequests() {
        let url = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let entries: [String: TokenRatioCache.Entry] = [
            "model": .init(ratio: 3.0, isSeed: false)
        ]
        try! JSONEncoder().encode(entries).write(to: url, options: .atomic)

        let cache = TokenRatioCache(cacheURL: url)

        // Too small (500 chars < 2000 minimum) — should be ignored
        cache.refine(model: "model", inputChars: 500, actualInputTokens: 100)
        #expect(cache.ratio(for: "model") == 3.0)
    }

    @Test func setRatioForcesExactValue() {
        let url = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let entries: [String: TokenRatioCache.Entry] = [
            "model": .init(ratio: 5.0, isSeed: true)
        ]
        try! JSONEncoder().encode(entries).write(to: url, options: .atomic)

        let cache = TokenRatioCache(cacheURL: url)
        // Force from error: 60000 chars / 20000 tokens = 3.0
        cache.setRatio(for: "model", inputChars: 60000, actualInputTokens: 20000)

        #expect(cache.ratio(for: "model") == 3.0)
        #expect(cache.isSeed(for: "model") == false)
    }

    @Test func migratesLegacyFormat() {
        let url = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Old format: plain [String: Double]
        let legacy = ["old-model": 2.5]
        try! JSONEncoder().encode(legacy).write(to: url, options: .atomic)

        let cache = TokenRatioCache(cacheURL: url)
        #expect(cache.ratio(for: "old-model") == 2.5)
        #expect(cache.isSeed(for: "old-model") == true) // legacy treated as seed
    }
}
