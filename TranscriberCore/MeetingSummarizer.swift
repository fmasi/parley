import Foundation
import os

/// Result of an attempted auto-summary, so the caller can decide whether to surface a failure
/// to the user instead of it failing silently (#134).
public enum SummaryOutcome: Equatable, Sendable {
    case skipped                 // summary not configured / disabled
    case succeeded
    case failed(String)          // localized description of the failure
}

public enum MeetingSummarizer {

    /// Summarize a transcript JSON file and write a `-summary.md` alongside it.
    public static func summarize(
        transcriptPath: URL,
        provider: any SummaryProvider
    ) async throws {
        let (segments, metadata) = try parseTranscript(at: transcriptPath)

        Logger.transcription.info("Generating summary for '\(metadata.sessionName)' (\(segments.count) segments)")

        let markdown = try await provider.summarize(segments: segments, metadata: metadata)

        // Deterministically stamp the source transcript filename as a footer so
        // the notes can always be traced back to their source — independent of
        // whether the LLM chose to mention it.
        let body = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamped = "\(body)\n\n---\n*Source transcript: `\(transcriptPath.lastPathComponent)`*\n"

        let baseName = transcriptPath.deletingPathExtension().lastPathComponent
        let summaryPath = transcriptPath.deletingLastPathComponent()
            .appendingPathComponent(baseName + "-summary.md")
        try stamped.write(to: summaryPath, atomically: true, encoding: .utf8)

        Logger.transcription.info("Summary written to \(summaryPath.lastPathComponent)")
    }

    /// Convenience: create provider from config + summarize. Never throws; returns a
    /// `SummaryOutcome` so the caller can notify the user on failure rather than the summary
    /// failing silently (#134).
    public static func summarizeIfConfigured(
        transcriptPath: URL,
        config: Config
    ) async -> SummaryOutcome {
        guard let summary = config.summary, summary.enabled, !summary.endpoint.isEmpty else {
            return .skipped
        }
        return await runSummary(transcriptPath: transcriptPath, provider: Self.createProvider(from: summary))
    }

    /// Run a summary with an explicit provider, translating success/failure into a `SummaryOutcome`.
    /// Logs the failure (preserving prior behavior) and reports it upward for user notification.
    static func runSummary(
        transcriptPath: URL,
        provider: any SummaryProvider
    ) async -> SummaryOutcome {
        do {
            try await summarize(transcriptPath: transcriptPath, provider: provider)
            return .succeeded
        } catch SummaryError.invalidEndpoint {
            // The endpoint URL can carry a token in some proxies (e.g. Cloudflare AI Gateway), so its
            // raw value must reach neither the public log nor the user-visible failure message — the
            // latter can surface as a notification during a screen-shared meeting (#134 review).
            Logger.transcription.error("Summary generation failed: invalid summary endpoint")
            return .failed("Invalid summary endpoint — check your provider settings")
        } catch {
            // Public so provider/HTTP failures (e.g. "model failed to load") are diagnosable instead
            // of `<private>` (#134). This forwards the provider's own error text — the server message
            // for `serverError`, the HTTP response body for `requestFailed` — to both the log and the
            // notification. That assumes providers don't echo the bearer token in their error bodies,
            // which holds for the standard providers (OpenAI / LM Studio / Ollama). The one case that
            // embeds the configured endpoint URL (which *can* carry a token) — `invalidEndpoint` — is
            // sanitized in the branch above.
            Logger.transcription.error("Summary generation failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
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
            date: resolveRecordingDate(metadata: metadata_raw, transcriptPath: path),
            durationSeconds: duration,
            speakers: speakers,
            dualStream: dualStream,
            echoSegmentsRemoved: echoRemoved
        )

        return (segments, metadata)
    }

    /// Determine the canonical recording-start date for the summary (#49).
    ///
    /// Priority: the transcript's `recorded_at` metadata (the real meeting start) →
    /// the transcript file's creation/modification date (older transcripts without the
    /// key) → the current time as a last resort. Never `Date()` when better info exists,
    /// so a recording summarized the next day is still dated to when it happened.
    static func resolveRecordingDate(metadata: [String: Any]?, transcriptPath path: URL) -> Date {
        if let raw = metadata?["recorded_at"] as? String,
           let parsed = parseISODate(raw) {
            Logger.transcription.debug("Summary date sourced from transcript metadata 'recorded_at'")
            return parsed
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let fileDate = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date) {
            Logger.transcription.debug("Summary date sourced from transcript file date (no 'recorded_at' in metadata)")
            return fileDate
        }

        Logger.transcription.debug("Summary date fell back to current time (no 'recorded_at' and no file date)")
        return Date()
    }

    /// Parse an ISO8601 timestamp, tolerating both fractional-second and plain forms.
    private static func parseISODate(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: raw) { return d }
        return ISO8601DateFormatter().date(from: raw)
    }
}
