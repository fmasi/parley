# Audio Chunk Concatenation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Concatenate per-chunk `.m4a` files into a single archive at the end of a chunked recording session, controlled by a `merge_chunked_audio` config flag.

**Architecture:** A new `AudioConcatenator` in `TranscriberCore` uses `AVMutableComposition` to stitch N stereo AAC `.m4a` chunks into a single file, exporting via `AVAssetExportSession` with `AVAssetExportPresetPassthrough` (falling back to `AVAssetExportPresetAppleM4A` on failure). `TranscriptionRunner.finalize()` calls it between step 5 (collect audio paths) and step 7 (assemble transcript JSON), so the JSON's `audio_paths` always reflects the final state. Single-chunk recordings skip concatenation entirely.

**Tech Stack:** Swift, AVFoundation (`AVMutableComposition`, `AVAssetExportSession`, `AVAssetReader`), Swift Testing

---

## Files

| Action | Path | Purpose |
|--------|------|---------|
| Create | `TranscriberCore/AudioConcatenator.swift` | Concatenation logic, passthrough + fallback |
| Create | `SwiftTests/TranscriberTests/AudioConcatenatorTests.swift` | Tests for all concatenation behaviours |
| Modify | `TranscriberCore/Config.swift` | Add `mergeChunkedAudio: Bool` field |
| Modify | `TranscriberApp/Services/TranscriptionRunner.swift` | Call concatenator in `finalize()` |
| Modify | `docs/parameters.md` | Document `merge_chunked_audio` |

---

## Task 1: Add `merge_chunked_audio` to Config

**Files:**
- Modify: `TranscriberCore/Config.swift`

The config follows a strict pattern: property → `CodingKeys` entry → default in `init(from:)` → value in `default` static. All four locations must be updated together.

- [ ] **Step 1: Add the property**

In `Config.swift`, in the `public struct Config` body alongside the other `public var` fields (near `chunkDurationMinutes`):

```swift
public var mergeChunkedAudio: Bool
```

- [ ] **Step 2: Add the CodingKey**

In the `enum CodingKeys` inside `Config`, add after `case chunkProcessingQos`:

```swift
case mergeChunkedAudio = "merge_chunked_audio"
```

- [ ] **Step 3: Add the decoder line**

In `public init(from decoder: Decoder) throws`, add after the `chunkProcessingQos` decode line:

```swift
mergeChunkedAudio = try c.decodeIfPresent(Bool.self, forKey: .mergeChunkedAudio) ?? true
```

- [ ] **Step 4: Add to the `default` static**

In `public static let default = Config(...)`, add after `chunkProcessingQos: "utility"`:

```swift
mergeChunkedAudio: true,
```

Also add the parameter to `Config`'s memberwise initialiser (the `public init(...)` that lists all fields), after `chunkProcessingQos: String`:

```swift
mergeChunkedAudio: Bool = true,
```

And in the `init` body:

```swift
self.mergeChunkedAudio = mergeChunkedAudio
```

- [ ] **Step 5: Run Config tests**

```bash
cd /Users/fmasi/Git/Transcriber/.worktrees/v0.7.x && \
swift test --filter ConfigTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ \
  2>&1 | tail -20
```

Expected: all existing ConfigTests pass (new field has a default so no existing JSON breaks).

- [ ] **Step 6: Commit**

```bash
git add TranscriberCore/Config.swift
git commit -m "feat: add merge_chunked_audio config flag (default true)"
```

---

## Task 2: Implement AudioConcatenator

**Files:**
- Create: `TranscriberCore/AudioConcatenator.swift`

- [ ] **Step 1: Write the failing test first** (see Task 3 — write tests before implementation)

Skip ahead to Task 3, write the tests, run them to confirm they fail with "no such module" or "cannot find type", then return here.

- [ ] **Step 2: Create the file**

`TranscriberCore/AudioConcatenator.swift`:

```swift
import AVFoundation
import os

// MARK: - Public types

public struct AudioConcatenationResult: Sendable {
    public let outputPath: URL
    /// True if AVFoundation used passthrough (no re-encode). False if it fell back to AAC re-encode.
    public let usedPassthrough: Bool
}

public enum AudioConcatenatorError: LocalizedError {
    case noSources
    case cannotLoadTrack(String)
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSources: return "No source files provided"
        case .cannotLoadTrack(let msg): return "Cannot load audio track: \(msg)"
        case .exportFailed(let msg): return "Export failed: \(msg)"
        }
    }
}

// MARK: - AudioConcatenator

/// Stitches N stereo AAC .m4a files into a single .m4a using AVMutableComposition.
/// Attempts lossless passthrough export first; falls back to AAC re-encode if passthrough fails.
/// Single-source input is a no-op (returns the source path unchanged).
public enum AudioConcatenator {

    /// Concatenate `sources` into a single .m4a at `outputDirectory/<outputName>.m4a`.
    /// Deletes source files on success (when sources.count > 1).
    /// - Parameters:
    ///   - sources: Ordered list of .m4a files to concatenate.
    ///   - outputDirectory: Directory to write the output file.
    ///   - outputName: Base name for the output file (without extension).
    /// - Returns: `AudioConcatenationResult` with the output path and whether passthrough was used.
    public static func concatenate(
        sources: [URL],
        outputDirectory: URL,
        outputName: String
    ) async throws -> AudioConcatenationResult {
        guard !sources.isEmpty else { throw AudioConcatenatorError.noSources }

        // Single source: nothing to stitch.
        if sources.count == 1 {
            return AudioConcatenationResult(outputPath: sources[0], usedPassthrough: true)
        }

        let outputURL = outputDirectory.appendingPathComponent("\(outputName).m4a")
        try? FileManager.default.removeItem(at: outputURL)

        // Build composition
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioConcatenatorError.exportFailed("Cannot add composition track")
        }

        var insertTime = CMTime.zero
        for source in sources {
            let asset = AVURLAsset(url: source)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else {
                throw AudioConcatenatorError.cannotLoadTrack(source.lastPathComponent)
            }
            let duration = try await asset.load(.duration)
            let timeRange = CMTimeRange(start: .zero, duration: duration)
            try compositionTrack.insertTimeRange(timeRange, of: track, at: insertTime)
            insertTime = CMTimeAdd(insertTime, duration)
        }

        // Try passthrough first
        if let result = try? await export(
            composition: composition,
            to: outputURL,
            preset: AVAssetExportPresetPassthrough,
            fileType: .m4a
        ) {
            try deleteSources(sources)
            Logger.files.info("AudioConcatenator: passthrough export succeeded → \(outputURL.lastPathComponent, privacy: .public)")
            return AudioConcatenationResult(outputPath: result, usedPassthrough: true)
        }

        // Passthrough failed — re-encode with AAC
        Logger.files.info("AudioConcatenator: passthrough failed, falling back to AAC re-encode")
        try? FileManager.default.removeItem(at: outputURL)
        let result = try await export(
            composition: composition,
            to: outputURL,
            preset: AVAssetExportPresetAppleM4A,
            fileType: .m4a
        )
        try deleteSources(sources)
        Logger.files.info("AudioConcatenator: re-encode succeeded → \(outputURL.lastPathComponent, privacy: .public)")
        return AudioConcatenationResult(outputPath: result, usedPassthrough: false)
    }

    // MARK: - Private

    private static func export(
        composition: AVMutableComposition,
        to outputURL: URL,
        preset: String,
        fileType: AVFileType
    ) async throws -> URL {
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw AudioConcatenatorError.exportFailed("Cannot create export session for preset \(preset)")
        }
        session.outputURL = outputURL
        session.outputFileType = fileType

        await session.export()

        if session.status == .failed {
            let msg = session.error?.localizedDescription ?? "unknown error"
            throw AudioConcatenatorError.exportFailed("\(preset): \(msg)")
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw AudioConcatenatorError.exportFailed("\(preset): output file missing after export")
        }
        return outputURL
    }

    private static func deleteSources(_ sources: [URL]) throws {
        for url in sources {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
```

- [ ] **Step 3: Build**

```bash
cd /Users/fmasi/Git/Transcriber/.worktrees/v0.7.x && swift build 2>&1 | grep -E 'error:|warning:|Build complete'
```

Expected: `Build complete!`

---

## Task 3: Write and run AudioConcatenator tests

**Files:**
- Create: `SwiftTests/TranscriberTests/AudioConcatenatorTests.swift`

The tests use real AVFoundation I/O (same pattern as `AudioArchiverTests.swift`). Each test creates temporary `.m4a` files using `AVAssetWriter`, runs the concatenator, and verifies file system and audio track state.

- [ ] **Step 1: Create the test file**

`SwiftTests/TranscriberTests/AudioConcatenatorTests.swift`:

```swift
import Testing
import Foundation
import AVFoundation
@testable import TranscriberCore

struct AudioConcatenatorTests {

    // MARK: - Helpers

    /// Creates a stereo AAC .m4a of `durationSeconds` at 48kHz with a sine tone.
    private static func createTestM4a(
        at url: URL,
        frequency: Double = 440.0,
        durationSeconds: Double = 1.0
    ) throws {
        let sampleRate: Double = 48_000
        let frameCount = Int(sampleRate * durationSeconds)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        )!

        // Encode WAV → AAC via AVAssetWriter
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 64_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let blockSize = 4096
        var frameOffset = 0
        while frameOffset < frameCount {
            guard input.isReadyForMoreMediaData else {
                await Task.yield()
                continue
            }
            let framesToProcess = min(blockSize, frameCount - frameOffset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(framesToProcess)) else { break }
            buffer.frameLength = AVAudioFrameCount(framesToProcess)
            let left = buffer.floatChannelData![0]
            let right = buffer.floatChannelData![1]
            for i in 0..<framesToProcess {
                let sample = Float(sin(2.0 * .pi * frequency * Double(frameOffset + i) / sampleRate))
                left[i] = sample
                right[i] = sample
            }
            var sampleBuffer: CMSampleBuffer?
            var formatDesc: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDesc)
            let pts = CMTime(value: CMTimeValue(frameOffset), timescale: CMTimeScale(sampleRate))
            CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDesc, sampleCount: CMItemCount(framesToProcess), sampleTimingEntryCount: 1, sampleTimingArray: [CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)), presentationTimeStamp: pts, decodeTimeStamp: .invalid)], sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
            if let buf = sampleBuffer {
                try buffer.copy(to: buf)
                input.append(buf)
            }
            frameOffset += framesToProcess
        }
        input.markAsFinished()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writer.finishWriting { c.resume() }
        }
    }

    // MARK: - Tests

    @Test func singleSourceIsNoOp() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("concat-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("chunk-0.m4a")
        try await Self.createTestM4a(at: source, durationSeconds: 1.0)

        let result = try await AudioConcatenator.concatenate(
            sources: [source],
            outputDirectory: dir,
            outputName: "merged"
        )

        // Should return the original file, not create a new one
        #expect(result.outputPath == source)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(result.usedPassthrough == true)
    }

    @Test func concatenatesMultipleSourcesIntoSingleFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("concat-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let chunk0 = dir.appendingPathComponent("session-0.m4a")
        let chunk1 = dir.appendingPathComponent("session-1.m4a")
        let chunk2 = dir.appendingPathComponent("session-2.m4a")
        try await Self.createTestM4a(at: chunk0, frequency: 220, durationSeconds: 1.0)
        try await Self.createTestM4a(at: chunk1, frequency: 440, durationSeconds: 1.0)
        try await Self.createTestM4a(at: chunk2, frequency: 880, durationSeconds: 1.0)

        let result = try await AudioConcatenator.concatenate(
            sources: [chunk0, chunk1, chunk2],
            outputDirectory: dir,
            outputName: "session"
        )

        #expect(result.outputPath.lastPathComponent == "session.m4a")
        #expect(FileManager.default.fileExists(atPath: result.outputPath.path))

        // Output has an audio track
        let asset = AVURLAsset(url: result.outputPath)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(!tracks.isEmpty)
    }

    @Test func sourceFilesDeletedAfterConcatenation() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("concat-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let chunk0 = dir.appendingPathComponent("s-0.m4a")
        let chunk1 = dir.appendingPathComponent("s-1.m4a")
        try await Self.createTestM4a(at: chunk0, durationSeconds: 1.0)
        try await Self.createTestM4a(at: chunk1, durationSeconds: 1.0)

        let result = try await AudioConcatenator.concatenate(
            sources: [chunk0, chunk1],
            outputDirectory: dir,
            outputName: "s"
        )

        #expect(!FileManager.default.fileExists(atPath: chunk0.path))
        #expect(!FileManager.default.fileExists(atPath: chunk1.path))
        #expect(FileManager.default.fileExists(atPath: result.outputPath.path))
    }

    @Test func concatenatedDurationApproximatelySumOfSources() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("concat-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let chunk0 = dir.appendingPathComponent("dur-0.m4a")
        let chunk1 = dir.appendingPathComponent("dur-1.m4a")
        try await Self.createTestM4a(at: chunk0, durationSeconds: 2.0)
        try await Self.createTestM4a(at: chunk1, durationSeconds: 3.0)

        let result = try await AudioConcatenator.concatenate(
            sources: [chunk0, chunk1],
            outputDirectory: dir,
            outputName: "dur"
        )

        let asset = AVURLAsset(url: result.outputPath)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        // Allow ±0.5s tolerance for AAC encoder delay at chunk boundaries
        #expect(seconds >= 4.5 && seconds <= 5.5)
    }

    @Test func emptySourcesThrows() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("concat-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            _ = try await AudioConcatenator.concatenate(
                sources: [],
                outputDirectory: dir,
                outputName: "empty"
            )
            Issue.record("Expected concatenate to throw on empty sources")
        } catch AudioConcatenatorError.noSources {
            // expected
        }
    }
}
```

- [ ] **Step 2: Run tests**

```bash
cd /Users/fmasi/Git/Transcriber/.worktrees/v0.7.x && \
swift test --filter AudioConcatenatorTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ \
  2>&1 | tail -30
```

Expected: all 5 tests pass. If `createTestM4a` hits an issue with `CMSampleBuffer` creation (it's verbose), it's acceptable to simplify it by writing a WAV first then using `AudioArchiver` to get a real `.m4a` — but try the direct path first.

- [ ] **Step 3: Commit**

```bash
git add TranscriberCore/AudioConcatenator.swift SwiftTests/TranscriberTests/AudioConcatenatorTests.swift
git commit -m "feat: AudioConcatenator — stitch chunk m4a files via AVMutableComposition passthrough"
```

---

## Task 4: Wire concatenation into TranscriptionRunner.finalize()

**Files:**
- Modify: `TranscriberApp/Services/TranscriptionRunner.swift`

The `finalize()` method currently ends with step 10 (delete session.json). A new step 5b goes between step 5 (collect audio paths) and step 7 (assemble JSON), so the JSON always reflects the final unified path.

- [ ] **Step 1: Replace the audio paths block in finalize()**

Find the comment `// 5. Audio paths from chunks` in `finalize()`. The current code is:

```swift
// 5. Audio paths from chunks
let audioPaths = sessionState.chunks.map {
    outputDirectory.appendingPathComponent($0.audioPath)
}
```

Replace with:

```swift
// 5. Audio paths from chunks
let chunkAudioPaths = sessionState.chunks.map {
    outputDirectory.appendingPathComponent($0.audioPath)
}

// 5b. Concatenate chunk audio files into a single archive (if enabled and more than 1 chunk)
let audioPaths: [URL]
if config.mergeChunkedAudio && chunkAudioPaths.count > 1 {
    do {
        let concatResult = try await AudioConcatenator.concatenate(
            sources: chunkAudioPaths,
            outputDirectory: outputDirectory,
            outputName: sessionState.sessionId
        )
        audioPaths = [concatResult.outputPath]
        Logger.files.info(
            "Concatenated \(chunkAudioPaths.count, privacy: .public) chunks → \(concatResult.outputPath.lastPathComponent, privacy: .public) (passthrough: \(concatResult.usedPassthrough, privacy: .public))"
        )
    } catch {
        Logger.files.error("Audio concatenation failed, keeping separate files: \(error, privacy: .public)")
        audioPaths = chunkAudioPaths
    }
} else {
    audioPaths = chunkAudioPaths
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/fmasi/Git/Transcriber/.worktrees/v0.7.x && swift build 2>&1 | grep -E 'error:|Build complete'
```

Expected: `Build complete!`

- [ ] **Step 3: Run the full test suite**

```bash
cd /Users/fmasi/Git/Transcriber/.worktrees/v0.7.x && \
swift test --filter TranscriberTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ \
  2>&1 | tail -20
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add TranscriberApp/Services/TranscriptionRunner.swift
git commit -m "feat: concatenate chunk audio files in finalize() when merge_chunked_audio=true"
```

---

## Task 5: Document the new config key

**Files:**
- Modify: `docs/parameters.md`

- [ ] **Step 1: Add entry**

In `docs/parameters.md`, find the section covering audio archive parameters (near `archive_bitrate_kbps`, `audio_archive_limit_hours`). Add the following entry in the same table or list style already used:

```
| `merge_chunked_audio` | bool | `true` | When true, concatenates per-chunk `.m4a` files into a single archive at the end of a chunked session. Uses AVFoundation passthrough (lossless) where possible, falls back to AAC re-encode. Set to `false` to keep individual chunk files. |
```

- [ ] **Step 2: Commit**

```bash
git add docs/parameters.md
git commit -m "docs: document merge_chunked_audio config key"
```

---

## Self-Review

**Spec coverage:**
- ✅ `AVMutableComposition` + passthrough export — implemented in `AudioConcatenator`
- ✅ Passthrough fallback to re-encode — implemented with two `export()` calls
- ✅ Config flag `merge_chunked_audio` — added to `Config.swift` with snake_case JSON key
- ✅ Single-chunk no-op — handled in `concatenate()` early return
- ✅ Source files deleted after success — `deleteSources()` called after both export paths
- ✅ Wired into `finalize()` between audio path collection and JSON assembly
- ✅ Tests for: no-op, multi-file output, source deletion, duration, empty input
- ✅ Documented in `parameters.md`

**Placeholder scan:** None found.

**Type consistency:**
- `AudioConcatenationResult` defined in Task 2, used in Task 4 ✅
- `AudioConcatenatorError.noSources` defined in Task 2, caught in test Task 3 ✅
- `config.mergeChunkedAudio` field defined in Task 1, used in Task 4 ✅
- `chunkAudioPaths` / `audioPaths` rename in Task 4 is self-contained ✅
