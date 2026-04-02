import Foundation

public struct DiarizedSegment: Sendable {
    public let start: Double
    public let end: Double
    public let speaker: String
    public let qualityScore: Float?

    public init(start: Double, end: Double, speaker: String, qualityScore: Float? = nil) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.qualityScore = qualityScore
    }
}

public protocol DiarizationProvider: Sendable {
    func diarize(audioPath: URL, numSpeakers: Int?) async throws -> [DiarizedSegment]
}
