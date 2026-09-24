import Foundation
import os

/// Result of an attempted auto-summary, so the caller can decide whether to surface a failure
/// to the user instead of it failing silently (#134).
public enum SummaryOutcome: Equatable, Sendable {
    case skipped                 // summary not configured / disabled
    case succeeded
    case failed(String)          // localized description of the failure
    /// The user cancelled — quit the app, or the stop path tore the task down. Deliberately NOT
    /// `.failed`: the only call site pattern-matches `.failed` to post a "Summary Failed"
    /// notification, so reusing it would tell someone their summary broke when they are the one
    /// who stopped it. Nothing went wrong and nothing needs saying.
    case cancelled
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

        // #138 / C-I6: the transcript testifies BEFORE its content leaves the machine. Stamped only
        // after a written summary, a request that timed out after sending (the documented -1001
        // case) left `transcript_transmitted: false` on a transcript that went to a remote endpoint.
        // If the stamp cannot be written, nothing is sent.
        try Self.stampDisclosure(.attempted(endpoint: endpoint), into: transcriptPath)

        let response = try await provider.summarizeDetailed(segments: segments, metadata: metadata)

        // Parley's own statement of what was not captured comes first, deterministically: a model
        // instruction alone is not a guarantee (small local models drop late rules). Then a summary
        // cut off at the model's output limit, which also reads as complete (P14).
        let banner = (SummaryPromptBuilder.captureBanner(metadata) ?? "")
            + (response.truncated ? Self.truncationBanner : "")

        // Deterministically stamp the source transcript filename as a footer so
        // the notes can always be traced back to their source — independent of
        // whether the LLM chose to mention it.
        let body = banner + response.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamped = "\(body)\n\n---\n*Source transcript: `\(transcriptPath.lastPathComponent)`*\n"

        let baseName = transcriptPath.deletingPathExtension().lastPathComponent
        let summaryPath = transcriptPath.deletingLastPathComponent()
            .appendingPathComponent(baseName + "-summary.md")
        try stamped.write(to: summaryPath, atomically: true, encoding: .utf8)

        // #138: the summary exists — the final state of the disclosure stamped above.
        try Self.stampDisclosure(.generated(endpoint: endpoint), into: transcriptPath)

        Logger.transcription.info("Summary written to \(summaryPath.lastPathComponent)")
    }

    static let truncationBanner = "> ⚠️ This summary may be incomplete: the model reached its output limit.\n\n"

    /// Rewrite the transcript JSON's `metadata.disclosure` block in place (#138), preserving all
    /// other keys. Atomic. A transcript with no readable metadata is left unchanged.
    ///
    /// Never un-says a disclosure: once `transcript_transmitted` or `summary_generated` is true it
    /// stays true, and every host the content was sent to stays in `transcript_transmitted_to` — a
    /// re-summary on this Mac must not make a transcript that left the machine read "airgapped".
    /// `summary_endpoint` names the endpoint that generated the summary (changed only by a
    /// generation), a separate fact (R2b item 6).
    static func stampDisclosure(_ disclosure: SummaryDisclosure, into transcriptPath: URL) throws {
        let data = try Data(contentsOf: transcriptPath)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var metadata = (json["metadata"] as? [String: Any]) ?? [:]
        let previous = metadata["disclosure"] as? [String: Any]
        let wasTransmitted = previous?["transcript_transmitted"] as? Bool == true
        let wasGenerated = previous?["summary_generated"] as? Bool == true
        let previousEndpoint = previous?["summary_endpoint"] as? String
        // A disclosure written before the host list existed: its endpoint is where it was sent.
        let previousHosts = previous?["transcript_transmitted_to"] as? [String]
            ?? (wasTransmitted ? [previousEndpoint].compactMap { $0 } : [])
        var hosts = previousHosts
        for host in disclosure.transcriptTransmittedTo where !hosts.contains(host) { hosts.append(host) }
        let stamped = SummaryDisclosure(
            summaryGenerated: disclosure.summaryGenerated || wasGenerated,
            summaryEndpoint: disclosure.summaryGenerated ? disclosure.summaryEndpoint : (wasGenerated ? previousEndpoint : nil),
            transcriptTransmitted: disclosure.transcriptTransmitted || wasTransmitted,
            transcriptTransmittedTo: hosts
        )
        metadata["disclosure"] = stamped.asMetadataDictionary()
        json["metadata"] = metadata
        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: transcriptPath, options: .atomic)
    }

    /// Convenience: create provider from config + summarize. Never throws; returns a
    /// `SummaryOutcome` so the caller can notify the user on failure rather than the summary
    /// failing silently (#134).
    public static func summarizeIfConfigured(
        transcriptPath: URL,
        config: Config,
        keychain: KeychainStoring = KeychainStore.shared
    ) async -> SummaryOutcome {
        guard let summary = config.summary, summary.enabled, !summary.endpoint.isEmpty else {
            return .skipped
        }
        // #48: the API key no longer lives on `SummaryConfig` — it's fetched from the Keychain at
        // the point of use instead of round-tripping through config.json.
        let apiKey = SummaryAPIKeyStore.load(keychain: keychain)
        return await runSummary(transcriptPath: transcriptPath, provider: Self.createProvider(from: summary, apiKey: apiKey), endpoint: summary.endpoint)
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
            case .cancelled:
                // The user quit, or the stop path tore the task down. Not a fault: `.cancelled`
                // rather than `.failed`, so no "Summary Failed" notification fires for something
                // they did on purpose.
                Logger.transcription.info("Summary cancelled — transcript is untouched")
                return .cancelled
            default:
                return .failed("Summary request failed: \(error.localizedDescription)")
            }
        } catch is CancellationError {
            // Swift's structured-concurrency cancellation (Task.checkCancellation(), app quitting,
            // the stop path tearing the task down) throws this distinct type — separate from
            // `URLError.cancelled` above — but it's the same "user did this on purpose" case, so it
            // gets the same non-`.failed` treatment (#191, same misdirection as #173's URLError case).
            Logger.transcription.info("Summary cancelled via task cancellation — transcript is untouched")
            return .cancelled
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

    /// Create the appropriate provider from config. `apiKey` is passed in separately (#48) —
    /// `SummaryConfig` no longer carries it; callers fetch it from `SummaryAPIKeyStore` first.
    public static func createProvider(from summary: SummaryConfig, apiKey: String) -> any SummaryProvider {
        switch summary.provider {
        case .lmstudio:
            return LMStudioSummaryProvider(
                endpoint: summary.endpoint,
                apiKey: apiKey,
                model: summary.model,
                contextLength: summary.contextLength,
                contextOverheadPercent: summary.contextOverheadPercent,
                maxOutputTokens: summary.maxOutputTokens,
                requestTimeoutSeconds: summary.requestTimeoutSeconds
            )
        case .openai:
            return OpenAISummaryProvider(
                endpoint: summary.endpoint,
                apiKey: apiKey,
                model: summary.model,
                requestTimeoutSeconds: summary.requestTimeoutSeconds
            )
        }
    }

    // MARK: - Private

    /// Test seam for `parseTranscript(at:)`.
    static func parseTranscriptForTesting(at path: URL) throws -> ([SummarySegment], SummaryMetadata) {
        try parseTranscript(at: path)
    }

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
        let capture = metadata_raw?["capture"] as? [String: Any]
        let provenance = metadata_raw?["capture_provenance"] as? [String: Any]
        let gaps = capture?["gaps"] as? [[String: Any]] ?? []

        // Flagged segments (VAD-filtered noise, mic-bleed echo) are kept in the record but are not
        // what anybody said to the meeting: the model never sees them (P10/P11). Nor does it see a
        // segment with no usable time (R2b item 5) — never placed at 00:00:00 — and the header says
        // how many were left out.
        let segments = rawSegments.filter { !TranscriptAssembler.isFlagged($0) }.map { seg in
            SummarySegment(
                start: seg["start"] as? Double ?? .nan,   // unreachable: flagged when not a Double
                end: seg["end"] as? Double ?? .nan,
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

        // From every segment, flagged or not: the meeting lasted as long as its last recorded moment
        // (the latest real end — a segment with no usable time says nothing about it).
        let duration = rawSegments.compactMap { $0["end"] as? Double }.filter(\.isFinite).max() ?? 0
        let sessionName = path.deletingPathExtension().lastPathComponent

        let metadata = SummaryMetadata(
            sessionName: sessionName,
            date: resolveRecordingDate(metadata: metadata_raw, transcriptPath: path),
            durationSeconds: duration,
            speakers: speakers,
            dualStream: dualStream,
            echoSegmentsRemoved: echoRemoved,
            remoteCapture: captureSideNote(capture?["remote"], provenance: provenance, isRemote: true),
            localCapture: captureSideNote(capture?["local"], provenance: provenance, isRemote: false),
            // Written by a build that tracks issues, yet no coverage for either side: say so rather
            // than let silence read as "complete".
            coverageNotRecorded: metadata_raw?["processing_issues"] != nil && capture?["remote"] == nil && capture?["local"] == nil,
            gapCount: gaps.count,
            gapSeconds: gaps.reduce(0) { $0 + (validSeconds($1["seconds"]) ?? 0) },
            untimedSegmentCount: rawSegments.filter { !TranscriptAssembler.hasUsableTime($0) }.count
        )

        return (segments, metadata)
    }

    /// One side of `metadata.capture` (§7.2) as a `CaptureSideNote`; nil when the side is absent.
    /// A side with no readable `status` keeps an empty status, which reads as "unknown" (fail
    /// closed). Seconds outside any real range become NaN and print as "?".
    private static func captureSideNote(_ raw: Any?, provenance: [String: Any]?, isRemote: Bool) -> CaptureSideNote? {
        guard let side = raw as? [String: Any] else { return nil }
        return CaptureSideNote(
            status: side["status"] as? String ?? "",
            deliveredSeconds: validSeconds(side["delivered_seconds"]) ?? .nan,
            expectedSeconds: validSeconds(side["expected_seconds"]) ?? .nan,
            exactZeroSeconds: validSeconds(side["exact_zero_seconds"]),
            // The CONFIRMED-denial field only: `system_audio_unrecovered` is also set by a failed
            // stream restart, and "permission denied" is a claim Parley must be able to back.
            permissionDenied: isRemote ? provenance?["system_permission_denied_confirmed"] as? Bool : nil,
            // This side's own content anomalies — the session-wide `quality_anomaly_count` would
            // blame one side for the other's faults.
            anomalyCount: side["content_anomaly_count"] as? Int,
            exactZeroIsLowerBound: side["exact_zero_seconds_is_lower_bound"] as? Bool == true
        )
    }

    /// A seconds value a recording could have: finite, ≥ 0, under a century. nil otherwise.
    private static func validSeconds(_ raw: Any?) -> Double? {
        guard let value = raw as? Double, value.isFinite, value >= 0, value < 3_153_600_000 else { return nil }
        return value
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
