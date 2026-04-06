import Foundation
import os

/// Caches measured chars-per-token ratios per model, persisted at `~/.audio-transcribe/token-ratios.json`.
///
/// Ratios are either "seed" (from a small calibration probe, rough) or "measured" (from real
/// transcripts, accurate). Real measurements always replace seeds. Subsequent real measurements
/// refine via EMA blending. Only transcripts above `minCharsForMeasurement` count as real data.
public final class TokenRatioCache: Sendable {

    public static let shared = TokenRatioCache()

    private let cacheURL: URL

    /// Default ratio (chars/3) used when no data is available at all.
    static let defaultRatio: Double = 3.0

    /// Minimum input chars for a request to count as a real measurement.
    /// Below this, template overhead dominates and the ratio is unreliable.
    static let minCharsForMeasurement = 2000

    /// Calibration probe: transcript-style text with timestamps and speaker labels.
    /// Mimics real input to get a representative chars/token ratio.
    /// 309 chars — large enough that template overhead (~12 tokens) is <15% of total.
    static let probeText = """
    [00:00:00] Alice: Good morning everyone, let's get started with the weekly standup.
    [00:00:15] Bob: Sure. I finished the authentication module yesterday and started on the API tests.
    [00:00:32] Alice: Great progress. Any blockers we should discuss before moving on to the next topic?
    """
    static let probeChars = 283

    init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL ?? {
            let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".audio-transcribe")
            return dir.appendingPathComponent("token-ratios.json")
        }()
    }

    // MARK: - Cache entry

    struct Entry: Codable {
        var ratio: Double
        var isSeed: Bool  // true = from probe, false = from real transcript
    }

    /// Get the chars-per-token ratio for a model. Returns cached value or nil.
    public func ratio(for model: String) -> Double? {
        loadEntries()[model]?.ratio
    }

    /// Whether the cached ratio is a seed (probe) or a real measurement.
    func isSeed(for model: String) -> Bool {
        loadEntries()[model]?.isSeed ?? true
    }

    // MARK: - Calibration (probe)

    /// Calibrate a model by sending a small probe request to the LM Studio REST API.
    /// Stores the result as a "seed" ratio — will be replaced by the first real transcript measurement.
    public func calibrate(model: String, endpoint: String, apiKey: String) async throws -> Double {
        let baseURL = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard let url = URL(string: baseURL + "/api/v1/chat") else {
            throw SummaryError.invalidEndpoint(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": model,
            "input": Self.probeText,
            "system_prompt": "Reply with OK.",
            "temperature": 0,
            "context_length": 512
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw SummaryError.requestFailed("Calibration failed: HTTP \(httpResponse.statusCode): \(responseBody.prefix(200))")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stats = json["stats"] as? [String: Any],
              let inputTokens = stats["input_tokens"] as? Int,
              inputTokens > 0
        else {
            Logger.transcription.warning("Calibration response missing token stats for \(model), using default ratio")
            return Self.defaultRatio
        }

        let contentChars = Self.probeChars + 14 // probe + "Reply with OK." system prompt
        let measuredRatio = Double(contentChars) / Double(inputTokens)

        let ratio = (1.5...6.0).contains(measuredRatio) ? measuredRatio : Self.defaultRatio

        var entries = loadEntries()
        entries[model] = Entry(ratio: ratio, isSeed: true)
        saveEntries(entries)

        Logger.transcription.info("Seed token ratio for \(model): \(String(format: "%.2f", ratio)) chars/token (from probe)")
        return ratio
    }

    // MARK: - Refinement (real transcripts)

    /// Update the ratio from a real transcript's actual token count.
    /// - First real measurement replaces the seed entirely.
    /// - Subsequent real measurements blend via EMA (0.3 new + 0.7 existing).
    /// - Requests below `minCharsForMeasurement` are ignored.
    public func refine(model: String, inputChars: Int, actualInputTokens: Int) {
        guard inputChars >= Self.minCharsForMeasurement, actualInputTokens > 10 else { return }
        let measured = Double(inputChars) / Double(actualInputTokens)
        guard (1.5...6.0).contains(measured) else { return }

        var entries = loadEntries()
        let existing = entries[model]

        let refined: Double
        if let existing, !existing.isSeed {
            // Blend with previous real measurements
            refined = 0.3 * measured + 0.7 * existing.ratio
        } else {
            // First real measurement — replaces seed or creates new entry
            refined = measured
        }

        entries[model] = Entry(ratio: refined, isSeed: false)
        saveEntries(entries)

        Logger.transcription.info(
            "Refined token ratio for \(model): \(String(format: "%.2f", refined)) chars/token (measured \(String(format: "%.2f", measured)), was \(existing.map { String(format: "%.2f", $0.ratio) + ($0.isSeed ? " seed" : "") } ?? "none"))"
        )
    }

    /// Force-set the ratio from a known-accurate measurement (e.g. from a context overflow error).
    /// Always marks as a real measurement, bypasses EMA blending.
    public func setRatio(for model: String, inputChars: Int, actualInputTokens: Int) {
        guard inputChars > 0, actualInputTokens > 0 else { return }
        let measured = Double(inputChars) / Double(actualInputTokens)
        guard (1.5...6.0).contains(measured) else { return }

        var entries = loadEntries()
        entries[model] = Entry(ratio: measured, isSeed: false)
        saveEntries(entries)

        Logger.transcription.info(
            "Set token ratio for \(model): \(String(format: "%.2f", measured)) chars/token (from \(actualInputTokens) actual tokens)"
        )
    }

    /// Estimate token count using cached ratio for model, or default.
    public func estimateTokens(_ text: String, model: String) -> Int {
        let r = ratio(for: model) ?? Self.defaultRatio
        return max(Int(ceil(Double(text.count) / r)), 1)
    }

    // MARK: - Persistence

    private func loadEntries() -> [String: Entry] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [:] }

        // Try new format first (with isSeed)
        if let entries = try? JSONDecoder().decode([String: Entry].self, from: data) {
            return entries
        }

        // Migrate from old format (plain [String: Double]) — treat as seeds
        if let legacy = try? JSONDecoder().decode([String: Double].self, from: data) {
            let entries = legacy.mapValues { Entry(ratio: $0, isSeed: true) }
            saveEntries(entries) // migrate in place
            return entries
        }

        return [:]
    }

    private func saveEntries(_ entries: [String: Entry]) {
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
