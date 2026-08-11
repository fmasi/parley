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
    /// `endpoint` is the configured summary endpoint, used only to stamp the transcript's
    /// disclosure block (#138) — its host is recorded, never the full URL or any token.
    public static func summarize(
        transcriptPath: URL,
        provider: any SummaryProvider,
        endpoint: String
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

        // #138: the content was sent to `endpoint` to produce this summary — update the
        // transcript's disclosure from its airgapped default so the artifact testifies to it.
        try Self.stampDisclosure(.generated(endpoint: endpoint), into: transcriptPath)

        Logger.transcription.info("Summary written to \(summaryPath.lastPathComponent)")
    }

    /// Rewrite the transcript JSON's `metadata.disclosure` block in place (#138), preserving all
    /// other keys. Atomic. A transcript with no readable metadata is left unchanged.
    static func stampDisclosure(_ disclosure: SummaryDisclosure, into transcriptPath: URL) throws {
        let data = try Data(contentsOf: transcriptPath)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var metadata = (json["metadata"] as? [String: Any]) ?? [:]
        metadata["disclosure"] = disclosure.asMetadataDictionary()
        json["metadata"] = metadata
        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: transcriptPath, options: .atomic)
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
        return await runSummary(transcriptPath: transcriptPath, provider: Self.createProvider(from: summary), endpoint: summary.endpoint)
    }

    /// Run a summary with an explicit provider, translating success/failure into a `SummaryOutcome`.
    /// Logs the failure (preserving prior behavior) and reports it upward for user notification.
    static func runSummary(
        transcriptPath: URL,
        provider: any SummaryProvider,
        endpoint: String
    ) async -> SummaryOutcome {
        do {
            try await summarize(transcriptPath: transcriptPath, provider: provider, endpoint: endpoint)
            return .succeeded
        } catch SummaryError.invalidEndpoint {
            // The endpoint URL can carry a token in some proxies (e.g. Cloudflare AI Gateway), so its
            // raw value must reach neither the public log nor the user-visible failure message — the
            // latter can surface as a notification during a screen-shared meeting (#134 review).
            Logger.transcription.error("Summary generation failed: invalid summary endpoint")
            return .failed("Invalid summary endpoint — check your provider settings")
        } catch let error as SummaryError {
            // Public so provider/HTTP failures (e.g. "model failed to load") are diagnosable instead
            // of `<private>` (#134). This forwards the provider's own error text — the server message
            // for `serverError`, the HTTP response body for `requestFailed` — to both the log and the
            // notification. That assumes providers don't echo the bearer token in their error bodies,
            // which holds for the standard providers (OpenAI / LM Studio / Ollama). The one case that
            // embeds the configured endpoint URL (which *can* carry a token) — `invalidEndpoint` — is
            // sanitized in the branch above.
            Logger.transcription.error("Summary generation failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        } catch let error as URLError {
            // NOT a file failure. This branch exists because a URLError fell through to the
            // catch-all below and was reported as "check disk space and permissions" — which read as
            // a permissions problem and sent two separate debugging sessions down the wrong path
            // (2026-08-04 and 2026-08-11, both actually `-1001` request timeouts against a local
            // LM Studio that accepted the request and then generated for longer than the timeout).
            // An error message that misdescribes the fault is worse than a vague one.
            Logger.transcription.error(
                "Summary generation failed: \(error.code.rawValue, privacy: .public) \(error.localizedDescription, privacy: .public)"
            )
            switch error.code {
            case .timedOut:
                return .failed("The model took too long to respond — the transcript is safe; try a smaller model or raise the summary timeout")
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                return .failed("Couldn't reach the summary endpoint — is your model server running?")
            default:
                return .failed("Summary request failed: \(error.localizedDescription)")
            }
        } catch {
            // A non-SummaryError, non-URLError here is a file read/write failure (transcript
            // unreadable, summary write failed). CocoaError's description embeds the
            // transcript/session filename, which would surface in the notification (visible during a
            // screen-share) — so keep the detail in the local log and give the user a generic,
            // actionable message (#134 review).
            Logger.transcription.error("Summary generation failed: \(error.localizedDescription)")
            return .failed("Couldn't read the transcript or write the summary — check disk space and permissions")
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
                maxOutputTokens: summary.maxOutputTokens,
                requestTimeoutSeconds: summary.requestTimeoutSeconds
            )
        case .openai:
            return OpenAISummaryProvider(
                endpoint: summary.endpoint,
                apiKey: summary.apiKey,
                model: summary.model,
                requestTimeoutSeconds: summary.requestTimeoutSeconds
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
