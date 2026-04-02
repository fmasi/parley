# Benchmark Tool API Research

Researched 2026-04-01. Concrete API details for three transcription engines.

---

## 1. FluidAudio (FluidInference)

### Identity
- **GitHub:** https://github.com/FluidInference/FluidAudio
- **Import name:** `FluidAudio`
- **License:** Apache 2.0 (fully open source, no API key required)
- **Models auto-download from HuggingFace** (no account needed)

### SPM Dependency
```swift
.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
// target dependency:
.product(name: "FluidAudio", package: "FluidAudio")
```

### Models
| Model | ID | Use | Languages |
|---|---|---|---|
| Parakeet TDT v3 | `FluidInference/parakeet-tdt-0.6b-v3-coreml` | Batch transcription | 25 European |
| Parakeet TDT v2 | `FluidInference/parakeet-tdt-0.6b-v2-coreml` | Batch (English-only, higher recall) | English |
| Parakeet EOU 120M | `FluidInference/parakeet-realtime-eou-120m-coreml` | Streaming ASR | English |

- Model size: 0.6B parameters (v2/v3), 120M (EOU)
- Real-time factor: ~120x on M4 Pro (1 minute of audio in ~0.5 seconds)
- Inference runs on Apple Neural Engine (ANE) via CoreML

### Audio Format Requirement
All modules expect **16kHz mono Float32** samples. Use `FluidAudio.AudioConverter` to convert files --
do NOT manually parse WAV headers.

### Minimum API -- Batch Transcription
```swift
import FluidAudio

// 1. Download and load models
let models = try await AsrModels.downloadAndLoad(version: .v3)  // or .v2 for English-only
let asrManager = AsrManager(config: .default)
try await asrManager.loadModels(models)

// 2. Convert audio to 16kHz mono Float32
let samples = try await loadSamples16kMono(path: "path/to/audio.wav")
// NOTE: use AudioConverter for real code, not manual parsing

// 3. Transcribe
let result = try await asrManager.transcribe(samples, source: .system)
print("Text: \(result.text)")
print("Confidence: \(result.confidence)")
```

### Speaker Diarization (built-in)
```swift
import FluidAudio

// LS-EEND: up to 10 speakers, 100ms streaming updates
let diarizer = LSEENDDiarizer()
try await diarizer.initialize(variant: .dihart3)

let samples = try await loadSamples16kMono(path: "path/to/meeting.wav")
let timeline = try diarizer.processComplete(samples, sourceSampleRate: 16_000)

for segment in timeline.segments {
    print("Speaker \(segment.speakerId): \(segment.startTimeSeconds)s - \(segment.endTimeSeconds)s")
}
```

Alternative diarizers:
- **Sortformer**: more stable speaker IDs, limited to 4 speakers
- **DiarizerManager** (legacy): clustering pipeline, `performCompleteDiarization(_:sampleRate:) -> DiarizationResult`
- **Offline VBx pipeline**: best offline quality

---

## 2. macOS 26 SpeechAnalyzer / SpeechTranscriber

### Identity
- **Framework:** `Speech` (same framework as SFSpeechRecognizer, new APIs in macOS 26)
- **Import:** `import Speech` (also `import AVFAudio` for file reading)
- **Minimum OS:** macOS 26.0 / iOS 26.0
- **Requires:** Xcode 26 beta command-line tools
- **No API key needed** -- on-device Apple model
- **No speaker diarization** -- SpeechAnalyzer does NOT support diarization

### Key Classes
| Class | Purpose |
|---|---|
| `SpeechAnalyzer` | Manages analysis sessions, coordinates modules |
| `SpeechTranscriber` | Speech-to-text module (advanced on-device model) |
| `DictationTranscriber` | Fallback for unsupported devices (same API surface) |
| `SpeechDetector` | Voice activity detection module |

### Presets
- `.offlineTranscription` -- batch file transcription
- `.progressiveLiveTranscription` -- real-time streaming

### Minimum API -- File Transcription
```swift
import Foundation
import AVFAudio
import Speech

func transcribeFile(from fileURL: URL, locale: Locale) async throws -> String {
    let transcriber = SpeechTranscriber(
        locale: locale,
        preset: .offlineTranscription
    )
    
    // Check if model is installed, download if needed
    if !(await SpeechTranscriber.installedLocales).contains(locale) {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }
    
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let audioFile = try AVAudioFile(forReading: fileURL)
    
    // Collect results concurrently
    async let transcript: AttributedString = transcriber.results.reduce(into: AttributedString("")) { partial, result in
        partial.append(result.text)
        partial.append(AttributedString(" "))
    }
    
    // Feed audio and finalize
    if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
        try await analyzer.finalizeAndFinish(through: lastSample)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    
    let plainText = String((try await transcript).characters)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return plainText
}
```

### Device Check + Fallback
```swift
if !SpeechTranscriber.supportsDevice() {
    let dictationTranscriber = DictationTranscriber(locale: locale)
    // Same API -- fallback for older/unsupported hardware
}
```

### SPM Package.swift (no external deps)
```swift
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "MyApp",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "MyApp",
            linkerSettings: [
                // Embed Info.plist for TCC permissions
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist"
                ])
            ]
        )
    ]
)
```

### Performance
- 2.2x faster than MacWhisper Large V3 Turbo (per MacStories benchmarks)
- No noticeable quality difference vs Whisper large models

### Key Notes
- `analyzeSequence(from:)` accepts `AVAudioFile` -- handles format conversion internally
- `transcriber.results` is an `AsyncSequence` -- each element has `.text` (AttributedString)
- Ending the input stream does NOT end the session -- must call `finalizeAndFinish(through:)`
- `cancelAndFinishNow()` for when no audio was found
- Reference implementation: https://github.com/argmaxinc/apple-speechanalyzer-cli-example

---

## 3. whisper.cpp via Swift

### Option A: SwiftWhisper (recommended -- highest-level API)

**GitHub:** https://github.com/exPHAT/SwiftWhisper (774 stars)

**SPM:**
```swift
.package(url: "https://github.com/exPHAT/SwiftWhisper.git", from: "1.2.0")
// target dependency:
.product(name: "SwiftWhisper", package: "SwiftWhisper")
```

**Import:** `import SwiftWhisper`

**Segment struct:**
```swift
public struct Segment: Equatable {
    public let startTime: Int   // milliseconds
    public let endTime: Int     // milliseconds
    public let text: String
}
```

**Minimum API:**
```swift
import SwiftWhisper

let modelURL = URL(fileURLWithPath: "path/to/ggml-base.en.bin")
let whisper = Whisper(fromFileURL: modelURL)

// audioFrames must be [Float] at 16kHz mono
let segments = try await whisper.transcribe(audioFrames: samples)

for segment in segments {
    print("[\(segment.startTime)ms - \(segment.endTime)ms] \(segment.text)")
}
print("Full text:", segments.map(\.text).joined())
```

**Models:** Download GGML-format Whisper models from https://huggingface.co/ggerganov/whisper.cpp
- tiny.en: ~75MB
- base.en: ~142MB
- small.en: ~466MB
- medium.en: ~1.5GB
- large-v3: ~3.1GB

**License:** MIT (open source, no API key)

### Option B: whisper.spm (low-level C API wrapper)

**GitHub:** https://github.com/ggerganov/whisper.spm (190 stars)

**SPM:**
```swift
// IMPORTANT: must use branch dependency, not version (unsafe build flags)
.package(url: "https://github.com/ggerganov/whisper.spm", branch: "master")
```

**Import:** `import whisper` (C module)

This exposes the raw whisper.cpp C API (`whisper_init_from_file`, `whisper_full`, etc.).
You would need to write your own Swift wrapper around the C functions.
**Recommendation: use SwiftWhisper instead** -- it wraps whisper.spm with a clean Swift API.

### Option C: WhisperKit (CoreML, by Argmax)

**GitHub:** https://github.com/argmaxinc/WhisperKit

**SPM:**
```swift
.package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
```

**Import:** `import WhisperKit`

Compiles Whisper models to CoreML format, runs on ANE. Has `TranscriptionSegment` with
`start: Float`, `end: Float`, `text: String`, `words: [WordTiming]?`.

More complex setup than SwiftWhisper but potentially faster on Apple Silicon due to ANE.
Pro version requires paid license ($1/device/month). Open source version is MIT.

---

## Summary Comparison

| Feature | FluidAudio | SpeechAnalyzer | SwiftWhisper |
|---|---|---|---|
| Import | `FluidAudio` | `Speech` | `SwiftWhisper` |
| Min OS | macOS 14+ | macOS 26.0 | macOS 13+ |
| License | Apache 2.0 | Apple built-in | MIT |
| API key | No | No | No |
| Model download | Auto (HuggingFace) | Auto (Apple) | Manual (GGML files) |
| Speaker diarization | Yes (built-in) | No | No |
| Inference engine | CoreML/ANE | Apple private | CPU (Accelerate) |
| Audio format | 16kHz mono Float32 | AVAudioFile (auto) | 16kHz mono Float |
| Speed (est.) | ~120x RT (M4 Pro) | ~2.2x Whisper Large | ~10-30x RT (CPU) |
