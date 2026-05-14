import Foundation
import os

public enum MeetingSummarizer {

    /// Summarize a transcript JSON file and write a `-summary.md` alongside it.
    public static func summarize(
        transcriptPath: URL,
        provider: any SummaryProvider
    ) async throws {
        let (segments, metadata) = try parseTranscript(at: transcriptPath)

        Logger.transcription.info("Generating summary for '\(metadata.sessionName)' (\(segments.count) segments)")

        let markdown = try await provider.summarize(segments: segments, metadata: metadata)

        let baseName = transcriptPath.deletingPathExtension().lastPathComponent
        let summaryPath = transcriptPath.deletingLastPathComponent()
            .appendingPathComponent(baseName + "-summary.md")
        try markdown.write(to: summaryPath, atomically: true, encoding: .utf8)

        Logger.transcription.info("Summary written to \(summaryPath.lastPathComponent)")
    }

    /// Convenience: create provider from config + summarize. Logs errors, never throws.
    public static func summarizeIfConfigured(
        transcriptPath: URL,
        config: Config
    ) async {
        guard let summary = config.summary, summary.enabled, !summary.endpoint.isEmpty else {
            return
        }

        let provider: any SummaryProvider = Self.createProvider(from: summary)

        do {
            try await summarize(transcriptPath: transcriptPath, provider: provider)
        } catch {
            Logger.transcription.error("Summary generation failed: \(error.localizedDescription)")
        }
    }

    /// Create the appropriate provider from config.
    public static func createProvider(from summary: SummaryConfig) -> any SummaryProvider {
        switch summary.provider {
        case .lmstudio:
            return LMStudioSummaryProvider(
                endpoint: summary.endpoint,
                apiKey: summary.apiKey,
                model: summary.model,
                contextLength: summary.contextLength,
                contextOverheadPercent: summary.contextOverheadPercent,
                maxOutputTokens: summary.maxOutputTokens
            )
        case .openai:
            return OpenAISummaryProvider(
                endpoint: summary.endpoint,
                apiKey: summary.apiKey,
                model: summary.model
            )
        }
    }

    // MARK: - Private

    private static func parseTranscript(at path: URL) throws -> ([SummarySegment], SummaryMetadata) {
        let data = try Data(contentsOf: path)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawSegments = json["segments"] as? [[String: Any]]
        else {
            throw SummaryError.emptyResponse
        }

        let metadata_raw = json["metadata"] as? [String: Any]
        let dualStream = metadata_raw?["dual_stream"] as? Bool ?? false
        let echoRemoved = metadata_raw?["echo_segments_removed"] as? Int ?? 0

        let segments = rawSegments.map { seg in
            SummarySegment(
                start: seg["start"] as? Double ?? 0,
                end: seg["end"] as? Double ?? 0,
                speaker: seg["speaker"] as? String ?? "",
                text: seg["text"] as? String ?? "",
                source: seg["source"] as? String ?? ""
            )
        }

        var seen = Set<String>()
        var speakers: [String] = []
        for seg in segments {
            if !seg.speaker.isEmpty && seen.insert(seg.speaker).inserted {
                speakers.append(seg.speaker)
            }
        }

        let duration = segments.last?.end ?? 0
        let sessionName = path.deletingPathExtension().lastPathComponent

        let metadata = SummaryMetadata(
            sessionName: sessionName,
            date: Date(),
            durationSeconds: duration,
            speakers: speakers,
            dualStream: dualStream,
            echoSegmentsRemoved: echoRemoved
        )

        return (segments, metadata)
    }
}
