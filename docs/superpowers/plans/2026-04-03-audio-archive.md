# Audio Archive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compress dual-WAV recordings into stereo AAC archives (L=local mic, R=remote system), enforce a storage quota in hours, and make the pipeline format-aware so archived files can be re-ingested.

**Architecture:** Three new components in TranscriberCore — `AudioSourceResolver` (detects input format, splits channels), `AudioArchiver` (WAV→AAC conversion), `StorageManager` (quota enforcement). Config gains two fields (`archive_bitrate_kbps`, `audio_archive_limit_hours`), Settings gets an "Audio Archive" section. The `SCStreamConfiguration` in the XPC service is updated to hardcode 48 kHz system audio. The rename dialog is updated to handle single-file stereo AAC archives.

**Tech Stack:** AVFoundation (AVAssetWriter, AVAssetReader, AVAudioConverter), Swift Testing, TranscriberCore target

**Spec:** `docs/superpowers/specs/2026-04-03-audio-archive-design.md`

---

### Task 1: Config — Add archive fields and deprecate sample_rate

**Files:**
- Modify: `TranscriberCore/Config.swift`
- Modify: `TranscriberCore/ConfigManager.swift`
- Modify: `SwiftTests/TranscriberTests/ConfigTests.swift`

- [ ] **Step 1: Write failing tests for new config fields**

In `SwiftTests/TranscriberTests/ConfigTests.swift`, add:

```swift
@Test func archiveBitrateDefaultsTo64() {
    let config = Config.default
    #expect(config.archiveBitrateKbps == 64)
}

@Test func audioArchiveLimitDefaultsTo15() {
    let config = Config.default
    #expect(config.audioArchiveLimitHours == 15)
}

@Test func archiveFieldsRoundTrip() throws {
    var config = Config.default
    config.archiveBitrateKbps = 128
    config.audioArchiveLimitHours = 24
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(Config.self, from: data)
    #expect(decoded.archiveBitrateKbps == 128)
    #expect(decoded.audioArchiveLimitHours == 24)
}

@Test func archiveFieldsSnakeCaseKeys() throws {
    let config = Config.default
    let data = try JSONEncoder().encode(config)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["archive_bitrate_kbps"] != nil)
    #expect(json["audio_archive_limit_hours"] != nil)
}

@Test func decodesLegacyConfigWithoutArchiveFields() throws {
    let json = """
    {"recording_directory":"/tmp","silence_timeout_minutes":5,"silence_detection_enabled":true,\
    "output_format":"txt","launch_on_startup":true,\
    "suppress_capture_warning":false}
    """
    let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    #expect(config.archiveBitrateKbps == 64)
    #expect(config.audioArchiveLimitHours == 15)
}

@Test func deprecatedSampleRateFieldIsIgnored() throws {
    let json = """
    {"recording_directory":"/tmp","silence_timeout_minutes":5,"silence_detection_enabled":true,\
    "output_format":"txt","launch_on_startup":true,\
    "suppress_capture_warning":false,"sample_rate":44100}
    """
    let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    // Should decode without error — sample_rate is silently ignored
    #expect(config.archiveBitrateKbps == 64)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | grep -E "(FAIL|error:)"`

Expected: Compilation errors — `archiveBitrateKbps` and `audioArchiveLimitHours` don't exist on Config.

- [ ] **Step 3: Add fields to Config.swift**

In `TranscriberCore/Config.swift`, add the two new properties after `vadSpeechThreshold`:

```swift
public var archiveBitrateKbps: Int
public var audioArchiveLimitHours: Int
```

Update `Config.default` to include:
```swift
archiveBitrateKbps: 64,
audioArchiveLimitHours: 15
```

Update `init(...)` to include:
```swift
archiveBitrateKbps: Int = 64,
audioArchiveLimitHours: Int = 15
```

Add to `CodingKeys`:
```swift
case archiveBitrateKbps = "archive_bitrate_kbps"
case audioArchiveLimitHours = "audio_archive_limit_hours"
```

Update `init(from decoder:)` to decode them with defaults:
```swift
archiveBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .archiveBitrateKbps) ?? 64
audioArchiveLimitHours = try c.decodeIfPresent(Int.self, forKey: .audioArchiveLimitHours) ?? 15
```

The `sample_rate` deprecation is a no-op here — `Config` never had a `sampleRate` field in the Swift codebase. The `init(from decoder:)` already ignores unknown keys, so a JSON file with `"sample_rate": 44100` decodes fine.

- [ ] **Step 4: Add deprecation warning in ConfigManager**

In `TranscriberCore/ConfigManager.swift`, update `load(from:)` to check for the deprecated field:

```swift
private static func load(from url: URL) -> Config {
    guard let data = try? Data(contentsOf: url),
          let config = try? JSONDecoder().decode(Config.self, from: data)
    else {
        Logger.config.info("Config not found or invalid, using defaults")
        return .default
    }
    // Warn about deprecated fields
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       json["sample_rate"] != nil {
        Logger.config.warning("Config field 'sample_rate' is deprecated and ignored — system audio is captured at 48 kHz")
    }
    Logger.config.info("Config loaded — format: \(config.outputFormat, privacy: .public), engine: \(config.engine.rawValue, privacy: .public)")
    return config
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -5`

Expected: All tests pass (existing + new).

- [ ] **Step 6: Commit**

```bash
git add TranscriberCore/Config.swift TranscriberCore/ConfigManager.swift SwiftTests/TranscriberTests/ConfigTests.swift
git commit -m "feat: add archive config fields (bitrate, limit hours), deprecation warning for sample_rate"
```

---

### Task 2: Hardcode system audio to 48 kHz in XPC service

**Files:**
- Modify: `AudioCaptureHelper/XPC/AudioCaptureService.swift`

- [ ] **Step 1: Set sampleRate on SCStreamConfiguration**

In `AudioCaptureHelper/XPC/AudioCaptureService.swift`, in the `configureAndStart()` method (around line 180), after `config.channelCount = 1`, add:

```swift
config.sampleRate = 48000
```

Also in `updateMicrophone()` (around line 112), after `config.channelCount = 1`, add:

```swift
config.sampleRate = 48000
```

Add a log line after setting it in `configureAndStart`:
```swift
Logger.audio.debug("System audio capture rate: 48000 Hz (fixed)")
```

- [ ] **Step 2: Verify build succeeds**

Run: `swift build 2>&1 | tail -3`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add AudioCaptureHelper/XPC/AudioCaptureService.swift
git commit -m "feat: hardcode system audio capture to 48 kHz"
```

Note: This cannot be unit tested — `SCStreamConfiguration` requires ScreenCaptureKit entitlements. Manual testing via `dev.py` will validate.

---

### Task 3: AudioSourceResolver — Format detection and channel splitting

**Files:**
- Create: `TranscriberCore/AudioSourceResolver.swift`
- Create: `SwiftTests/TranscriberTests/AudioSourceResolverTests.swift`

- [ ] **Step 1: Write failing tests**

Create `SwiftTests/TranscriberTests/AudioSourceResolverTests.swift`:

```swift
import Testing
import Foundation
@testable import TranscriberCore

struct AudioSourceResolverTests {

    // MARK: - Format detection

    @Test func detectsTwoWavFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let systemPath = dir.appendingPathComponent("meeting.wav")
        let micPath = dir.appendingPathComponent("meeting_mic.wav")
        try Data([0]).write(to: systemPath)
        try Data([0]).write(to: micPath)

        let result = try AudioSourceResolver.detect(baseName: "meeting", in: dir)
        guard case .dualWav(let system, let mic) = result else {
            Issue.record("Expected dualWav, got \(result)")
            return
        }
        #expect(system.lastPathComponent == "meeting.wav")
        #expect(mic.lastPathComponent == "meeting_mic.wav")
    }

    @Test func detectsStereoAac() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let aacPath = dir.appendingPathComponent("meeting.m4a")
        try Data([0]).write(to: aacPath)

        let result = try AudioSourceResolver.detect(baseName: "meeting", in: dir)
        guard case .stereoAac(let path) = result else {
            Issue.record("Expected stereoAac, got \(result)")
            return
        }
        #expect(path.lastPathComponent == "meeting.m4a")
    }

    @Test func prefersWavOverAacWhenBothExist() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let systemPath = dir.appendingPathComponent("meeting.wav")
        let micPath = dir.appendingPathComponent("meeting_mic.wav")
        let aacPath = dir.appendingPathComponent("meeting.m4a")
        try Data([0]).write(to: systemPath)
        try Data([0]).write(to: micPath)
        try Data([0]).write(to: aacPath)

        let result = try AudioSourceResolver.detect(baseName: "meeting", in: dir)
        guard case .dualWav = result else {
            Issue.record("Expected dualWav when both formats exist, got \(result)")
            return
        }
    }

    @Test func throwsWhenNoFilesFound() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: AudioSourceResolverError.self) {
            try AudioSourceResolver.detect(baseName: "missing", in: dir)
        }
    }

    @Test func detectsSystemWavOnlyWhenNoMic() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let systemPath = dir.appendingPathComponent("meeting.wav")
        try Data([0]).write(to: systemPath)

        let result = try AudioSourceResolver.detect(baseName: "meeting", in: dir)
        guard case .singleWav(let path) = result else {
            Issue.record("Expected singleWav, got \(result)")
            return
        }
        #expect(path.lastPathComponent == "meeting.wav")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AudioSourceResolverTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -5`

Expected: Compilation error — `AudioSourceResolver` doesn't exist.

- [ ] **Step 3: Implement AudioSourceResolver**

Create `TranscriberCore/AudioSourceResolver.swift`:

```swift
import Foundation
import os

/// Detected audio source format for a recording.
public enum AudioSourceFormat {
    /// Two separate WAV files: system audio + microphone
    case dualWav(system: URL, mic: URL)
    /// Single WAV file (system audio only, no mic)
    case singleWav(URL)
    /// Single stereo AAC archive: L=local mic, R=remote system
    case stereoAac(URL)
}

public enum AudioSourceResolverError: LocalizedError {
    case noAudioFiles(baseName: String, directory: URL)

    public var errorDescription: String? {
        switch self {
        case .noAudioFiles(let baseName, let directory):
            return "No audio files found for '\(baseName)' in \(directory.path)"
        }
    }
}

/// Detects the audio source format for a recording and provides
/// channel-separated streams to the pipeline.
///
/// Channel convention for stereo AAC:
/// - Left channel = local microphone (the user)
/// - Right channel = remote system audio (other participants)
public enum AudioSourceResolver {

    /// Detect the audio format for a recording base name in a directory.
    /// Prefers dual WAV over stereo AAC when both exist (WAVs are the source of truth).
    public static func detect(baseName: String, in directory: URL) throws -> AudioSourceFormat {
        let fm = FileManager.default
        let systemWav = directory.appendingPathComponent("\(baseName).wav")
        let micWav = directory.appendingPathComponent("\(baseName)_mic.wav")
        let stereoAac = directory.appendingPathComponent("\(baseName).m4a")

        // Prefer dual WAV (original recordings, not yet archived)
        if fm.fileExists(atPath: systemWav.path) && fm.fileExists(atPath: micWav.path) {
            Logger.files.debug("AudioSourceResolver: dual WAV detected for \(baseName, privacy: .public)")
            return .dualWav(system: systemWav, mic: micWav)
        }

        // System WAV only (no mic recording)
        if fm.fileExists(atPath: systemWav.path) {
            Logger.files.debug("AudioSourceResolver: single WAV detected for \(baseName, privacy: .public)")
            return .singleWav(systemWav)
        }

        // Stereo AAC archive
        if fm.fileExists(atPath: stereoAac.path) {
            Logger.files.debug("AudioSourceResolver: stereo AAC detected for \(baseName, privacy: .public)")
            return .stereoAac(stereoAac)
        }

        throw AudioSourceResolverError.noAudioFiles(baseName: baseName, directory: directory)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AudioSourceResolverTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -5`

Expected: All 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/AudioSourceResolver.swift SwiftTests/TranscriberTests/AudioSourceResolverTests.swift
git commit -m "feat: AudioSourceResolver — detect dual WAV, single WAV, or stereo AAC input"
```

---

### Task 4: AudioSourceResolver — Stereo AAC channel splitting

**Files:**
- Modify: `TranscriberCore/AudioSourceResolver.swift`
- Create: `SwiftTests/TranscriberTests/AudioSourceResolverSplitTests.swift`

This task adds the `splitChannels` method that extracts L/R from a stereo AAC into two temp WAV files for pipeline consumption.

- [ ] **Step 1: Write failing test**

Create `SwiftTests/TranscriberTests/AudioSourceResolverSplitTests.swift`:

```swift
import Testing
import Foundation
import AVFoundation
@testable import TranscriberCore

struct AudioSourceResolverSplitTests {

    /// Helper: create a stereo WAV file with distinct L/R content.
    /// L channel = 440 Hz sine (mic/local), R channel = 880 Hz sine (system/remote)
    private static func createTestStereoWav(at url: URL, durationSeconds: Double = 1.0, sampleRate: Double = 48000) throws {
        let frameCount = Int(sampleRate * durationSeconds)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        )!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw TestHelperError.cannotCreateBuffer
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        let leftPtr = buffer.floatChannelData![0]
        let rightPtr = buffer.floatChannelData![1]
        for i in 0..<frameCount {
            let t = Double(i) / sampleRate
            leftPtr[i] = Float(sin(2.0 * .pi * 440.0 * t))   // L = 440 Hz
            rightPtr[i] = Float(sin(2.0 * .pi * 880.0 * t))   // R = 880 Hz
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    /// Helper: create stereo AAC by converting a stereo WAV.
    private static func createTestStereoAac(at aacURL: URL, sampleRate: Double = 48000) throws {
        let wavURL = aacURL.deletingPathExtension().appendingPathExtension("tmp.wav")
        try createTestStereoWav(at: wavURL, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let asset = AVAsset(url: wavURL)
        let reader = try AVAssetReader(asset: asset)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw TestHelperError.noAudioTrack
        }
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: sampleRate,
        ])
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: aacURL, fileType: .m4a)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: sampleRate,
            AVEncoderBitRateKey: 64000,
        ])
        writer.add(writerInput)

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        group.enter()
        writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "test-encode")) {
            while writerInput.isReadyForMoreMediaData {
                if let sample = readerOutput.copyNextSampleBuffer() {
                    writerInput.append(sample)
                } else {
                    writerInput.markAsFinished()
                    group.leave()
                    return
                }
            }
        }
        group.wait()
        writer.finishWriting {}
        // Wait for writer to finish
        while writer.status == .writing {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    enum TestHelperError: Error {
        case cannotCreateBuffer
        case noAudioTrack
    }

    @Test func splitChannelsCreatesTwoFiles() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("split-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let aacPath = dir.appendingPathComponent("test.m4a")
        try Self.createTestStereoAac(at: aacPath)

        let (localPath, remotePath) = try await AudioSourceResolver.splitChannels(stereoAac: aacPath, outputDirectory: dir)

        #expect(FileManager.default.fileExists(atPath: localPath.path))
        #expect(FileManager.default.fileExists(atPath: remotePath.path))
        #expect(localPath.pathExtension == "wav")
        #expect(remotePath.pathExtension == "wav")

        // Verify mono
        let localFile = try AVAudioFile(forReading: localPath)
        let remoteFile = try AVAudioFile(forReading: remotePath)
        #expect(localFile.processingFormat.channelCount == 1)
        #expect(remoteFile.processingFormat.channelCount == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AudioSourceResolverSplitTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -5`

Expected: Compilation error — `splitChannels` doesn't exist.

- [ ] **Step 3: Implement splitChannels**

Add to `TranscriberCore/AudioSourceResolver.swift`:

```swift
import AVFoundation

// Add to the AudioSourceResolver enum:

/// Split a stereo AAC file into two mono WAV files.
/// Returns (local mic, remote system) paths.
/// L channel → local mic, R channel → remote system.
public static func splitChannels(
    stereoAac: URL,
    outputDirectory: URL
) async throws -> (local: URL, remote: URL) {
    let baseName = stereoAac.deletingPathExtension().lastPathComponent
    let localPath = outputDirectory.appendingPathComponent("\(baseName)_split_mic.wav")
    let remotePath = outputDirectory.appendingPathComponent("\(baseName)_split_system.wav")

    let asset = AVAsset(url: stereoAac)
    let reader = try AVAssetReader(asset: asset)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
        throw AudioSourceResolverError.noAudioFiles(baseName: baseName, directory: outputDirectory)
    }

    let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsBigEndianKey: false,
        AVNumberOfChannelsKey: 2,
    ]
    let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
    reader.add(readerOutput)
    reader.startReading()

    // Detect sample rate from track
    let descriptions = try await track.load(.formatDescriptions)
    let sampleRate: Double
    if let desc = descriptions.first {
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
        sampleRate = asbd?.pointee.mSampleRate ?? 48000
    } else {
        sampleRate = 48000
    }

    let localWriter = WavFileWriter(path: localPath.path)
    let remoteWriter = WavFileWriter(path: remotePath.path)
    localWriter.setSampleRate(UInt32(sampleRate))
    localWriter.setChannelCount(1)
    remoteWriter.setSampleRate(UInt32(sampleRate))
    remoteWriter.setChannelCount(1)

    while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        data.withUnsafeMutableBytes { rawPtr in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: rawPtr.baseAddress!)
        }

        // Deinterleave stereo Int16: [L0, R0, L1, R1, ...] → separate L and R
        let sampleCount = length / MemoryLayout<Int16>.size
        let frameCount = sampleCount / 2
        data.withUnsafeBytes { rawPtr in
            let int16Ptr = rawPtr.bindMemory(to: Int16.self)
            var leftSamples = [Int16](repeating: 0, count: frameCount)
            var rightSamples = [Int16](repeating: 0, count: frameCount)
            for i in 0..<frameCount {
                leftSamples[i] = int16Ptr[i * 2]       // L = local mic
                rightSamples[i] = int16Ptr[i * 2 + 1]  // R = remote system
            }
            localWriter.appendInt16(leftSamples)
            remoteWriter.appendInt16(rightSamples)
        }
    }

    localWriter.finalize()
    remoteWriter.finalize()

    Logger.files.info("Split stereo AAC into L=\(localPath.lastPathComponent, privacy: .public), R=\(remotePath.lastPathComponent, privacy: .public)")
    return (local: localPath, remote: remotePath)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AudioSourceResolverSplitTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -5`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/AudioSourceResolver.swift SwiftTests/TranscriberTests/AudioSourceResolverSplitTests.swift
git commit -m "feat: AudioSourceResolver.splitChannels — extract L/R from stereo AAC to mono WAVs"
```

---

### Task 5: AudioArchiver — WAV to stereo AAC conversion

**Files:**
- Create: `TranscriberCore/AudioArchiver.swift`
- Create: `SwiftTests/TranscriberTests/AudioArchiverTests.swift`

- [ ] **Step 1: Write failing tests**

Create `SwiftTests/TranscriberTests/AudioArchiverTests.swift`:

```swift
import Testing
import Foundation
import AVFoundation
@testable import TranscriberCore

struct AudioArchiverTests {

    /// Helper: create a mono 48kHz WAV file with a sine wave.
    private static func createTestWav(at url: URL, frequency: Double = 440.0, durationSeconds: Double = 1.0) throws {
        let sampleRate: Double = 48000
        let frameCount = Int(sampleRate * durationSeconds)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw ArchiverTestError.cannotCreateBuffer
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let ptr = buffer.floatChannelData![0]
        for i in 0..<frameCount {
            ptr[i] = Float(sin(2.0 * .pi * frequency * Double(i) / sampleRate))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    enum ArchiverTestError: Error {
        case cannotCreateBuffer
    }

    @Test func archiveCreatesStereoM4a() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archiver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let systemWav = dir.appendingPathComponent("meeting.wav")
        let micWav = dir.appendingPathComponent("meeting_mic.wav")
        try Self.createTestWav(at: systemWav, frequency: 880)
        try Self.createTestWav(at: micWav, frequency: 440)

        let result = try await AudioArchiver.archive(
            systemAudio: systemWav,
            micAudio: micWav,
            outputDirectory: dir,
            bitrateKbps: 64
        )

        // Output file exists and is m4a
        #expect(result.archivePath.pathExtension == "m4a")
        #expect(FileManager.default.fileExists(atPath: result.archivePath.path))

        // Source WAVs are deleted
        #expect(!FileManager.default.fileExists(atPath: systemWav.path))
        #expect(!FileManager.default.fileExists(atPath: micWav.path))

        // Output is stereo
        let file = try AVAudioFile(forReading: result.archivePath)
        #expect(file.processingFormat.channelCount == 2)
    }

    @Test func archivePreservesBaseName() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archiver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let systemWav = dir.appendingPathComponent("my-meeting-2026.wav")
        let micWav = dir.appendingPathComponent("my-meeting-2026_mic.wav")
        try Self.createTestWav(at: systemWav)
        try Self.createTestWav(at: micWav)

        let result = try await AudioArchiver.archive(
            systemAudio: systemWav,
            micAudio: micWav,
            outputDirectory: dir,
            bitrateKbps: 64
        )

        #expect(result.archivePath.lastPathComponent == "my-meeting-2026.m4a")
    }

    @Test func archiveKeepsWavsOnFailure() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archiver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let systemWav = dir.appendingPathComponent("meeting.wav")
        let micWav = dir.appendingPathComponent("meeting_mic.wav")
        // Write invalid WAV data
        try Data([0, 1, 2]).write(to: systemWav)
        try Data([0, 1, 2]).write(to: micWav)

        do {
            _ = try await AudioArchiver.archive(
                systemAudio: systemWav,
                micAudio: micWav,
                outputDirectory: dir,
                bitrateKbps: 64
            )
            Issue.record("Expected archive to throw on invalid input")
        } catch {
            // WAVs should still exist
            #expect(FileManager.default.fileExists(atPath: systemWav.path))
            #expect(FileManager.default.fileExists(atPath: micWav.path))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AudioArchiverTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -5`

Expected: Compilation error — `AudioArchiver` doesn't exist.

- [ ] **Step 3: Implement AudioArchiver**

Create `TranscriberCore/AudioArchiver.swift`:

```swift
import AVFoundation
import Foundation
import os

public struct AudioArchiveResult {
    public let archivePath: URL
}

public enum AudioArchiverError: LocalizedError {
    case cannotReadAudio(String)
    case encodingFailed(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotReadAudio(let msg): return "Cannot read audio: \(msg)"
        case .encodingFailed(let msg): return "AAC encoding failed: \(msg)"
        case .verificationFailed(let msg): return "Archive verification failed: \(msg)"
        }
    }
}

/// Converts dual-WAV recordings (system + mic) into a single stereo AAC archive.
/// Channel convention: L = local microphone, R = remote system audio.
public enum AudioArchiver {

    /// Archive dual WAV files into a single stereo AAC file.
    /// On success, deletes the source WAV files.
    /// On failure, keeps the source WAV files intact.
    public static func archive(
        systemAudio: URL,
        micAudio: URL,
        outputDirectory: URL,
        bitrateKbps: Int
    ) async throws -> AudioArchiveResult {
        let baseName = systemAudio.deletingPathExtension().lastPathComponent
        let outputPath = outputDirectory.appendingPathComponent("\(baseName).m4a")
        let startTime = ContinuousClock.now

        Logger.files.info("Archiving to stereo AAC: \(baseName, privacy: .public) at \(bitrateKbps) kbps")

        // Read both source files
        let systemFile: AVAudioFile
        let micFile: AVAudioFile
        do {
            systemFile = try AVAudioFile(forReading: systemAudio)
            micFile = try AVAudioFile(forReading: micAudio)
        } catch {
            throw AudioArchiverError.cannotReadAudio(error.localizedDescription)
        }

        let sampleRate = systemFile.processingFormat.sampleRate

        // Read system audio into buffer
        let systemFrameCount = AVAudioFrameCount(systemFile.length)
        let micFrameCount = AVAudioFrameCount(micFile.length)
        let maxFrames = max(systemFrameCount, micFrameCount)

        guard let systemBuffer = AVAudioPCMBuffer(
            pcmFormat: systemFile.processingFormat,
            frameCapacity: systemFrameCount
        ) else {
            throw AudioArchiverError.cannotReadAudio("Cannot create system audio buffer")
        }
        try systemFile.read(into: systemBuffer)

        guard let micBuffer = AVAudioPCMBuffer(
            pcmFormat: micFile.processingFormat,
            frameCapacity: micFrameCount
        ) else {
            throw AudioArchiverError.cannotReadAudio("Cannot create mic audio buffer")
        }
        try micFile.read(into: micBuffer)

        // Create interleaved stereo buffer: L=mic, R=system
        let stereoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: true
        )!
        guard let stereoBuffer = AVAudioPCMBuffer(
            pcmFormat: stereoFormat,
            frameCapacity: maxFrames
        ) else {
            throw AudioArchiverError.encodingFailed("Cannot create stereo buffer")
        }
        stereoBuffer.frameLength = maxFrames

        let stereoPtr = stereoBuffer.floatChannelData![0]
        let systemPtr = systemBuffer.floatChannelData![0]
        let micPtr = micBuffer.floatChannelData![0]

        for i in 0..<Int(maxFrames) {
            let micSample: Float = i < Int(micFrameCount) ? micPtr[i] : 0
            let systemSample: Float = i < Int(systemFrameCount) ? systemPtr[i] : 0
            stereoPtr[i * 2] = micSample       // L = local mic
            stereoPtr[i * 2 + 1] = systemSample // R = remote system
        }

        // Encode to AAC via AVAssetWriter
        // Remove existing output file if present
        try? FileManager.default.removeItem(at: outputPath)

        let writer = try AVAssetWriter(outputURL: outputPath, fileType: .m4a)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: sampleRate,
            AVEncoderBitRateKey: bitrateKbps * 1000,
        ])
        writer.add(writerInput)

        // Convert PCM buffer to CMSampleBuffer for writer
        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: true
        )!

        guard let formatDesc = sourceFormat.formatDescription as CMFormatDescription? else {
            throw AudioArchiverError.encodingFailed("Cannot create format description")
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Write in chunks to avoid memory spikes
        let chunkSize = 48000 // 1 second at 48kHz
        var offset = 0
        let totalFrames = Int(maxFrames)

        while offset < totalFrames {
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }

            let remaining = totalFrames - offset
            let framesToWrite = min(chunkSize, remaining)
            let byteCount = framesToWrite * 2 * MemoryLayout<Float>.size // 2 channels, Float32

            var blockBuffer: CMBlockBuffer?
            let dataPtr = UnsafeMutableRawPointer(stereoPtr.advanced(by: offset * 2))
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorNull,
                memoryBlock: dataPtr,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: 0,
                blockBufferOut: &blockBuffer
            )

            guard let block = blockBuffer else {
                throw AudioArchiverError.encodingFailed("Cannot create block buffer")
            }

            var sampleBuffer: CMSampleBuffer?
            let timing = CMSampleTimingInfo(
                duration: CMTime(value: CMTimeValue(framesToWrite), timescale: CMTimeScale(sampleRate)),
                presentationTimeStamp: CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(sampleRate)),
                decodeTimeStamp: .invalid
            )
            var timingCopy = timing
            let sampleSize = 2 * MemoryLayout<Float>.size // bytes per frame (2 ch × 4 bytes)

            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: formatDesc,
                sampleCount: framesToWrite,
                presentationTimeStamp: timing.presentationTimeStamp,
                packetDescriptions: nil,
                sampleBufferOut: &sampleBuffer
            )

            guard let sample = sampleBuffer else {
                throw AudioArchiverError.encodingFailed("Cannot create sample buffer at offset \(offset)")
            }

            writerInput.append(sample)
            offset += framesToWrite
        }

        writerInput.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw AudioArchiverError.encodingFailed(writer.error?.localizedDescription ?? "Unknown writer error")
        }

        // Verify output
        let attrs = try FileManager.default.attributesOfItem(atPath: outputPath.path)
        let fileSize = attrs[.size] as? Int ?? 0
        guard fileSize > 0 else {
            throw AudioArchiverError.verificationFailed("Output file is empty")
        }

        // Quick decode check
        let verifyAsset = AVAsset(url: outputPath)
        let tracks = try await verifyAsset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            try? FileManager.default.removeItem(at: outputPath)
            throw AudioArchiverError.verificationFailed("Output has no audio tracks")
        }

        // Delete source WAVs
        try FileManager.default.removeItem(at: systemAudio)
        try FileManager.default.removeItem(at: micAudio)

        let elapsed = ContinuousClock.now - startTime
        Logger.files.info(
            "Archive complete: \(outputPath.lastPathComponent, privacy: .public) (\(fileSize) bytes) in \(elapsed.components.seconds)s"
        )

        return AudioArchiveResult(archivePath: outputPath)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AudioArchiverTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -5`

Expected: All 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/AudioArchiver.swift SwiftTests/TranscriberTests/AudioArchiverTests.swift
git commit -m "feat: AudioArchiver — convert dual WAV to stereo AAC (L=mic, R=system)"
```

---

### Task 6: StorageManager — Quota enforcement

**Files:**
- Create: `TranscriberCore/StorageManager.swift`
- Create: `SwiftTests/TranscriberTests/StorageManagerTests.swift`

- [ ] **Step 1: Write failing tests**

Create `SwiftTests/TranscriberTests/StorageManagerTests.swift`:

```swift
import Testing
import Foundation
@testable import TranscriberCore

struct StorageManagerTests {

    private static func createFakeM4a(at url: URL, sizeBytes: Int) throws {
        let data = Data(repeating: 0, count: sizeBytes)
        try data.write(to: url)
    }

    @Test func quotaInBytesCalculation() {
        // 15 hours at 64 kbps = 15 * 64000 / 8 * 3600 = 432_000_000 bytes
        let bytes = StorageManager.quotaBytes(hours: 15, bitrateKbps: 64)
        #expect(bytes == 15 * 64000 / 8 * 3600)
    }

    @Test func noCleanupWhenUnderQuota() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create a small file (1 KB) with a large quota (15 hours)
        let file = dir.appendingPathComponent("small.m4a")
        try Self.createFakeM4a(at: file, sizeBytes: 1024)

        let deleted = try StorageManager.enforceQuota(
            in: dir,
            limitHours: 15,
            bitrateKbps: 64,
            protectedFile: nil
        )
        #expect(deleted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func deletesOldestFilesWhenOverQuota() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Quota: 1 hour at 64 kbps = 28_800_000 bytes (~27.5 MB)
        // Create three 10MB files (total 30MB > quota)
        let tenMB = 10_000_000
        let old = dir.appendingPathComponent("old.m4a")
        let mid = dir.appendingPathComponent("mid.m4a")
        let new = dir.appendingPathComponent("new.m4a")
        try Self.createFakeM4a(at: old, sizeBytes: tenMB)
        Thread.sleep(forTimeInterval: 0.05) // Ensure distinct modification times
        try Self.createFakeM4a(at: mid, sizeBytes: tenMB)
        Thread.sleep(forTimeInterval: 0.05)
        try Self.createFakeM4a(at: new, sizeBytes: tenMB)

        let deleted = try StorageManager.enforceQuota(
            in: dir,
            limitHours: 1,
            bitrateKbps: 64,
            protectedFile: nil
        )

        // Should delete oldest file(s) to get under quota
        #expect(!deleted.isEmpty)
        #expect(deleted.contains(old))
        // The newest file should always survive
        #expect(FileManager.default.fileExists(atPath: new.path))
    }

    @Test func neverDeletesProtectedFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Set a tiny quota that forces cleanup
        let fiveMB = 5_000_000
        let file = dir.appendingPathComponent("protected.m4a")
        try Self.createFakeM4a(at: file, sizeBytes: fiveMB)

        let deleted = try StorageManager.enforceQuota(
            in: dir,
            limitHours: 0, // zero quota, but file is protected
            bitrateKbps: 64,
            protectedFile: file
        )

        #expect(deleted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func ignoresNonM4aFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create a large JSON file — should not be counted or deleted
        let jsonFile = dir.appendingPathComponent("transcript.json")
        try Data(repeating: 0, count: 50_000_000).write(to: jsonFile)

        let deleted = try StorageManager.enforceQuota(
            in: dir,
            limitHours: 1,
            bitrateKbps: 64,
            protectedFile: nil
        )
        #expect(deleted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: jsonFile.path))
    }

    @Test func currentUsageBytes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Self.createFakeM4a(at: dir.appendingPathComponent("a.m4a"), sizeBytes: 1000)
        try Self.createFakeM4a(at: dir.appendingPathComponent("b.m4a"), sizeBytes: 2000)
        // Non-m4a should not be counted
        try Data(repeating: 0, count: 9999).write(to: dir.appendingPathComponent("c.json"))

        let usage = StorageManager.currentUsageBytes(in: dir)
        #expect(usage == 3000)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter StorageManagerTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -5`

Expected: Compilation error — `StorageManager` doesn't exist.

- [ ] **Step 3: Implement StorageManager**

Create `TranscriberCore/StorageManager.swift`:

```swift
import Foundation
import os

/// Enforces audio archive storage quota by deleting oldest .m4a files.
/// Only manages .m4a files — transcripts (JSON/SRT/TXT) and WAVs are never touched.
public enum StorageManager {

    /// Calculate quota in bytes from hours and bitrate.
    public static func quotaBytes(hours: Int, bitrateKbps: Int) -> Int {
        hours * bitrateKbps * 1000 / 8 * 3600
    }

    /// Total size of .m4a files in the directory.
    public static func currentUsageBytes(in directory: URL) -> Int {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        return contents
            .filter { $0.pathExtension == "m4a" }
            .compactMap { url -> Int? in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey])
                return values?.fileSize
            }
            .reduce(0, +)
    }

    /// Enforce storage quota by deleting oldest .m4a files.
    /// - Parameters:
    ///   - directory: The recording directory to scan
    ///   - limitHours: Maximum hours of audio to retain
    ///   - bitrateKbps: Encoding bitrate (for quota calculation)
    ///   - protectedFile: File that must never be deleted (e.g., just-archived file)
    /// - Returns: List of deleted file URLs
    @discardableResult
    public static func enforceQuota(
        in directory: URL,
        limitHours: Int,
        bitrateKbps: Int,
        protectedFile: URL?
    ) throws -> [URL] {
        let quota = quotaBytes(hours: limitHours, bitrateKbps: bitrateKbps)
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return [] }

        // Only consider .m4a files
        var m4aFiles = contents.filter { $0.pathExtension == "m4a" }

        // Sort by modification date, oldest first
        m4aFiles.sort { a, b in
            let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return dateA < dateB
        }

        var totalSize = m4aFiles.compactMap { url -> Int? in
            (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        }.reduce(0, +)

        guard totalSize > quota else { return [] }

        var deleted: [URL] = []
        for file in m4aFiles {
            guard totalSize > quota else { break }

            // Never delete the protected file
            if let protectedFile, file.path == protectedFile.path {
                continue
            }

            let fileSize = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            try fm.removeItem(at: file)
            totalSize -= fileSize
            deleted.append(file)
            Logger.files.info("StorageManager: deleted \(file.lastPathComponent, privacy: .public) (\(fileSize) bytes) to enforce quota")
        }

        if !deleted.isEmpty {
            Logger.files.info("StorageManager: deleted \(deleted.count) file(s), usage now \(totalSize) / \(quota) bytes")
        }

        return deleted
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter StorageManagerTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -5`

Expected: All 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/StorageManager.swift SwiftTests/TranscriberTests/StorageManagerTests.swift
git commit -m "feat: StorageManager — enforce audio archive quota, delete oldest m4a first"
```

---

### Task 7: Integrate AudioArchiver into TranscriptionRunner

**Files:**
- Modify: `TranscriberApp/Services/TranscriptionRunner.swift`

- [ ] **Step 1: Add archival step after transcription**

In `TranscriberApp/Services/TranscriptionRunner.swift`, after the `TranscriptWriter.writeFormatFile` call (around line 132), add the archival and storage management steps:

```swift
// Archive WAVs to stereo AAC (L=mic, R=system)
if isDualStream, let micAudio {
    do {
        let archiveResult = try await AudioArchiver.archive(
            systemAudio: systemAudio,
            micAudio: micAudio,
            outputDirectory: outputDirectory,
            bitrateKbps: config.archiveBitrateKbps
        )
        // Update transcript JSON with new audio path
        Self.updateAudioPaths(in: jsonPath, to: [archiveResult.archivePath])
        Logger.files.info("Archived to: \(archiveResult.archivePath.lastPathComponent, privacy: .public)")

        // Enforce storage quota
        StorageManager.enforceQuota(
            in: outputDirectory,
            limitHours: config.audioArchiveLimitHours,
            bitrateKbps: config.archiveBitrateKbps,
            protectedFile: archiveResult.archivePath
        )
    } catch {
        Logger.files.error("Archival failed, keeping WAV files: \(error, privacy: .public)")
    }
}
```

- [ ] **Step 2: Add the updateAudioPaths helper**

Add this static method to `TranscriptionRunner`:

```swift
/// Update the audio_paths in a transcript JSON file after archival.
private static func updateAudioPaths(in jsonPath: URL, to newPaths: [URL]) {
    guard let data = try? Data(contentsOf: jsonPath),
          var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var metadata = json["metadata"] as? [String: Any]
    else { return }

    metadata["audio_paths"] = newPaths.map { $0.path }
    metadata["audio_files"] = newPaths.map { $0.lastPathComponent }
    json["metadata"] = metadata

    if let updatedData = try? JSONSerialization.data(
        withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
    ) {
        try? updatedData.write(to: jsonPath, options: .atomic)
        Logger.files.info("Updated audio_paths in \(jsonPath.lastPathComponent, privacy: .public)")
    }
}
```

- [ ] **Step 3: Verify build succeeds**

Run: `swift build 2>&1 | tail -3`

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add TranscriberApp/Services/TranscriptionRunner.swift
git commit -m "feat: integrate AudioArchiver and StorageManager into transcription pipeline"
```

---

### Task 8: Update RenameWindowController for stereo AAC

**Files:**
- Modify: `TranscriberApp/Services/RenameWindowController.swift`

- [ ] **Step 1: Update parseSpeakers to handle single m4a**

In `RenameWindowController.parseSpeakers(from:)` (around line 94–99), replace the audio path mapping:

Replace:
```swift
// Build source→audio file mapping from metadata
let metadata = json["metadata"] as? [String: Any]
let audioPaths = metadata?["audio_paths"] as? [String] ?? []
// First path = system (remote), second = mic (local)
let remoteAudio = audioPaths.first.map { URL(fileURLWithPath: $0) }
let localAudio = audioPaths.count > 1 ? URL(fileURLWithPath: audioPaths[1]) : nil
```

With:
```swift
// Build source→audio file mapping from metadata
let metadata = json["metadata"] as? [String: Any]
let audioPaths = metadata?["audio_paths"] as? [String] ?? []

let remoteAudio: URL?
let localAudio: URL?

if audioPaths.count == 1, audioPaths[0].hasSuffix(".m4a") {
    // Stereo AAC archive: single file serves both sources
    // AVAudioPlayer plays stereo as-is (L=local, R=remote) — works for sample playback
    let archivePath = URL(fileURLWithPath: audioPaths[0])
    let exists = FileManager.default.fileExists(atPath: archivePath.path)
    remoteAudio = exists ? archivePath : nil
    localAudio = exists ? archivePath : nil
} else {
    // Legacy dual WAV: first = system (remote), second = mic (local)
    remoteAudio = audioPaths.first.map { URL(fileURLWithPath: $0) }
    localAudio = audioPaths.count > 1 ? URL(fileURLWithPath: audioPaths[1]) : nil
}
```

- [ ] **Step 2: Verify build succeeds**

Run: `swift build 2>&1 | tail -3`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Services/RenameWindowController.swift
git commit -m "feat: RenameWindowController handles single stereo AAC in audio_paths"
```

---

### Task 9: Settings UI — Audio Archive section

**Files:**
- Modify: `TranscriberApp/Views/SettingsView.swift`

- [ ] **Step 1: Add Audio Archive section**

In `TranscriberApp/Views/SettingsView.swift`, add a new section after the "Recording" section (after line 85):

```swift
Section("Audio Archive") {
    Picker("Encoding Bitrate", selection: $config.archiveBitrateKbps) {
        Text("48 kbps").tag(48)
        Text("64 kbps").tag(64)
        Text("96 kbps").tag(96)
        Text("128 kbps").tag(128)
    }

    Stepper(
        "Keep last \(config.audioArchiveLimitHours) hours",
        value: $config.audioArchiveLimitHours,
        in: 1...999
    )

    let estimatedMiB = config.audioArchiveLimitHours * config.archiveBitrateKbps * 1000 / 8 * 3600 / 1_048_576
    Text("≈ \(estimatedMiB) MiB at \(config.archiveBitrateKbps) kbps")
        .font(.caption)
        .foregroundStyle(.secondary)

    let usageBytes = StorageManager.currentUsageBytes(
        in: URL(fileURLWithPath: config.recordingDirectory)
    )
    let usageMiB = usageBytes / 1_048_576
    let usageHours = config.archiveBitrateKbps > 0
        ? usageBytes * 8 / (config.archiveBitrateKbps * 1000) / 3600
        : 0
    Text("\(usageMiB) MiB used (≈ \(usageHours) hours)")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

- [ ] **Step 2: Increase window height**

The Settings window needs more height for the new section. Update the frame (around line 115):

Replace:
```swift
.frame(width: 450, height: 500)
```

With:
```swift
.frame(width: 450, height: 600)
```

- [ ] **Step 3: Verify build succeeds**

Run: `swift build 2>&1 | tail -3`

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add TranscriberApp/Views/SettingsView.swift
git commit -m "feat: add Audio Archive section to Settings (bitrate, limit hours, usage)"
```

---

### Task 10: Update CLAUDE.md and test checklist

**Files:**
- Modify: `CLAUDE.md`
- Modify: `scripts/test-checklist.md`

- [ ] **Step 1: Update CLAUDE.md**

Add to the Architecture → Shared Logic section, after the `FilenameUtils.swift` entry:

```
- `TranscriberCore/AudioSourceResolver.swift` -- detects input format (dual WAV or stereo AAC), splits stereo AAC channels (L=local mic, R=remote system) for pipeline re-ingestion
- `TranscriberCore/AudioArchiver.swift` -- converts dual WAV (system+mic) to stereo AAC archive (L=mic, R=system) via AVAssetWriter, deletes source WAVs on success
- `TranscriberCore/StorageManager.swift` -- enforces audio archive storage quota in hours, deletes oldest .m4a files first, never deletes transcripts
```

Add to Key Gotchas:

```
35. **Stereo AAC channel convention:** L=local microphone, R=remote system audio. This is the contract between AudioArchiver (producer) and AudioSourceResolver (consumer). Never swap channels.
36. **System audio capture rate:** Hardcoded to 48 kHz in SCStreamConfiguration. The `sample_rate` config field is deprecated — log a warning if present.
37. **Audio archive quota:** Enforced in hours via static calculation (hours × bitrate → bytes). Only .m4a files count toward quota. Transcripts are never deleted. The just-archived file is always protected from cleanup.
38. **AudioArchiver error safety:** If AAC encoding fails at any step, source WAV files are kept intact. Never delete WAVs before verifying the archive is valid.
```

Update the Audio Capture Architecture section, replace:

```
- `.audio` output type = system audio only (at config sampleRate)
```

With:

```
- `.audio` output type = system audio only (at 48 kHz, hardcoded)
```

- [ ] **Step 2: Update test checklist**

Add to `scripts/test-checklist.md`:

```markdown
## Audio Archive
- [ ] Record a meeting (system + mic), verify .m4a created after transcription
- [ ] Verify .m4a is stereo (L=mic, R=system) — play in QuickTime, check both channels
- [ ] Verify source WAV files are deleted after successful archival
- [ ] Verify transcript JSON audio_paths points to .m4a after archival
- [ ] Open rename dialog after archival — verify speaker samples play correctly
- [ ] Change archive bitrate in Settings, record again, verify file size matches expected bitrate
- [ ] Set archive limit to 1 hour, record multiple sessions, verify oldest .m4a is cleaned up
- [ ] Verify transcript JSON/SRT/TXT files are never deleted by quota enforcement
- [ ] If archival fails (simulate by making output dir read-only), verify WAV files are preserved
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md scripts/test-checklist.md
git commit -m "docs: update CLAUDE.md and test checklist for audio archive feature"
```

---

### Task 11: Run full test suite

**Files:** None (validation only)

- [ ] **Step 1: Run all tests**

Run: `swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -5`

Expected: All tests pass (existing ~239 + new ~16 = ~255 tests).

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -3`

Expected: Build complete.

- [ ] **Step 3: Review all changes**

Run: `git log --oneline main..HEAD`

Expected commits:
1. `feat: add archive config fields (bitrate, limit hours), deprecation warning for sample_rate`
2. `feat: hardcode system audio capture to 48 kHz`
3. `feat: AudioSourceResolver — detect dual WAV, single WAV, or stereo AAC input`
4. `feat: AudioSourceResolver.splitChannels — extract L/R from stereo AAC to mono WAVs`
5. `feat: AudioArchiver — convert dual WAV to stereo AAC (L=mic, R=system)`
6. `feat: StorageManager — enforce audio archive quota, delete oldest m4a first`
7. `feat: integrate AudioArchiver and StorageManager into transcription pipeline`
8. `feat: RenameWindowController handles single stereo AAC in audio_paths`
9. `feat: add Audio Archive section to Settings (bitrate, limit hours, usage)`
10. `docs: update CLAUDE.md and test checklist for audio archive feature`
