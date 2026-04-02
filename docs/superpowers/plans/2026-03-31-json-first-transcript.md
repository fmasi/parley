# JSON-First Transcript Output — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make JSON the sole transcription output; derive format files (SRT/TXT) in Swift after the rename dialog closes.

**Architecture:** New `TranscriptWriter` in TranscriberCore provides pure formatting functions (SRT/TXT) and a `writeFormatFile(fromJSON:)` entry point. `RenameWindowController` calls it on both save and cancel. `TranscriptionRunner` always passes `-f json` to Python.

**Tech Stack:** Swift Testing, Foundation, TranscriberCore

**Spec:** `docs/superpowers/specs/2026-03-31-json-first-transcript-design.md`

---

### File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `TranscriberCore/TranscriptWriter.swift` | Pure formatting (SRT/TXT) + write-to-disk |
| Create | `SwiftTests/TranscriberTests/TranscriptWriterTests.swift` | Unit tests for all formatting + file writing |
| Modify | `TranscriberApp/Services/RenameWindowController.swift` | Call `TranscriptWriter.writeFormatFile` on save and cancel |
| Modify | `TranscriberApp/Services/TranscriptionRunner.swift` | Hardcode `-f json`, simplify `TranscriptionResult` |
| Modify | `TranscriberApp/Views/MenuView.swift` | Remove `outputFormat` from `run()` call, update result usage |

---

### Task 1: TranscriptWriter — Timestamp Formatting

**Files:**
- Create: `SwiftTests/TranscriberTests/TranscriptWriterTests.swift`
- Create: `TranscriberCore/TranscriptWriter.swift`

- [ ] **Step 1: Write failing tests for timestamp formatting**

```swift
import Testing
import Foundation
@testable import TranscriberCore

struct TranscriptWriterTests {

    // MARK: - Timestamp formatting

    @Test func formatTimestampZero() {
        #expect(TranscriptWriter.formatTimestamp(0) == "00:00:00,000")
    }

    @Test func formatTimestampWithMilliseconds() {
        #expect(TranscriptWriter.formatTimestamp(8.039) == "00:00:08,039")
    }

    @Test func formatTimestampMinutesAndHours() {
        #expect(TranscriptWriter.formatTimestamp(3661.5) == "01:01:01,500")
    }

    @Test func formatTimestampShortZero() {
        #expect(TranscriptWriter.formatTimestampShort(0) == "00:00:00")
    }

    @Test func formatTimestampShortTruncatesMillis() {
        #expect(TranscriptWriter.formatTimestampShort(8.039) == "00:00:08")
    }

    @Test func formatTimestampShortMinutesAndHours() {
        #expect(TranscriptWriter.formatTimestampShort(3661.5) == "01:01:01")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TranscriberTests.TranscriptWriterTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/`
Expected: FAIL — `TranscriptWriter` not defined

- [ ] **Step 3: Implement timestamp formatting**

```swift
import Foundation

public enum TranscriptWriter {
    /// Format seconds as HH:MM:SS,mmm (SRT format).
    static func formatTimestamp(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    /// Format seconds as HH:MM:SS (TXT format).
    static func formatTimestampShort(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2
Expected: All 6 tests PASS

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/TranscriptWriter.swift SwiftTests/TranscriberTests/TranscriptWriterTests.swift
git commit -m "feat: add TranscriptWriter timestamp formatting with tests"
```

---

### Task 2: TranscriptWriter — SRT Formatting

**Files:**
- Modify: `SwiftTests/TranscriberTests/TranscriptWriterTests.swift`
- Modify: `TranscriberCore/TranscriptWriter.swift`

- [ ] **Step 1: Write failing tests for SRT formatting**

Append to `TranscriptWriterTests`:

```swift
    // MARK: - SRT formatting

    @Test func formatSRTMultipleSegments() {
        let segments: [[String: Any]] = [
            ["start": 8.039, "end": 9.039, "speaker": "Alice", "text": "Hello"],
            ["start": 11.959, "end": 29.579, "speaker": "Bob", "text": "Hi there"],
        ]
        let expected = """
            1
            00:00:08,039 --> 00:00:09,039
            Alice: Hello

            2
            00:00:11,959 --> 00:00:29,579
            Bob: Hi there

            """
        #expect(TranscriptWriter.formatSRT(segments: segments) == expected)
    }

    @Test func formatSRTEmptySpeakerOmitsPrefix() {
        let segments: [[String: Any]] = [
            ["start": 0.0, "end": 1.0, "speaker": "", "text": "No speaker"],
        ]
        let expected = """
            1
            00:00:00,000 --> 00:00:01,000
            No speaker

            """
        #expect(TranscriptWriter.formatSRT(segments: segments) == expected)
    }

    @Test func formatSRTMissingSpeakerKeyOmitsPrefix() {
        let segments: [[String: Any]] = [
            ["start": 0.0, "end": 1.0, "text": "No key"],
        ]
        let expected = """
            1
            00:00:00,000 --> 00:00:01,000
            No key

            """
        #expect(TranscriptWriter.formatSRT(segments: segments) == expected)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: same swift test command
Expected: FAIL — `formatSRT` not defined

- [ ] **Step 3: Implement SRT formatting**

Add to `TranscriptWriter`:

```swift
    /// Format segments as SRT subtitle text.
    static func formatSRT(segments: [[String: Any]]) -> String {
        var result = ""
        for (i, seg) in segments.enumerated() {
            let start = formatTimestamp(seg["start"] as? Double ?? 0)
            let end = formatTimestamp(seg["end"] as? Double ?? 0)
            let speaker = seg["speaker"] as? String ?? ""
            let text = seg["text"] as? String ?? ""
            let prefix = speaker.isEmpty ? "" : "\(speaker): "
            result += "\(i + 1)\n\(start) --> \(end)\n\(prefix)\(text)\n\n"
        }
        return result
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: All SRT tests PASS

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/TranscriptWriter.swift SwiftTests/TranscriberTests/TranscriptWriterTests.swift
git commit -m "feat: add SRT formatting to TranscriptWriter"
```

---

### Task 3: TranscriptWriter — TXT Formatting

**Files:**
- Modify: `SwiftTests/TranscriberTests/TranscriptWriterTests.swift`
- Modify: `TranscriberCore/TranscriptWriter.swift`

- [ ] **Step 1: Write failing tests for TXT formatting**

Append to `TranscriptWriterTests`:

```swift
    // MARK: - TXT formatting

    @Test func formatTXTMultipleSegments() {
        let segments: [[String: Any]] = [
            ["start": 8.039, "speaker": "Alice", "text": "Hello"],
            ["start": 11.959, "speaker": "Bob", "text": "Hi there"],
        ]
        let expected = "[00:00:08] Alice: Hello\n[00:00:11] Bob: Hi there\n"
        #expect(TranscriptWriter.formatTXT(segments: segments) == expected)
    }

    @Test func formatTXTEmptySpeakerOmitsPrefix() {
        let segments: [[String: Any]] = [
            ["start": 0.0, "speaker": "", "text": "No speaker"],
        ]
        #expect(TranscriptWriter.formatTXT(segments: segments) == "[00:00:00] No speaker\n")
    }

    @Test func formatTXTMissingSpeakerKeyOmitsPrefix() {
        let segments: [[String: Any]] = [
            ["start": 0.0, "text": "No key"],
        ]
        #expect(TranscriptWriter.formatTXT(segments: segments) == "[00:00:00] No key\n")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `formatTXT` not defined

- [ ] **Step 3: Implement TXT formatting**

Add to `TranscriptWriter`:

```swift
    /// Format segments as plain text with timestamps.
    static func formatTXT(segments: [[String: Any]]) -> String {
        var result = ""
        for seg in segments {
            let ts = formatTimestampShort(seg["start"] as? Double ?? 0)
            let speaker = seg["speaker"] as? String ?? ""
            let text = seg["text"] as? String ?? ""
            let prefix = speaker.isEmpty ? "" : "\(speaker): "
            result += "[\(ts)] \(prefix)\(text)\n"
        }
        return result
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: All TXT tests PASS

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/TranscriptWriter.swift SwiftTests/TranscriberTests/TranscriptWriterTests.swift
git commit -m "feat: add TXT formatting to TranscriptWriter"
```

---

### Task 4: TranscriptWriter — writeFormatFile (file I/O)

**Files:**
- Modify: `SwiftTests/TranscriberTests/TranscriptWriterTests.swift`
- Modify: `TranscriberCore/TranscriptWriter.swift`

- [ ] **Step 1: Write failing tests for writeFormatFile**

Append to `TranscriptWriterTests`:

```swift
    // MARK: - writeFormatFile

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-test-\(UUID().uuidString)")
    }

    private func createJSON(in dir: URL, metadata: [String: Any], segments: [[String: Any]]) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json: [String: Any] = ["metadata": metadata, "segments": segments]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let path = dir.appendingPathComponent("test.json")
        try data.write(to: path)
        return path
    }

    @Test func writeFormatFileSRT() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let segments: [[String: Any]] = [
            ["start": 1.0, "end": 2.0, "speaker": "Alice", "text": "Hello"],
        ]
        let jsonPath = try createJSON(in: dir, metadata: ["output_format": "srt"], segments: segments)

        try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)

        let srtPath = dir.appendingPathComponent("test.srt")
        let content = try String(contentsOf: srtPath, encoding: .utf8)
        #expect(content.contains("Alice: Hello"))
        #expect(content.contains("00:00:01,000 --> 00:00:02,000"))
    }

    @Test func writeFormatFileTXT() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let segments: [[String: Any]] = [
            ["start": 1.0, "end": 2.0, "speaker": "Bob", "text": "Hi"],
        ]
        let jsonPath = try createJSON(in: dir, metadata: ["output_format": "txt"], segments: segments)

        try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)

        let txtPath = dir.appendingPathComponent("test.txt")
        let content = try String(contentsOf: txtPath, encoding: .utf8)
        #expect(content == "[00:00:01] Bob: Hi\n")
    }

    @Test func writeFormatFileJSONIsNoop() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let jsonPath = try createJSON(in: dir, metadata: ["output_format": "json"], segments: [])

        try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)

        // No extra file should be created
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(contents.count == 1) // only the .json
    }

    @Test func writeFormatFileReflectsRenamedSpeakers() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let segments: [[String: Any]] = [
            ["start": 0.0, "end": 1.0, "speaker": "Frederic", "text": "Hello"],
            ["start": 1.0, "end": 2.0, "speaker": "Remote Speaker 1", "text": "Hi"],
        ]
        let jsonPath = try createJSON(in: dir, metadata: ["output_format": "srt"], segments: segments)

        try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)

        let srtPath = dir.appendingPathComponent("test.srt")
        let content = try String(contentsOf: srtPath, encoding: .utf8)
        #expect(content.contains("Frederic: Hello"))
        #expect(content.contains("Remote Speaker 1: Hi"))
    }

    @Test func writeFormatFileMissingFormatDefaultsToNoOp() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let jsonPath = try createJSON(in: dir, metadata: [:], segments: [])

        try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)

        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(contents.count == 1) // only the .json
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `writeFormatFile` not defined

- [ ] **Step 3: Implement writeFormatFile**

Add to `TranscriptWriter`:

```swift
    enum WriterError: Error {
        case invalidJSON
    }

    /// Generate a format file (.srt or .txt) from a JSON transcript.
    /// Reads segments and output_format from the JSON metadata.
    /// Writes the format file alongside the JSON (same directory, same base name).
    /// No-op if output_format is "json" or missing.
    static func writeFormatFile(fromJSON jsonPath: URL) throws {
        let data = try Data(contentsOf: jsonPath)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = json["segments"] as? [[String: Any]],
              let metadata = json["metadata"] as? [String: Any]
        else { throw WriterError.invalidJSON }

        let format = metadata["output_format"] as? String ?? "json"
        guard format != "json" else { return }

        let content: String
        switch format {
        case "srt":
            content = formatSRT(segments: segments)
        case "txt":
            content = formatTXT(segments: segments)
        default:
            return
        }

        let outputPath = jsonPath.deletingPathExtension().appendingPathExtension(format)
        try content.write(to: outputPath, atomically: true, encoding: .utf8)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: All writeFormatFile tests PASS

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/TranscriptWriter.swift SwiftTests/TranscriberTests/TranscriptWriterTests.swift
git commit -m "feat: add writeFormatFile to generate SRT/TXT from JSON"
```

---

### Task 5: Wire RenameWindowController to generate format file

**Files:**
- Modify: `TranscriberApp/Services/RenameWindowController.swift:13-34` (show method callbacks)

- [ ] **Step 1: Update onSave callback to generate format file after rename**

In `RenameWindowController.show(jsonPath:)`, change the `onSave` closure:

```swift
        let dialog = RenameDialog(
            jsonPath: jsonPath,
            speakers: speakers,
            onSave: { mapping in
                Self.applySpeakerRenames(mapping, jsonPath: jsonPath)
                Self.generateFormatFile(jsonPath: jsonPath)
                closePanel()
            },
            onCancel: {
                Self.generateFormatFile(jsonPath: jsonPath)
                closePanel()
            }
        )
```

- [ ] **Step 2: Add generateFormatFile helper**

Add after `applySpeakerRenames`:

```swift
    static func generateFormatFile(jsonPath: URL) {
        do {
            try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)
            let format = Self.readOutputFormat(from: jsonPath) ?? "json"
            if format != "json" {
                let outputPath = jsonPath.deletingPathExtension().appendingPathExtension(format)
                Logger.files.info("Format file written: \(outputPath.lastPathComponent, privacy: .public)")
            }
        } catch {
            Logger.files.error("Failed to write format file: \(error, privacy: .public)")
        }
    }

    private static func readOutputFormat(from jsonPath: URL) -> String? {
        guard let data = try? Data(contentsOf: jsonPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = json["metadata"] as? [String: Any]
        else { return nil }
        return metadata["output_format"] as? String
    }
```

- [ ] **Step 3: Remove the old onCancel inline closure**

The `onCancel` closure used to just close the panel. Now it also generates the format file before closing. The `closePanel` block (lines 20-24) stays as-is — it's called after format generation.

- [ ] **Step 4: Build to verify compilation**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 5: Commit**

```bash
git add TranscriberApp/Services/RenameWindowController.swift
git commit -m "feat: generate format file on rename save and cancel"
```

---

### Task 6: Simplify TranscriptionRunner to always output JSON

**Files:**
- Modify: `TranscriberApp/Services/TranscriptionRunner.swift`
- Modify: `TranscriberApp/Views/MenuView.swift:125-153` (stopRecording)

- [ ] **Step 1: Simplify TranscriptionResult and run() signature**

In `TranscriptionRunner.swift`, change `TranscriptionResult`:

```swift
struct TranscriptionResult {
    let jsonPath: URL
}
```

Change `run()` signature — remove `outputFormat` parameter:

```swift
    func run(
        systemAudio: URL,
        micAudio: URL?,
        outputDirectory: URL,
        hfToken: String = ""
    ) async throws -> TranscriptionResult {
```

- [ ] **Step 2: Hardcode `-f json` in arguments and simplify return**

Replace lines 47-49 (outputFile computation) and line 58 (`-f outputFormat`):

```swift
        var arguments = [
            transcribeScript.path,
            "-i", systemAudio.path,
        ]
        if let mic = micAudio {
            arguments += ["-i", mic.path]
        }
        arguments += ["-f", "json"]

        let baseName = systemAudio.deletingPathExtension().lastPathComponent
        let jsonFile = outputDirectory.appendingPathComponent(baseName + ".json")
        arguments += ["-o", jsonFile.path]
```

Update the log line:

```swift
        Logger.transcription.info("Launching transcription — format: json, inputs: \(inputCount)")
```

Simplify the return in the termination handler:

```swift
                cont.resume(returning: TranscriptionResult(
                    jsonPath: jsonFile
                ))
```

Remove the `let jsonFile = outputDirectory...` line that was previously inside the termination handler (lines 142-143) — it's now defined above.

- [ ] **Step 3: Update MenuView.stopRecording()**

In `MenuView.swift`, change the `stopRecording()` method:

```swift
    private func stopRecording() async {
        Logger.state.info("Recording stopped")
        do {
            let paths = try await captureClient.stop()
            appState.phase = .transcribing(progress: "Transcribing...")

            let config = configManager.config
            let result = try await transcriptionRunner.run(
                systemAudio: paths.systemAudio,
                micAudio: paths.micAudio,
                outputDirectory: paths.systemAudio.deletingLastPathComponent(),
                hfToken: config.hfToken
            )

            appState.lastJsonPath = result.jsonPath.path
            appState.lastTranscriptPath = result.jsonPath.path
            appState.phase = .idle
            sendNotification(title: "Transcription Complete", body: result.jsonPath.lastPathComponent)

            RenameWindowController.shared.show(jsonPath: result.jsonPath)
        } catch {
            appState.errorMessage = error.localizedDescription
            sendNotification(title: "Transcription Failed", body: error.localizedDescription)
            appState.phase = .idle
        }
    }
```

- [ ] **Step 4: Build to verify compilation**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 5: Run all tests**

Run: `swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add TranscriberApp/Services/TranscriptionRunner.swift TranscriberApp/Views/MenuView.swift
git commit -m "refactor: TranscriptionRunner always outputs JSON, format file derived by Swift"
```

---

### Task 7: Update test checklist

**Files:**
- Modify: `scripts/test-checklist.md`

- [ ] **Step 1: Add test cases for JSON-first format generation**

Add to the test checklist:

```markdown
## Format File Generation
- [ ] Record with output_format=srt → rename speakers → save → .srt has renamed speakers
- [ ] Record with output_format=srt → rename dialog → cancel → .srt has original speakers
- [ ] Record with output_format=txt → rename speakers → save → .txt has renamed speakers
- [ ] Record with output_format=json → rename dialog → save → no extra file created
- [ ] Manual "Rename Speakers..." → save → format file updated with new names
```

- [ ] **Step 2: Commit**

```bash
git add scripts/test-checklist.md
git commit -m "docs: add format file generation test cases to checklist"
```
