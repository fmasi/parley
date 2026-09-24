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

/// How much of one side of the meeting was captured, read from the transcript's
/// `metadata.capture.remote` / `.local` (§7.1/§7.3). `status` is a `TrackAccounting.Status` raw
/// value ("healthy", "idle", "neverDelivered", "compromised").
public struct CaptureSideNote: Equatable, Sendable {
    /// Empty when the transcript recorded coverage but no status (read as "unknown", fail closed).
    public let status: String
    public let deliveredSeconds: Double
    public let expectedSeconds: Double
    /// Seconds of exact digital zero among those delivered; nil when not recorded.
    public let exactZeroSeconds: Double?
    /// Remote side only: true when the helper confirmed the System Audio Recording permission was
    /// not granted (denied or not determined) and it was never restored
    /// (`capture_provenance.system_permission_denied_confirmed`);
    /// nil when the transcript does not record it. Only `true` is evidence — anything else is "not
    /// confirmed".
    public let permissionDenied: Bool?
    /// Content-compromising capture anomalies recorded on THIS side (`content_anomaly_count`); nil
    /// when not recorded.
    public let anomalyCount: Int?

    public init(status: String, deliveredSeconds: Double, expectedSeconds: Double,
                exactZeroSeconds: Double? = nil, permissionDenied: Bool? = nil, anomalyCount: Int? = nil) {
        self.status = status
        self.deliveredSeconds = deliveredSeconds
        self.expectedSeconds = expectedSeconds
        self.exactZeroSeconds = exactZeroSeconds
        self.permissionDenied = permissionDenied
        self.anomalyCount = anomalyCount
    }
}

public struct SummaryMetadata: Sendable {
    public let sessionName: String
    public let date: Date
    public let durationSeconds: Double
    public let speakers: [String]
    public let dualStream: Bool
    public let echoSegmentsRemoved: Int
    /// Capture coverage per side; nil when the transcript carries none (older, or not recorded).
    public let remoteCapture: CaptureSideNote?
    public let localCapture: CaptureSideNote?
    /// The transcript was written by a build that tracks capture (it has `processing_issues`) but
    /// holds no coverage for either side — so "complete" cannot be claimed.
    public let coverageNotRecorded: Bool
    /// Periods with nothing recorded (relaunch, sleep) from `metadata.capture.gaps`.
    public let gapCount: Int
    public let gapSeconds: Double

    public init(sessionName: String, date: Date, durationSeconds: Double, speakers: [String],
                dualStream: Bool = false, echoSegmentsRemoved: Int = 0,
                remoteCapture: CaptureSideNote? = nil, localCapture: CaptureSideNote? = nil,
                coverageNotRecorded: Bool = false, gapCount: Int = 0, gapSeconds: Double = 0) {
        self.sessionName = sessionName
        self.date = date
        self.durationSeconds = durationSeconds
        self.speakers = speakers
        self.dualStream = dualStream
        self.echoSegmentsRemoved = echoSegmentsRemoved
        self.remoteCapture = remoteCapture
        self.localCapture = localCapture
        self.coverageNotRecorded = coverageNotRecorded
        self.gapCount = gapCount
        self.gapSeconds = gapSeconds
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
