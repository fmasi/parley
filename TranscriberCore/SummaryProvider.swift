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

public protocol SummaryProvider: Sendable {
    func summarize(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String
}
