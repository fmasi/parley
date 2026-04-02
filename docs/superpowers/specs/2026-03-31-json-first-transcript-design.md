# JSON-First Transcript Output

**Date:** 2026-03-31
**Branch:** feature/json-first-transcript

## Problem

When the Swift app renames speakers via the rename dialog, only the JSON file is updated. The format file (SRT/TXT) retains stale speaker labels because Python generates it during transcription, before renaming occurs.

Additionally, generating a format file in Python that Swift will overwrite after the rename dialog is wasted compute and I/O.

## Design

JSON becomes the sole output of the Python transcription step. Format files (SRT/TXT) are derived from JSON by Swift, after the rename dialog closes.

### Flow

```
Recording stops
  -> Python transcribe.py runs with -f json -> writes JSON only
  -> Rename dialog opens automatically
  -> User saves (JSON updated with new names) OR cancels (JSON unchanged)
  -> Swift reads JSON, generates format file (SRT/TXT) based on metadata.output_format
```

### Components

#### 1. TranscriptWriter (new — TranscriberCore)

Pure formatting utility. No AppKit dependency, fully testable.

```swift
public enum TranscriptWriter {
    /// Generate a format file (.srt or .txt) from a JSON transcript.
    /// Reads segments and output_format from the JSON, writes the format file
    /// alongside the JSON (same directory, same base name, different extension).
    /// No-op if output_format is "json".
    static func writeFormatFile(fromJSON jsonPath: URL) throws
}
```

Internal helpers:
- `formatSRT(segments:) -> String` — SRT format matching Python's `write_srt`: `{index}\n{HH:MM:SS,mmm} --> {HH:MM:SS,mmm}\n{speaker}: {text}\n\n`
- `formatTXT(segments:) -> String` — TXT format matching Python's `write_txt`: `[HH:MM:SS] {speaker}: {text}\n`
- `formatTimestamp(_:) -> String` — `HH:MM:SS,mmm` (SRT)
- `formatTimestampShort(_:) -> String` — `HH:MM:SS` (TXT)

#### 2. TranscriptionRunner (modified)

- Always pass `-f json` to Python (hardcoded, ignore `config.outputFormat`)
- Remove `outputFormat` parameter from `run()`
- `TranscriptionResult.outputPath` becomes the JSON path (remove `jsonPath` optional — JSON is always the output)

#### 3. RenameWindowController (modified)

Both save and cancel callbacks call `TranscriptWriter.writeFormatFile(fromJSON:)` after the dialog closes:

- **Save:** `applySpeakerRenames` updates JSON, then `writeFormatFile` generates format file with renamed speakers
- **Cancel:** `writeFormatFile` generates format file from original JSON (original speaker labels)

#### 4. MenuView (modified)

- `stopRecording()`: remove `outputFormat` from `transcriptionRunner.run()` call
- Update `TranscriptionResult` usage: `result.outputPath` is now the JSON, no separate `result.jsonPath`
- `appState.lastTranscriptPath` points to the format file path (derived: same base name + format extension) for "Open Last Transcript" menu item, or nil until format file is generated

### What stays unchanged

- **Python `transcribe.py`**: No code changes. Passing `-f json` makes it output JSON only (existing behavior on line 387-388).
- **Python `rename_speakers.py`**: Independent CLI path, keeps its own SRT/TXT generation.
- **Config.outputFormat**: Still stored in config, still read from JSON metadata at format generation time.

### Format matching

Swift output must match Python output exactly:

**SRT:**
```
1
00:00:08,039 --> 00:00:09,039
Speaker Name: text here

2
00:00:11,959 --> 00:00:29,579
Another Speaker: more text

```

**TXT:**
```
[00:00:08] Speaker Name: text here
[00:00:11] Another Speaker: more text
```

Empty speaker string: omit the `Speaker: ` prefix (just output the text).

### Test plan

Tests live in `SwiftTests/TranscriberTests/TranscriptWriterTests.swift`:

1. `formatTimestamp` — seconds to `HH:MM:SS,mmm`
2. `formatTimestampShort` — seconds to `HH:MM:SS`
3. `formatSRT` — multiple segments with speakers, correct indexing and formatting
4. `formatSRT` with empty speaker — no prefix
5. `formatTXT` — multiple segments with speakers
6. `formatTXT` with empty speaker — no prefix
7. `writeFormatFile` with SRT metadata — writes `.srt` alongside JSON
8. `writeFormatFile` with TXT metadata — writes `.txt` alongside JSON
9. `writeFormatFile` with JSON metadata — no-op, no extra file created
10. `writeFormatFile` with renamed speakers — format file reflects renamed names
