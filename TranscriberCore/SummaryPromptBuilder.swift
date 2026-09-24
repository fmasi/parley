import Foundation

/// Shared prompt + transcript formatting for the summary providers. Both `OpenAISummaryProvider`
/// and `LMStudioSummaryProvider` build the same system prompt and user message from a transcript
/// plus metadata; keeping it in one place means a third provider (#37) doesn't copy it a third
/// time, and prompt templates (#38) have a single home instead of a hardcoded static inside one
/// concrete provider.
enum SummaryPromptBuilder {

    /// The system message: the base prompt, plus the dual-stream echo hint when the recording
    /// carried separate microphone / system streams.
    static func systemMessage(dualStream: Bool) -> String {
        dualStream ? systemPrompt + dualStreamHint : systemPrompt
    }

    /// `systemMessage(dualStream:)`, minus the echo hint when there is no remote audio to compare
    /// against (not captured, nothing playing, or uncertain): the hint tells the model to use
    /// "concurrent remote segments", which would contradict the header.
    static func systemMessage(metadata: SummaryMetadata) -> String {
        let remote = metadata.remoteCapture.map { verdict($0, isRemote: true) }
        let noRemoteAudio: Set<SideVerdict> = [.notCaptured, .idle, .permissionDeniedSilence, .uncertainSilence]
        return systemMessage(dualStream: metadata.dualStream && !(remote.map(noRemoteAudio.contains) ?? false))
    }

    /// The user message: the meeting-metadata header followed by the formatted transcript.
    static func userMessage(metadata: SummaryMetadata, segments: [SummarySegment]) -> String {
        let transcript = formatTranscript(segments, includeSource: metadata.dualStream)
        // A side that was not captured is stated in the header (§7.3): otherwise the model reads a
        // one-sided transcript as a one-sided meeting and summarises it as if nobody else spoke.
        let capture = captureLine(metadata).map { "\n\($0)" } ?? ""
        return """
        Meeting: \(metadata.sessionName)
        Date: \(formatDate(metadata.date))
        Duration: \(formatDuration(metadata.durationSeconds))
        Participants: \(metadata.speakers.joined(separator: ", "))\(capture)

        --- TRANSCRIPT ---
        \(transcript)
        """
    }

    /// The header line(s) about what was captured, newline-joined, or nil when there is nothing to
    /// say (both sides healthy, or an untracked transcript). Order: remote, microphone, "coverage
    /// not recorded", recording gaps.
    static func captureLine(_ metadata: SummaryMetadata) -> String? {
        let lines = captureLines(metadata).map(\.text)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The deterministic banner `MeetingSummarizer` puts at the top of `-summary.md` when a side was
    /// not (fully) captured or the recording has gaps — the summary must never read as complete on
    /// the strength of a model obeying an instruction. nil when nothing warrants one (a healthy or
    /// idle side, or coverage merely not recorded).
    static func captureBanner(_ metadata: SummaryMetadata) -> String? {
        let lines = captureLines(metadata).filter(\.warrantsBanner).map(\.text)
        guard !lines.isEmpty else { return nil }
        return "> ⚠️ This summary covers only what was captured:\n"
            + lines.map { "> \($0)" }.joined(separator: "\n") + "\n\n"
    }

    /// How one side's capture reads, from its recorded status and facts.
    enum SideVerdict: Hashable {
        case healthy, idle, notCaptured, partlyCaptured, permissionDeniedSilence, uncertainSilence, localSilence,
             localPartialSilence, compromised, unknown
    }

    /// `compromised` is split by WHY, because one word cannot cover them honestly: a shortfall is
    /// "partly captured"; a full-length track of exact digital silence is "not captured" only when
    /// the permission denial was confirmed, and "uncertain" otherwise (the other side may simply
    /// have been muted — never claim a fault that can't be confirmed, never claim health either);
    /// anything else is "captured, but compromised". An unreadable status is "unknown" (fail closed).
    static func verdict(_ note: CaptureSideNote, isRemote: Bool) -> SideVerdict {
        switch TrackAccounting.Status(rawValue: note.status) {
        case .healthy: return .healthy
        // `idle` is a tap-only verdict (nothing played on this Mac); a mic is never idle.
        case .idle: return isRemote ? .idle : .healthy
        case .neverDelivered: return .notCaptured
        case nil: return .unknown
        case .compromised:
            if isSignificant(note.expectedSeconds - note.deliveredSeconds, of: note.expectedSeconds) { return .partlyCaptured }
            if let zeros = note.exactZeroSeconds, isSignificant(zeros, of: note.deliveredSeconds) {
                if isRemote { return note.permissionDenied == true ? .permissionDeniedSilence : .uncertainSilence }
                // "Only digital silence" only when under a second of non-zero audio remains — a mic
                // that died 5 minutes into an hour DID record the user for those 5 minutes.
                return note.deliveredSeconds - zeros < 1 ? .localSilence : .localPartialSilence
            }
            return .compromised
        }
    }

    /// The same bar `TrackAccounting` uses for a coverage deficit: ≥ 15 s AND ≥ 10 % of the whole.
    private static func isSignificant(_ part: Double, of whole: Double) -> Bool {
        part.isFinite && whole.isFinite && whole > 0
            && part >= TrackAccounting.minimumDeficitSeconds && part / whole >= TrackAccounting.deficitRatio
    }

    private struct CaptureHeaderLine {
        let text: String
        let warrantsBanner: Bool
    }

    private static func captureLines(_ metadata: SummaryMetadata) -> [CaptureHeaderLine] {
        var lines = [
            metadata.remoteCapture.flatMap { sideLine("Remote audio", $0, isRemote: true) },
            metadata.localCapture.flatMap { sideLine("Your microphone", $0, isRemote: false) },
        ].compactMap { $0 }
        if metadata.coverageNotRecorded {
            lines.append(CaptureHeaderLine(text: "Capture coverage was not recorded", warrantsBanner: false))
        }
        if metadata.gapCount > 0 {
            lines.append(CaptureHeaderLine(
                text: "Recording gaps: \(metadata.gapCount) (total \(formatGap(metadata.gapSeconds)))",
                warrantsBanner: metadata.gapSeconds > 0
            ))
        }
        return lines
    }

    private static func sideLine(_ label: String, _ note: CaptureSideNote, isRemote: Bool) -> CaptureHeaderLine? {
        let delivered = seconds(note.deliveredSeconds), expected = seconds(note.expectedSeconds)
        let amounts = "(\(delivered) s delivered of \(expected) s expected)"
        let silence = note.exactZeroSeconds.map(seconds) ?? "?"
        // What WAS delivered may itself be digital silence; "partly captured" or "compromised" must
        // not hide how much.
        let silenceSuffix = (note.exactZeroSeconds ?? 0).rounded() >= 1 && (note.exactZeroSeconds ?? 0).isFinite
            ? "; \(silence) s of it was digital silence" : ""
        let text: String
        switch verdict(note, isRemote: isRemote) {
        case .healthy: return nil
        case .idle: return CaptureHeaderLine(text: "\(label): nothing was playing on this Mac (no remote side)", warrantsBanner: false)
        case .notCaptured: text = "\(label): not captured \(amounts)"
        case .partlyCaptured:
            // A confirmed denial on a side that was only partly captured is part of why.
            let permission = isRemote && note.permissionDenied == true
                ? "; system audio permission was not granted for part of the call" : ""
            text = "\(label): partly captured \(amounts)\(silenceSuffix)\(permission)"
        case .permissionDeniedSilence:
            // "not granted" is true for both a denial and a permission never answered (TCC
            // `notDetermined`) — the two statuses that count as a confirmed denial.
            text = "\(label): not captured — system audio permission was not granted; \(silence) s of digital silence were recorded instead"
        case .uncertainSilence:
            text = "\(label): uncertain — \(silence) s were exact digital silence and Parley could not confirm the permission; the other side may have been muted, or not captured"
        case .localSilence: text = "\(label): recorded only digital silence (\(silence) s)"
        case .localPartialSilence: text = "\(label): captured, but \(silence) s of \(delivered) s was digital silence"
        case .compromised:
            let detail = note.anomalyCount.map { "\($0) capture \($0 == 1 ? "anomaly" : "anomalies") recorded" }
                ?? "anomaly count not recorded"
            text = "\(label): captured, but compromised (\(detail))\(silenceSuffix)"
        case .unknown: text = "\(label): capture status unknown (\(delivered) s of \(expected) s)"
        }
        return CaptureHeaderLine(text: text, warrantsBanner: true)
    }

    /// Whole seconds, or "?" for a value no recording could have (non-finite, negative, or beyond a
    /// century) — a corrupted transcript must not crash summarizing (`Int(1e300)` traps).
    private static func seconds(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < 3_153_600_000 else { return "?" }
        return String(format: "%.0f", value)
    }

    /// "3 min 10 s", "45 s", "1 h 2 min 5 s".
    private static func formatGap(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < 3_153_600_000 else { return "? s" }
        let total = Int(value.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h) h \(m) min \(s) s" }
        if m > 0 { return "\(m) min \(s) s" }
        return "\(s) s"
    }

    static func formatTranscript(_ segments: [SummarySegment], includeSource: Bool = false) -> String {
        segments.map { seg in
            // A corrupted time (non-finite, negative, absurd) prints as unknown: `Int(1e300)` traps.
            let ts: String
            if seg.start.isFinite, seg.start >= 0, seg.start < 3_153_600_000 {
                let total = Int(seg.start)
                ts = String(format: "[%02d:%02d:%02d]", total / 3600, (total % 3600) / 60, total % 60)
            } else {
                ts = "[--:--:--]"
            }
            let sourceTag = includeSource && !seg.source.isEmpty ? " (\(seg.source))" : ""
            return "\(ts) \(seg.speaker)\(sourceTag): \(seg.text)"
        }.joined(separator: "\n")
    }

    static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f.string(from: date)
    }

    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 3_153_600_000 else { return "?" }
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
    - If a "Remote audio" or "Your microphone" line says a side was not captured, partly captured, uncertain, compromised, or recorded only digital silence, state that in the Summary section before anything else.
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
