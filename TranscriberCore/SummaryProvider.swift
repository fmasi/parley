import Foundation

public struct SummarySegment: Sendable {
    public let start: Double
    public let end: Double
    public let speaker: String
    public let text: String
    public let source: String  // "local" or "remote"

    public init(start: Double, end: Double, speaker: String, text: String, source: String = "") {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
        self.source = source
    }
}

public struct SummaryMetadata: Sendable {
    public let sessionName: String
    public let date: Date
    public let durationSeconds: Double
    public let speakers: [String]
    public let dualStream: Bool
    public let echoSegmentsRemoved: Int

    public init(sessionName: String, date: Date, durationSeconds: Double, speakers: [String],
                dualStream: Bool = false, echoSegmentsRemoved: Int = 0) {
        self.sessionName = sessionName
        self.date = date
        self.durationSeconds = durationSeconds
        self.speakers = speakers
        self.dualStream = dualStream
        self.echoSegmentsRemoved = echoSegmentsRemoved
    }
}

/// A summary plus whether the model stopped because it hit its output limit (P14).
public struct SummaryResponse: Equatable, Sendable {
    public let markdown: String
    /// The model ran out of output tokens: the summary may end mid-thought or miss later sections.
    public let truncated: Bool

    public init(markdown: String, truncated: Bool) {
        self.markdown = markdown
        self.truncated = truncated
    }
}

public protocol SummaryProvider: Sendable {
    func summarize(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String
    /// `summarize`, plus whether the output was truncated. Providers that can tell override it; the
    /// default says "not truncated", which is all a provider without that signal can say.
    func summarizeDetailed(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> SummaryResponse
}

extension SummaryProvider {
    public func summarizeDetailed(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> SummaryResponse {
        SummaryResponse(markdown: try await summarize(segments: segments, metadata: metadata), truncated: false)
    }
}
