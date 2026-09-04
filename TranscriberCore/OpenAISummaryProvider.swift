import Foundation
import os

public enum SummaryError: LocalizedError {
    case invalidEndpoint(String)
    case requestFailed(String)
    case emptyResponse
    /// The provider returned a structured error payload (e.g. `{"error": {...}}`) rather than
    /// a completion. Surfacing the server's own message is what keeps a misconfigured endpoint
    /// (bad token, unknown model) diagnosable instead of masked as `emptyResponse` (#134).
    case serverError(message: String, code: String?)
    /// The endpoint rejected our credentials (401/403).
    ///
    /// Separate from `requestFailed` for two reasons. It is the one failure with a precise, useful
    /// instruction — "check the API key" — and a generic "HTTP 401: <body>" buries that in noise.
    /// And it must NOT echo the response body: some servers reflect the offending credential back,
    /// and this text reaches a notification that may be on screen during a shared meeting. The same
    /// concern already sanitizes `invalidEndpoint`.
    case authenticationFailed(status: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let url): return "Invalid summary endpoint: \(url)"
        case .requestFailed(let msg): return "Summary request failed: \(msg)"
        case .emptyResponse: return "Summary response contained no content"
        case .serverError(let message, let code):
            let suffix = code.map { " (\($0))" } ?? ""
            return "Summary provider error: \(message)\(suffix)"
        case .authenticationFailed(let status):
            return "The summary endpoint rejected the API key (HTTP \(status)) — check it in Settings"
        }
    }

    /// Build a `.serverError` from a decoded response body if it carries a provider error payload.
    /// Handles the OpenAI/`{"error": {"message":..,"code":..}}` shape and a bare `{"error":"msg"}`
    /// string; the `code` may be a string or an integer. Returns nil when there's no error object,
    /// so callers fall through to normal completion parsing. Shared by both summary providers (#134).
    static func from(errorPayload json: [String: Any]) -> SummaryError? {
        guard let error = json["error"] else { return nil }
        if let dict = error as? [String: Any] {
            let message = (dict["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let code = (dict["code"] as? String) ?? (dict["code"] as? Int).map(String.init)
            // Only a payload that actually carries a message or code is a real error — otherwise
            // fall through so a benign/empty `error` on a success body isn't misread as a failure.
            guard message != nil || code != nil else { return nil }
            return .serverError(message: message ?? "Unknown provider error", code: code)
        }
        if let message = error as? String, !message.isEmpty {
            return .serverError(message: message, code: nil)
        }
        return nil
    }
}

public struct OpenAISummaryProvider: SummaryProvider, Sendable {
    private let endpoint: String
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let retryBaseDelay: Double

    /// Maximum number of retries on a rate-limit / transient response (HTTP 429 / 503).
    static let maxRetries = 3
    /// Upper bound on any single backoff sleep, in seconds — caps both exponential
    /// backoff and an over-large `Retry-After`.
    static let maxBackoffSeconds: Double = 30

    public init(endpoint: String, apiKey: String, model: String, requestTimeoutSeconds: Int? = nil) {
        self.init(endpoint: endpoint, apiKey: apiKey, model: model, session: .shared,
                  requestTimeoutSeconds: requestTimeoutSeconds)
    }

    /// See `LMStudioSummaryProvider.defaultRequestTimeoutSeconds` — same reasoning.
    public static let defaultRequestTimeoutSeconds = 600

    /// Testable initializer: inject a `URLSession` (e.g. with a mock `URLProtocol`) and a
    /// shorter retry base delay so the 429 backoff path runs fast under test.
    init(endpoint: String, apiKey: String, model: String, session: URLSession,
         retryBaseDelay: Double = 1.0, requestTimeoutSeconds: Int? = nil) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.retryBaseDelay = retryBaseDelay
        self.requestTimeoutSeconds = requestTimeoutSeconds ?? Self.defaultRequestTimeoutSeconds
    }

    private let requestTimeoutSeconds: Int

    public func summarize(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String {
        let request = try buildRequest(segments: segments, metadata: metadata)

        var attempt = 0
        while true {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return try Self.parseResponse(data)
            }

            if (200...299).contains(httpResponse.statusCode) {
                return try Self.parseResponse(data)
            }

            // Bounded retry with backoff on rate-limit (429) and transient overload (503).
            if Self.isRetryable(httpResponse.statusCode), attempt < Self.maxRetries {
                let delay = retryDelay(attempt: attempt, response: httpResponse)
                Logger.transcription.warning(
                    "OpenAI summary HTTP \(httpResponse.statusCode), retrying in \(delay)s (attempt \(attempt + 1)/\(Self.maxRetries))"
                )
                try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                attempt += 1
                continue
            }

            // 401/403 has a precise fix and a body that may echo the credential back — classify it
            // and throw BEFORE the body is decoded at all. There was no leak either way (the old
            // ordering decoded it and then discarded it on this path), but decoding a
            // credential-bearing body above the guard that stops it escaping reads like a bug
            // waiting to be introduced by the next edit.
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw SummaryError.authenticationFailed(status: httpResponse.statusCode)
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SummaryError.requestFailed("HTTP \(httpResponse.statusCode): \(body.prefix(200))")
        }
    }

    // MARK: - Retry policy (testable)

    static func isRetryable(_ statusCode: Int) -> Bool {
        statusCode == 429 || statusCode == 503
    }

    /// Backoff for the given attempt (0-based). Honors a `Retry-After` header when present,
    /// otherwise exponential backoff (retryBaseDelay * 2^attempt), both capped.
    func retryDelay(attempt: Int, response: HTTPURLResponse) -> Double {
        if let header = response.value(forHTTPHeaderField: "Retry-After"),
           let parsed = Self.parseRetryAfter(header) {
            return min(parsed, Self.maxBackoffSeconds)
        }
        let exponential = retryBaseDelay * pow(2.0, Double(attempt))
        return min(exponential, Self.maxBackoffSeconds)
    }

    /// Parse a `Retry-After` value: either delay-seconds (e.g. "5") or an HTTP-date.
    /// Returns the number of seconds to wait, or nil if unparseable.
    static func parseRetryAfter(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let seconds = Double(trimmed) {
            return seconds >= 0 ? seconds : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: trimmed) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }

    // MARK: - Internal (testable via @testable import)

    func buildRequest(segments: [SummarySegment], metadata: SummaryMetadata) throws -> URLRequest {
        guard let url = URL(string: endpoint.hasSuffix("/")
            ? endpoint + "chat/completions"
            : endpoint + "/chat/completions")
        else {
            throw SummaryError.invalidEndpoint(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // A local model accepts instantly and then generates for minutes; the stock 60s timeout is
        // the wrong order of magnitude and cost two real summaries (#173).
        request.timeoutInterval = TimeInterval(requestTimeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let userContent = SummaryPromptBuilder.userMessage(metadata: metadata, segments: segments)
        let prompt = SummaryPromptBuilder.systemMessage(dualStream: metadata.dualStream)

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": userContent]
            ],
            "temperature": 0.3
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parseResponse(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SummaryError.emptyResponse
        }
        // A structured error body (HTTP 200 or otherwise) carries the real cause — surface it
        // rather than masking it as `emptyResponse` (#134).
        if let serverError = SummaryError.from(errorPayload: json) {
            throw serverError
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw SummaryError.emptyResponse
        }
        return content
    }
}
