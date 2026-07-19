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

    /// The user message: the meeting-metadata header followed by the formatted transcript.
    static func userMessage(metadata: SummaryMetadata, segments: [SummarySegment]) -> String {
        let transcript = formatTranscript(segments, includeSource: metadata.dualStream)
        return """
        Meeting: \(metadata.sessionName)
        Date: \(formatDate(metadata.date))
        Duration: \(formatDuration(metadata.durationSeconds))
        Participants: \(metadata.speakers.joined(separator: ", "))

        --- TRANSCRIPT ---
        \(transcript)
        """
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

    static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f.string(from: date)
    }

    static func formatDuration(_ seconds: Double) -> String {
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
