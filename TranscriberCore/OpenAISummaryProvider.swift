import Foundation
import os

public enum SummaryError: LocalizedError {
    case invalidEndpoint(String)
    case requestFailed(String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let url): return "Invalid summary endpoint: \(url)"
        case .requestFailed(let msg): return "Summary request failed: \(msg)"
        case .emptyResponse: return "Summary response contained no content"
        }
    }
}

public struct OpenAISummaryProvider: SummaryProvider, Sendable {
    private let endpoint: String
    private let apiKey: String
    private let model: String

    public init(endpoint: String, apiKey: String, model: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
    }

    public func summarize(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String {
        let request = try buildRequest(segments: segments, metadata: metadata)
        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SummaryError.requestFailed("HTTP \(httpResponse.statusCode): \(body.prefix(200))")
        }

        return try Self.parseResponse(data)
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
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let transcript = Self.formatTranscript(segments, includeSource: metadata.dualStream)
        let userContent = """
        Meeting: \(metadata.sessionName)
        Date: \(Self.formatDate(metadata.date))
        Duration: \(Self.formatDuration(metadata.durationSeconds))
        Participants: \(metadata.speakers.joined(separator: ", "))

        --- TRANSCRIPT ---
        \(transcript)
        """

        var prompt = Self.systemPrompt
        if metadata.dualStream {
            prompt += Self.dualStreamHint
        }

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

    static func formatTranscript(_ segments: [SummarySegment], includeSource: Bool = false) -> String {
        segments.map { seg in
            let h = Int(seg.start) / 3600
            let m = (Int(seg.start) % 3600) / 60
            let s = Int(seg.start) % 60
            let ts = String(format: "[%02d:%02d:%02d]", h, m, s)
            let sourceTag = includeSource && !seg.source.isEmpty ? " (\(seg.source))" : ""
            return "\(ts) \(seg.speaker)\(sourceTag): \(seg.text)"
        }.joined(separator: "\n")
    }

    static func parseResponse(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw SummaryError.emptyResponse
        }
        return content
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

    static let systemPrompt = """
    You are an expert executive assistant producing concise, skimmable meeting notes.
    Analyze the transcript and produce a structured summary in Markdown.

    ## Required Sections (in this exact order)

    ### Summary
    Open with a metadata line listing the participants and, if available, the \
    duration. Follow with a 2-3 sentence TL;DR capturing the meeting's purpose \
    and outcome.

    ### Decisions
    List only explicit decisions that were actually reached — not intentions, \
    opinions, or topics still under discussion. Write each on its own line as \
    "**Decision:** <what was decided>", noting who endorsed it and a brief why. \
    Omit this section entirely if no explicit decisions were made.

    ### Action Items
    A checklist. Each item MUST follow this shape:
    "- [ ] **<Owner>** to <verb + specific deliverable> — by <deadline>"
    Include the "— by <deadline>" clause only when a deadline was actually \
    stated; otherwise end the item after the deliverable. Omit this section \
    entirely if there are no action items.

    ### Discussion
    Group the substantive discussion by theme (not chronologically). Write 1-3 \
    sentences per topic, attributing viewpoints to speakers where relevant.

    ### Open Questions
    Unresolved topics, concerns, or questions that need follow-up. Omit if none.

    ## Rules
    - Use speaker names exactly as they appear in the transcript
    - Do not invent information not present in the transcript
    - Lead with what's actionable: decisions and action items come before discussion
    - Do not include small talk, greetings, or off-topic banter
    - Keep the total summary under 500 words
    - Use professional, concise language
    """

    static let dualStreamHint = """

    ## Dual-Stream Audio Context
    This transcript was recorded with separate microphone (local) and system audio \
    (remote) streams. Segments are labeled accordingly.

    Some local segments may contain a mix of genuine speech and mic bleed — the \
    microphone picking up what a remote speaker said through the computer speakers. \
    Use concurrent remote segments as a reference: if part of a local segment \
    repeats what a remote speaker said at roughly the same time, that part is echo. \
    Extract only the genuinely new content from that local segment (questions, \
    comments, reactions, unique information) and attribute it to the local speaker. \
    Discard the echoed portion, not the entire segment.
    """
}
