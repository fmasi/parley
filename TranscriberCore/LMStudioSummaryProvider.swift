import Foundation
import os

/// Summary provider using LM Studio's native REST API v1 (`/api/v1/chat`).
///
/// Advantages over the OpenAI-compatible endpoint:
/// - `context_length` per request (no need to pre-configure in the GUI)
/// - Token usage stats in the response (`input_tokens`, `total_output_tokens`)
/// - Stateful chats and MCP support (future)
public struct LMStudioSummaryProvider: SummaryProvider, Sendable {
    private let endpoint: String
    private let apiKey: String
    private let model: String
    private let contextLength: Int?
    private let overheadPercent: Int
    private let outputBuffer: Int

    public init(
        endpoint: String,
        apiKey: String,
        model: String,
        contextLength: Int? = nil,
        contextOverheadPercent: Int? = nil,
        maxOutputTokens: Int? = nil
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.contextLength = contextLength
        self.overheadPercent = contextOverheadPercent ?? Self.defaultOverheadPercent
        self.outputBuffer = maxOutputTokens ?? Self.defaultOutputBuffer
    }

    public func summarize(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String {
        // Calibrate on first encounter with this model
        await calibrateIfNeeded()

        // #133: check whether the model is already loaded (and big enough) BEFORE building the
        // request, so we can avoid sending context_length and forcing a reload that OOMs.
        let loadedState = await fetchLoadedState()
        let (request, inputChars, resolvedContextLength) = try await buildRequest(
            segments: segments, metadata: metadata, loadedState: loadedState)
        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""

            // Context too small — parse actual token count from error, set exact ratio, retry once
            if httpResponse.statusCode == 500, let actualTokens = Self.parseContextError(body) {
                Logger.transcription.warning(
                    "Context too small: model needed \(actualTokens) tokens. Setting exact ratio and retrying."
                )
                await TokenRatioCache.shared.setRatio(
                    for: model,
                    inputChars: inputChars,
                    actualInputTokens: actualTokens
                )
                return try await retryRequest(segments: segments, metadata: metadata)
            }

            throw SummaryError.requestFailed("HTTP \(httpResponse.statusCode): \(body.prefix(200))")
        }

        let (content, stats) = try Self.parseResponse(data)

        if let stats {
            Logger.transcription.info(
                "LM Studio summary stats — input: \(stats.inputTokens) tokens, output: \(stats.outputTokens) tokens"
            )
            // Refine token ratio from real usage data
            await TokenRatioCache.shared.refine(
                model: model,
                inputChars: inputChars,
                actualInputTokens: stats.inputTokens
            )
            if Self.isLikelyTruncated(contextLength: resolvedContextLength, inputTokens: stats.inputTokens, outputTokens: stats.outputTokens) {
                Logger.transcription.warning(
                    "Summary may be truncated — output used \(stats.outputTokens)/\(resolvedContextLength - stats.inputTokens) available tokens. Consider increasing context window."
                )
            }
        }

        return content
    }

    /// Single retry with recalibrated context — no further retries to avoid loops.
    private func retryRequest(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String {
        let (request, inputChars, resolvedContextLength) = try await buildRequest(segments: segments, metadata: metadata)
        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SummaryError.requestFailed("HTTP \(httpResponse.statusCode) (after retry): \(body.prefix(200))")
        }

        let (content, stats) = try Self.parseResponse(data)

        if let stats {
            Logger.transcription.info(
                "LM Studio summary stats (retry) — input: \(stats.inputTokens) tokens, output: \(stats.outputTokens) tokens"
            )
            await TokenRatioCache.shared.refine(
                model: model,
                inputChars: inputChars,
                actualInputTokens: stats.inputTokens
            )
            let availableOutput = resolvedContextLength - stats.inputTokens
            if availableOutput > 0 && stats.outputTokens >= availableOutput - 5 {
                Logger.transcription.warning(
                    "Summary may be truncated (retry) — output used \(stats.outputTokens)/\(availableOutput) available tokens."
                )
            }
        }

        return content
    }

    private func calibrateIfNeeded() async {
        let cache = TokenRatioCache.shared
        guard await cache.ratio(for: model) == nil else { return }
        do {
            _ = try await cache.calibrate(model: model, endpoint: endpoint, apiKey: apiKey)
        } catch {
            Logger.transcription.warning("Token calibration failed for \(model), using default ratio: \(error.localizedDescription)")
        }
    }

    // MARK: - Internal (testable)

    struct TokenStats: Sendable {
        let inputTokens: Int
        let outputTokens: Int
    }

    /// Default output buffer: tokens reserved for the summary response.
    /// 500-word summary ≈ 650 tokens + markdown formatting. 2048 is generous.
    static let defaultOutputBuffer = 2048

    /// Default overhead: 10% safety margin on estimated input tokens.
    static let defaultOverheadPercent = 10

    /// Returns (request, totalInputChars, resolvedContextLength).
    ///
    /// `loadedState`: the target model's current load state (from `/api/v0/models`). When the model
    /// is already loaded with enough context, `context_length` is omitted so LM Studio uses the
    /// loaded instance as-is instead of reloading it (#133). `nil` (unknown) keeps the old behavior.
    func buildRequest(
        segments: [SummarySegment],
        metadata: SummaryMetadata,
        loadedState: ModelState? = nil
    ) async throws -> (URLRequest, Int, Int) {
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

        let transcript = OpenAISummaryProvider.formatTranscript(segments, includeSource: metadata.dualStream)
        let userMessage = """
        Meeting: \(metadata.sessionName)
        Date: \(Self.formatDate(metadata.date))
        Duration: \(Self.formatDuration(metadata.durationSeconds))
        Participants: \(metadata.speakers.joined(separator: ", "))

        --- TRANSCRIPT ---
        \(transcript)
        """

        var prompt = OpenAISummaryProvider.systemPrompt
        if metadata.dualStream {
            prompt += OpenAISummaryProvider.dualStreamHint
        }

        // Estimate tokens needed and auto-size context window (uses calibrated ratio if available)
        let cache = TokenRatioCache.shared
        let rawEstimate = await cache.estimateTokens(userMessage, model: model)
            + (await cache.estimateTokens(prompt, model: model))
        let estimatedInputTokens = rawEstimate + (rawEstimate * overheadPercent / 100)
        let neededContext = estimatedInputTokens + outputBuffer
        let maxContext = contextLength ?? 32768

        if neededContext > maxContext {
            Logger.transcription.warning(
                "Transcript may exceed context window: ~\(estimatedInputTokens) input tokens estimated, cap is \(maxContext). Summary may be incomplete."
            )
        }

        var body: [String: Any] = [
            "model": model,
            "input": userMessage,
            "system_prompt": prompt,
            "temperature": 0.3
        ]

        // #133: only send context_length when the model actually needs a (re)load. Sending it when
        // the model is already loaded forces LM Studio to reload — which OOMs on a busy machine.
        let resolvedContext: Int
        switch Self.contextDecision(state: loadedState, neededContext: neededContext, maxContext: maxContext) {
        case .useLoadedAsIs:
            resolvedContext = loadedState?.loadedContextLength ?? maxContext
            Logger.transcription.info(
                "LM Studio: '\(self.model, privacy: .public)' already loaded with \(resolvedContext) context (need ~\(neededContext)) — using as-is, no reload."
            )
        case .request(let ctx):
            resolvedContext = ctx
            body["context_length"] = ctx
            Logger.transcription.info(
                "LM Studio: requesting \(ctx) context_length for '\(self.model, privacy: .public)' (need ~\(neededContext), cap \(maxContext))."
            )
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let totalInputChars = userMessage.count + prompt.count
        return (request, totalInputChars, resolvedContext)
    }

    // MARK: - Model load state (#133)

    /// The target model's current load state in LM Studio, from `/api/v0/models`.
    public struct ModelState: Equatable, Sendable {
        public let isLoaded: Bool
        public let loadedContextLength: Int?
        public init(isLoaded: Bool, loadedContextLength: Int?) {
            self.isLoaded = isLoaded
            self.loadedContextLength = loadedContextLength
        }
    }

    enum ContextDecision: Equatable {
        case useLoadedAsIs               // model already loaded big enough — send no context_length
        case request(contextLength: Int) // needs a (re)load at this context
    }

    /// Use the loaded model as-is only when it is loaded AND its context is at least what we need;
    /// otherwise request a context (capped at max). `nil` state (couldn't check) falls back to
    /// requesting a context — the pre-#133 behavior, so a down models endpoint never blocks a summary.
    static func contextDecision(state: ModelState?, neededContext: Int, maxContext: Int) -> ContextDecision {
        if let state, state.isLoaded, let loaded = state.loadedContextLength, loaded >= neededContext {
            return .useLoadedAsIs
        }
        return .request(contextLength: min(neededContext, maxContext))
    }

    /// Parse `/api/v0/models` for one model's state. Returns nil if the model isn't listed.
    ///
    /// `/api/v0/models` reports `id` and `publisher` separately (e.g. id `gemma-4-26b-a4b-it-mlx`,
    /// publisher `lmstudio-community`), while config.json may store the combined
    /// `lmstudio-community/gemma-4-26b-a4b-it-mlx`. Match on the bare id, the `publisher/id` form,
    /// or the config value's basename — otherwise the provider mistakes a loaded model for unloaded
    /// and forces the reload this whole fix exists to avoid.
    static func parseModelState(_ data: Data, model: String) -> ModelState? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]]
        else { return nil }
        let modelBasename = model.split(separator: "/").last.map(String.init)
        guard let entry = entries.first(where: { entry in
            guard let id = entry["id"] as? String else { return false }
            if id == model { return true }
            if let publisher = entry["publisher"] as? String, "\(publisher)/\(id)" == model { return true }
            return modelBasename == id
        }) else { return nil }
        let isLoaded = (entry["state"] as? String) == "loaded"
        let loadedContext = isLoaded ? (entry["loaded_context_length"] as? Int) : nil
        return ModelState(isLoaded: isLoaded, loadedContextLength: loadedContext)
    }

    /// Query LM Studio for the target model's load state. Any failure (endpoint down, auth, timeout)
    /// returns nil, which `contextDecision` treats as "request a context" — never blocks the summary.
    func fetchLoadedState() async -> ModelState? {
        let baseURL = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard let url = URL(string: baseURL + "/api/v0/models") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
        else { return nil }
        return Self.parseModelState(data, model: model)
    }

    /// Check if output was likely truncated (used all available space).
    /// Returns true if output tokens are within 5 of the available output space.
    static func isLikelyTruncated(contextLength: Int, inputTokens: Int, outputTokens: Int) -> Bool {
        let available = contextLength - inputTokens
        return available > 0 && outputTokens >= available - 5
    }

    /// Parse the actual token count from an LM Studio context overflow error.
    /// Error format: "n_keep: 19985 >= n_ctx: 10240" or similar with "n_keep: NNNN".
    static func parseContextError(_ body: String) -> Int? {
        // Match "n_keep: <number>" — that's the actual input token count
        guard let range = body.range(of: #"n_keep:\s*(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let match = body[range]
        let digits = match.filter(\.isNumber)
        return Int(digits)
    }

    static func parseResponse(_ data: Data) throws -> (String, TokenStats?) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? [[String: Any]]
        else {
            throw SummaryError.emptyResponse
        }

        // Find the first message-type output
        guard let message = output.first(where: { ($0["type"] as? String) == "message" }),
              let content = message["content"] as? String
        else {
            throw SummaryError.emptyResponse
        }

        // Parse optional token stats
        var stats: TokenStats?
        if let statsJSON = json["stats"] as? [String: Any],
           let inputTokens = statsJSON["input_tokens"] as? Int,
           let outputTokens = statsJSON["total_output_tokens"] as? Int {
            stats = TokenStats(inputTokens: inputTokens, outputTokens: outputTokens)
        }

        return (content, stats)
    }

    private static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f.string(from: date)
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
