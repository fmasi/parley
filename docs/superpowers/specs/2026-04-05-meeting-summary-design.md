# Meeting Summary Generation — Design Spec

**Date:** 2026-04-05
**Issue:** #25 (rudimentary v1)
**Milestone:** v0.7.0

## Goal

Generate structured meeting minutes from a completed transcript. Auto-triggers after transcription if configured; also available as a CLI subcommand for retroactive use.

## Scope (v0.7.0)

- Two providers: OpenAI-compatible (`/v1/chat/completions`) and LM Studio native REST API v1 (`/api/v1/chat`)
- Single default prompt (structured meeting minutes)
- Provider protocol (`SummaryProvider`) for future Apple Intelligence support
- Per-model token ratio calibration with self-correcting context window sizing (LM Studio)
- Auto-trigger after transcription + CLI `summarize` subcommand + Settings UI

### Out of scope (future)

- Apple Intelligence on-device provider
- Multiple prompt templates / auto-detection of meeting type
- Map-reduce for transcripts exceeding model context window
- User-supplied prompt collections
- Per-chunk live summaries (only full-session summary)

## Architecture

### Provider Protocol

```swift
public protocol SummaryProvider: Sendable {
    func summarize(transcript: String) async throws -> String
}
```

Single method. The transcript string is the pre-formatted prompt (system + user content is handled by the caller for providers that don't support system messages, or by the provider itself for those that do).

Refined design: the protocol takes the raw segments + metadata. The provider is responsible for prompt formatting AND API call. This lets Apple Intelligence use a completely different prompt strategy (e.g. Apple's summarization API doesn't take a "system prompt").

```swift
public protocol SummaryProvider: Sendable {
    func summarize(segments: [TranscriptSegment], metadata: SummaryMetadata) async throws -> String
}

public struct TranscriptSegment: Sendable {
    public let start: Double
    public let end: Double
    public let speaker: String
    public let text: String
}

public struct SummaryMetadata: Sendable {
    public let sessionName: String
    public let date: Date
    public let durationSeconds: Double
    public let speakers: [String]
}
```

### OpenAISummaryProvider

Implements `SummaryProvider`. Sends a chat completion request to the configured endpoint.

- Uses `URLSession` — no third-party HTTP dependencies
- Formats segments into a readable transcript block for the user message
- Uses a system prompt with explicit section headers
- Supports any OpenAI-compatible API (the `/v1/chat/completions` contract)
- Handles errors gracefully: network failures, auth errors, rate limits → logged, summary skipped (never blocks the pipeline)

### MeetingSummarizer

Orchestrator in TranscriberCore. Responsibilities:

1. Read transcript JSON (or accept segments directly from pipeline)
2. Extract metadata (speakers, duration, session name)
3. Build `TranscriptSegment` array
4. Call `SummaryProvider.summarize()`
5. Write result to `<session-name>-summary.md`

For long transcripts (estimated >15k tokens input — roughly >60 min at typical speech rate), uses map-reduce: summarize per-chunk, then summarize the chunk summaries. Token estimation: ~1.3 tokens per word, ~150 words per minute of meeting → ~200 tokens/min. 15k token threshold ≈ 75 minutes.

### Config Changes

New optional nested struct in `Config`:

```swift
public struct SummaryConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var endpoint: String
    public var apiKey: String
    public var model: String
}
```

In `config.json`:
```json
{
  "summary": {
    "enabled": true,
    "endpoint": "https://api.openai.com/v1",
    "api_key": "sk-...",
    "model": "gpt-4o-mini"
  }
}
```

- `summary` is optional in config — absent means summarization disabled (backward compatible)
- `enabled` allows disabling without removing credentials
- `endpoint` has no default — must be explicitly configured (no surprise API calls)
- `api_key` can be empty for local providers (Ollama)

### Default Prompt

System message:
```
You are an expert executive assistant producing concise meeting notes.
Analyze the transcript and produce a structured summary in Markdown.

## Required Sections

### Executive Summary
2-3 sentences capturing the overall purpose and outcome of the meeting.

### Key Topics
Group discussion points by theme (not chronologically). For each topic,
write 1-3 sentences summarizing what was discussed. Attribute viewpoints
to speakers where relevant.

### Decisions
List each decision made, who made or endorsed it, and brief context for why.
If no decisions were made, omit this section.

### Action Items
For each action item: who is responsible, what they need to do, and any
deadline mentioned. If no action items, omit this section.

### Open Questions
Unresolved topics or questions that need follow-up. Omit if none.

## Rules
- Use speaker names exactly as they appear in the transcript
- Do not invent information not present in the transcript
- Do not include small talk, greetings, or off-topic banter
- Keep the total summary under 500 words
- Use professional, concise language
```

User message: the formatted transcript with speaker labels and timestamps.

### Integration Points

#### 1. Auto-trigger (post-transcription)

In `ChunkProcessor` (or the calling code that runs after all chunks are processed and the transcript is written):

```
After transcript file is written:
  if config.summary?.enabled == true && config.summary?.endpoint != nil:
    Task.detached {
      MeetingSummarizer.summarize(transcriptPath, config.summary!, outputDir)
    }
```

Fire-and-forget: summary failure never blocks or affects the transcript pipeline. Errors are logged via `Logger.transcription`.

#### 2. CLI subcommand

```bash
AudioTranscribe summarize -i transcript.json [--provider openai|lmstudio] [--endpoint URL] [--api-key KEY] [--model MODEL] [--context-length N]
```

- Reads transcript JSON, runs summarization, writes `-summary.md` alongside
- CLI flags override config.json values (useful for one-off runs with different providers)
- If no endpoint configured anywhere, prints error and exits

#### 3. Settings UI

New section in SettingsView: "Meeting Summary"
- Toggle: "Auto-summarize after transcription" (maps to `summary.enabled`)
- Picker: Provider (OpenAI Compatible / LM Studio)
- Text field: Endpoint URL (help text adapts to provider)
- Secure text field: API Key (can be empty for local providers)
- Text field: Model name
- Text field: Context Length (LM Studio only, optional — auto-sized if empty)

## Output

File: `<session-name>-summary.md` in the same directory as the transcript.

Plain markdown. The content is whatever the LLM returns (which follows the structured prompt above).

## Error Handling

- Network failure → log warning, skip summary. Transcript is unaffected.
- Auth error (401/403) → log error with hint to check API key. Skip summary.
- Rate limit (429) → log warning. No retry in v1 (future: exponential backoff).
- Malformed response → log error with response body excerpt. Skip summary.
- Summary never blocks, never throws to caller, never affects transcript integrity.

## Files Created/Modified

### New files
- `TranscriberCore/SummaryProvider.swift` — `SummaryProvider` protocol + `SummarySegment` + `SummaryMetadata` types
- `TranscriberCore/OpenAISummaryProvider.swift` — OpenAI-compatible provider (`/v1/chat/completions`), system prompt, request building, response parsing
- `TranscriberCore/LMStudioSummaryProvider.swift` — LM Studio native REST API v1 provider (`/api/v1/chat`), per-request context_length, token stats, auto-sizing, self-correcting retry
- `TranscriberCore/MeetingSummarizer.swift` — orchestrator: reads transcript JSON, creates provider from config via `createProvider(from:)`, writes `-summary.md`
- `TranscriberCore/TokenRatioCache.swift` — per-model chars/token ratio cache with probe calibration, continuous refinement from real transcripts, seed vs measured distinction
- `SwiftTests/TranscriberTests/MeetingSummarizerTests.swift` — 3 tests with mock/capturing providers
- `SwiftTests/TranscriberTests/OpenAISummaryProviderTests.swift` — 5 tests for request shape, auth, response parsing
- `SwiftTests/TranscriberTests/LMStudioSummaryProviderTests.swift` — 11 tests for native API, auto-sizing, context capping, error parsing
- `SwiftTests/TranscriberTests/TokenRatioCacheTests.swift` — 11 tests for seed/measured lifecycle, EMA blending, legacy migration
- `SwiftTests/TranscriberTests/CLIParserTests.swift` — 3 tests for summarize subcommand parsing

### Modified files
- `TranscriberCore/Config.swift` — `SummaryProviderType` enum, `SummaryConfig` struct with provider/endpoint/apiKey/model/contextLength, optional `summary` field on `Config`
- `TranscriberCore/CLIParser.swift` — `SummarizeOptions` struct, `.summarize` command case, `--provider`/`--endpoint`/`--api-key`/`--model`/`--context-length` flags
- `TranscriberApp/TranscriberApp.swift` — added "summarize" to `cliSubcommands` set
- `TranscriberApp/Services/CLIHandler.swift` — `handleSummarize` with provider selection via `MeetingSummarizer.createProvider(from:)`
- `TranscriberApp/Services/TranscriptionRunner.swift` — auto-trigger `MeetingSummarizer.summarizeIfConfigured` in both `run()` and `finalize()` paths
- `TranscriberApp/Views/SettingsView.swift` — "Meeting Summary" section with provider picker, endpoint, API key (SecureField), model, context length (LM Studio only)
- `SwiftTests/TranscriberTests/ConfigTests.swift` — 4 tests for summary config round-trip, snake_case keys, backward compat

## Token Ratio Calibration

The LM Studio provider auto-sizes the context window per request. This requires estimating how many tokens the input text will produce. The estimation uses a **chars-per-token ratio** that varies by model (different tokenizer vocabularies):

### Lifecycle

1. **No data** → default ratio 3.0 chars/token (conservative for transcript-style text)
2. **First use of a model** → calibration probe: 283 chars of transcript-style text (timestamps + speaker labels) sent to the model → actual token count from `stats.input_tokens` → stored as "seed" ratio
3. **First real transcript** (>2000 chars) → actual token count from response stats → **replaces seed entirely** (seed is never blended into the average — it's only a starting point)
4. **Subsequent real transcripts** → EMA blend: `new_ratio = 0.3 * measured + 0.7 * cached` (converges quickly, remains stable)
5. **Context overflow error** → `n_keep: NNNNN` parsed from HTTP 500 body → exact ratio set via `setRatio` → retry succeeds → ratio cached as real measurement

### Design decisions

- **Ratio is per-model, not per-prompt.** The chars/token ratio is a property of the tokenizer (baked into the model file). Different prompts change the char count but not the ratio. `estimateTokens(text, model:)` works on any string.
- **Seed vs measured distinction** prevents probe data (tiny text, template-dominated) from polluting the running average of real transcript measurements.
- **Minimum 2000 chars** for a measurement to count — small requests have disproportionate template overhead that skews the ratio.
- **Persistence** at `~/.audio-transcribe/token-ratios.json` survives app restarts. Includes legacy migration from plain `[String: Double]` format.

### Measured values (Gemma 4, 256K vocab)
- Probe (283 chars): 2.94 chars/token (4% off real, safe overcount)
- Real transcript (61K chars, 53 min meeting): **3.06 chars/token**
- Generic English prose: ~4.0-4.5 chars/token (higher because no timestamps/speaker labels)

## Testing Strategy

- **361 tests across 37 suites** — all offline, no network calls in tests
- `MeetingSummarizerTests`: mock and capturing providers verify file output, metadata extraction, error propagation
- `OpenAISummaryProviderTests`: verify request JSON shape, auth header, response parsing without hitting API
- `LMStudioSummaryProviderTests`: verify native API request format, auto-sizing context, capping at user limit, error message parsing
- `TokenRatioCacheTests`: seed replacement by real measurement, EMA blending, small-request filtering, legacy format migration
- `CLIParserTests`: summarize subcommand with all flag combinations
- `ConfigTests`: SummaryConfig round-trip, snake_case keys, backward compatibility with configs lacking `summary`

## Future Considerations

- **Multiple prompts**: `SummaryConfig` gains a `promptTemplate: String?` field. Built-in templates keyed by meeting type (standup, 1:1, planning). Auto-detection via a cheap classifier call before the main summary. Token estimation is unaffected (ratio is per-model, not per-prompt).
- **Apple Intelligence**: new `AppleIntelligenceSummaryProvider` conforming to `SummaryProvider`. Selected automatically when available and no endpoint is configured.
- **Provider selection logic**: `if appleIntelligenceAvailable && !endpointConfigured → Apple Intelligence; else if endpointConfigured → configured provider; else → skip`
- **Map-reduce for long transcripts**: When estimated input exceeds the model's max context, summarize per-chunk then summarize the summaries. The token estimation infrastructure is already in place.
