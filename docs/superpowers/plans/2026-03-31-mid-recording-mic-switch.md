# Mid-Recording Microphone Switch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow switching the active microphone during a recording via a menu bar option, without stopping capture, with all mic audio normalized to a consistent format.

**Architecture:** Audio normalization via `AVAudioConverter` in `AudioOutputHandler` converts every mic CMSampleBuffer to 48kHz mono Int16 before writing to `WavFileWriter`. A new `updateMicrophone(deviceId:reply:)` XPC method calls `SCStream.updateConfiguration()` on the live stream. A "Change Microphone..." menu item opens a floating `NSPanel` with the existing `MicrophonePicker` component.

**Tech Stack:** ScreenCaptureKit, AVFoundation (AVAudioConverter), SwiftUI, XPC, Swift Testing

**Spec:** `docs/superpowers/specs/2026-03-31-mid-recording-mic-switch-design.md`

**Build command:** `swift build`

**Test command:** `swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `TranscriberCore/AudioConverter.swift` | **Create** | Pure audio format conversion: CMSampleBuffer → normalized Int16 samples via AVAudioConverter |
| `SwiftTests/TranscriberTests/AudioConverterTests.swift` | **Create** | Unit tests for AudioConverter |
| `AudioCaptureHelper/XPC/AudioOutputHandler.swift` | **Modify** | Use AudioConverter for mic frames instead of raw passthrough |
| `AudioCaptureProtocol/AudioCaptureProtocol.swift` | **Modify** | Add `updateMicrophone(deviceId:reply:)` to protocol |
| `AudioCaptureHelper/XPC/AudioCaptureService.swift` | **Modify** | Implement `updateMicrophone` — call `stream.updateConfiguration()` |
| `TranscriberApp/Services/AudioCaptureClient.swift` | **Modify** | Add `updateMicrophone(deviceId:)` async wrapper |
| `TranscriberApp/Services/MicSwitchWindowController.swift` | **Create** | NSPanel controller for mic switch dialog (same pattern as SessionNameWindowController) |
| `TranscriberApp/Views/MicSwitchDialog.swift` | **Create** | SwiftUI view: MicrophonePicker + Switch/Cancel buttons |
| `TranscriberApp/Views/MenuView.swift` | **Modify** | Add "Change Microphone..." item during recording |
| `scripts/test-checklist.md` | **Modify** | Add mic switch manual test cases |

---

## Task 1: AudioConverter — Failing Tests

**Files:**
- Create: `SwiftTests/TranscriberTests/AudioConverterTests.swift`

The `AudioConverter` will live in `TranscriberCore` so it can be unit-tested. It wraps `AVAudioConverter` and converts arbitrary PCM audio (any sample rate, channel count, Float32 or Int16) to a fixed 48kHz mono Int16 output.

- [ ] **Step 1: Write the failing tests**

Create `SwiftTests/TranscriberTests/AudioConverterTests.swift`:

```swift
import Testing
import Foundation
import AVFoundation
@testable import TranscriberCore

struct AudioConverterTests {

    // MARK: - Helpers

    /// Create an AVAudioPCMBuffer with Float32 samples at a given rate/channels.
    private func makeFloat32Buffer(
        samples: [Float],
        sampleRate: Double,
        channels: UInt32
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: channels > 1
        )!
        let frameCount = UInt32(samples.count) / channels
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        if channels > 1 {
            // Interleaved: copy directly
            memcpy(buffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)
        } else {
            memcpy(buffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)
        }
        return buffer
    }

    // MARK: - Conversion output format

    @Test func outputIsAlways48kHzMonoInt16() throws {
        let converter = AudioConverter()
        let input = makeFloat32Buffer(
            samples: [0.0, 0.5, -0.5, 1.0],
            sampleRate: 16000,
            channels: 1
        )
        let result = try converter.convert(input)
        #expect(result.sampleRate == 48000)
        #expect(result.channelCount == 1)
        #expect(!result.samples.isEmpty)
    }

    @Test func convertsFrom48kHzStereoToMono() throws {
        let converter = AudioConverter()
        // 4 frames of stereo = 8 samples interleaved (L, R, L, R, ...)
        let input = makeFloat32Buffer(
            samples: [0.5, 0.3, 0.5, 0.3, 0.5, 0.3, 0.5, 0.3],
            sampleRate: 48000,
            channels: 2
        )
        let result = try converter.convert(input)
        #expect(result.sampleRate == 48000)
        #expect(result.channelCount == 1)
        // 4 input frames at 48kHz → 4 output frames at 48kHz (no rate change, just downmix)
        #expect(result.samples.count == 4)
    }

    @Test func handlesFormatChange() throws {
        let converter = AudioConverter()
        // First: 16kHz mono
        let input1 = makeFloat32Buffer(
            samples: [0.1, 0.2, 0.3, 0.4],
            sampleRate: 16000,
            channels: 1
        )
        let result1 = try converter.convert(input1)
        #expect(result1.sampleRate == 48000)

        // Second: 48kHz stereo — format change, converter should adapt
        let input2 = makeFloat32Buffer(
            samples: [0.5, 0.3, 0.5, 0.3],
            sampleRate: 48000,
            channels: 2
        )
        let result2 = try converter.convert(input2)
        #expect(result2.sampleRate == 48000)
        #expect(result2.channelCount == 1)
    }

    @Test func outputSamplesAreReasonable() throws {
        let converter = AudioConverter()
        // Constant 0.5 signal at 48kHz mono — no resampling needed
        let input = makeFloat32Buffer(
            samples: [0.5, 0.5, 0.5, 0.5],
            sampleRate: 48000,
            channels: 1
        )
        let result = try converter.convert(input)
        // All output samples should be near Int16(0.5 * 32767) = ~16383
        for sample in result.samples {
            #expect(abs(Int32(sample) - 16383) < 100)
        }
    }

    @Test func sameSampleRatePassthrough() throws {
        let converter = AudioConverter()
        let input = makeFloat32Buffer(
            samples: [0.0, 1.0, -1.0, 0.5],
            sampleRate: 48000,
            channels: 1
        )
        let result = try converter.convert(input)
        // Same rate, same channels → frame count should match
        #expect(result.samples.count == 4)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TranscriberTests/AudioConverterTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/`

Expected: Compilation error — `AudioConverter` type does not exist.

---

## Task 2: AudioConverter — Implementation

**Files:**
- Create: `TranscriberCore/AudioConverter.swift`

- [ ] **Step 1: Implement AudioConverter**

Create `TranscriberCore/AudioConverter.swift`:

```swift
import AVFoundation
import os

/// Converts arbitrary PCM audio buffers to a fixed 48kHz mono Int16 format.
/// Handles sample rate conversion, channel downmixing, and format normalization
/// via AVAudioConverter. Detects source format changes (e.g., after a mic switch)
/// and recreates the internal converter automatically.
public final class AudioConverter {
    public static let outputSampleRate: Double = 48000
    public static let outputChannelCount: UInt32 = 1

    /// The fixed output format: 48kHz mono Int16
    public static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: outputSampleRate,
        channels: AVAudioChannelCount(outputChannelCount),
        interleaved: true
    )!

    private var converter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?

    public struct Result {
        public let samples: [Int16]
        public let sampleRate: Double
        public let channelCount: UInt32

        public init(samples: [Int16], sampleRate: Double, channelCount: UInt32) {
            self.samples = samples
            self.sampleRate = sampleRate
            self.channelCount = channelCount
        }
    }

    public init() {}

    /// Convert an AVAudioPCMBuffer (any supported PCM format) to 48kHz mono Int16.
    /// Creates or replaces the internal AVAudioConverter when the input format changes.
    public func convert(_ inputBuffer: AVAudioPCMBuffer) throws -> Result {
        let inputFormat = inputBuffer.format

        // Rebuild converter if input format changed
        if converter == nil || lastInputFormat != inputFormat {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else {
                throw AudioConverterError.cannotCreateConverter(
                    from: inputFormat.description, to: Self.outputFormat.description
                )
            }
            newConverter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
            converter = newConverter
            lastInputFormat = inputFormat
            Logger.audio.info(
                "AudioConverter: new converter \(inputFormat.sampleRate)Hz \(inputFormat.channelCount)ch → 48000Hz 1ch"
            )
        }

        guard let converter else {
            throw AudioConverterError.converterNotAvailable
        }

        // Calculate output frame count
        let ratio = Self.outputSampleRate / inputFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(
            ceil(Double(inputBuffer.frameLength) * ratio)
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: Self.outputFormat,
            frameCapacity: outputFrameCount
        ) else {
            throw AudioConverterError.cannotCreateOutputBuffer
        }

        var inputConsumed = false
        var conversionError: Error?
        let status = converter.convert(to: outputBuffer, error: &conversionError) {
            _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let conversionError {
            throw AudioConverterError.conversionFailed(conversionError.localizedDescription)
        }
        if status == .error {
            throw AudioConverterError.conversionFailed("AVAudioConverter returned error status")
        }

        // Extract Int16 samples from output buffer
        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else {
            return Result(samples: [], sampleRate: Self.outputSampleRate, channelCount: Self.outputChannelCount)
        }

        let int16Ptr = outputBuffer.int16ChannelData![0]
        let samples = Array(UnsafeBufferPointer(start: int16Ptr, count: frameCount))

        return Result(
            samples: samples,
            sampleRate: Self.outputSampleRate,
            channelCount: Self.outputChannelCount
        )
    }
}

public enum AudioConverterError: LocalizedError {
    case cannotCreateConverter(from: String, to: String)
    case converterNotAvailable
    case cannotCreateOutputBuffer
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateConverter(let from, let to):
            return "Cannot create audio converter from \(from) to \(to)"
        case .converterNotAvailable:
            return "Audio converter not available"
        case .cannotCreateOutputBuffer:
            return "Cannot create output buffer"
        case .conversionFailed(let msg):
            return "Audio conversion failed: \(msg)"
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `swift test --filter TranscriberTests/AudioConverterTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/`

Expected: All 5 tests pass.

- [ ] **Step 3: Commit**

```bash
git add TranscriberCore/AudioConverter.swift SwiftTests/TranscriberTests/AudioConverterTests.swift
git commit -m "feat: add AudioConverter for mic audio normalization to 48kHz mono Int16"
```

---

## Task 3: Integrate AudioConverter into AudioOutputHandler

**Files:**
- Modify: `AudioCaptureHelper/XPC/AudioOutputHandler.swift`

This task replaces the raw mic passthrough with normalized audio. The `detectedMicRate` flag and per-frame format detection for mic are replaced by the `AudioConverter`. System audio (`.audio` type) is left unchanged.

- [ ] **Step 1: Update AudioOutputHandler to use AudioConverter for mic frames**

Replace the full content of `AudioCaptureHelper/XPC/AudioOutputHandler.swift` with:

```swift
import AudioToolbox
import AVFoundation
import Foundation
import os
import ScreenCaptureKit
import TranscriberCore

final class AudioOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate {
    private let systemWriter: WavFileWriter
    private let micWriter: WavFileWriter
    private var detectedSystemRate = false
    private let micConverter = AudioConverter()

    init(systemWriter: WavFileWriter, micWriter: WavFileWriter) {
        self.systemWriter = systemWriter
        self.micWriter = micWriter

        // Mic writer always gets normalized 48kHz mono Int16
        micWriter.setSampleRate(UInt32(AudioConverter.outputSampleRate))
        micWriter.setChannelCount(UInt16(AudioConverter.outputChannelCount))
    }

    func finalizeAll() {
        systemWriter.finalize()
        micWriter.finalize()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        if type == .audio {
            handleSystemAudio(sampleBuffer)
        } else if type == .microphone {
            handleMicAudio(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Logger.audio.error("Stream stopped with error: \(error, privacy: .public)")
    }

    // MARK: - System audio (unchanged — ScreenCaptureKit normalizes via config)

    private func handleSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        if !detectedSystemRate {
            detectedSystemRate = true
            if let info = formatInfo(from: sampleBuffer) {
                systemWriter.setSampleRate(UInt32(info.rate))
                systemWriter.setChannelCount(UInt16(info.channels))
                Logger.audio.info("System audio: \(Int(info.rate))Hz, \(info.channels)ch, \(info.isFloat ? "Float32" : "Int16", privacy: .public)")
            }
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset = 0, totalLength = 0
        var rawPtr: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength,
            dataPointerOut: &rawPtr
        )
        guard status == kCMBlockBufferNoErr, let ptr = rawPtr else { return }

        let isFloat = isFloatFormat(from: sampleBuffer)
        if isFloat {
            let count = totalLength / MemoryLayout<Float32>.size
            ptr.withMemoryRebound(to: Float32.self, capacity: count) { floatPtr in
                systemWriter.append(UnsafeBufferPointer(start: floatPtr, count: count))
            }
        } else {
            let count = totalLength / MemoryLayout<Int16>.size
            ptr.withMemoryRebound(to: Int16.self, capacity: count) { int16Ptr in
                systemWriter.appendInt16(UnsafeBufferPointer(start: int16Ptr, count: count))
            }
        }
        Logger.audio.debug("System frame: \(totalLength) bytes")
    }

    // MARK: - Mic audio (normalized via AudioConverter)

    private func handleMicAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return }

        let inputFormat = AVAudioFormat(streamDescription: asbd)!
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        // Extract AVAudioPCMBuffer from CMSampleBuffer
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            Logger.audio.error("Failed to create PCM buffer for mic audio")
            return
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Copy sample data from CMSampleBuffer into AVAudioPCMBuffer
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset = 0, totalLength = 0
        var rawPtr: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength,
            dataPointerOut: &rawPtr
        )
        guard status == kCMBlockBufferNoErr, let ptr = rawPtr else { return }

        // Copy raw bytes into the PCM buffer's audio buffer list
        if let channelData = pcmBuffer.floatChannelData {
            memcpy(channelData[0], ptr, totalLength)
        } else if let channelData = pcmBuffer.int16ChannelData {
            memcpy(channelData[0], ptr, totalLength)
        }

        do {
            let result = try micConverter.convert(pcmBuffer)
            result.samples.withUnsafeBufferPointer { micWriter.appendInt16($0) }
            Logger.audio.debug("Mic frame: \(frameCount) in → \(result.samples.count) out (48kHz mono)")
        } catch {
            Logger.audio.error("Mic audio conversion failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Format helpers (system audio only)

    private struct FormatInfo {
        let rate: Double
        let channels: UInt32
        let isFloat: Bool
        let bitsPerChannel: UInt32
    }

    private func formatInfo(from buf: CMSampleBuffer) -> FormatInfo? {
        guard let fmt = CMSampleBufferGetFormatDescription(buf),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return nil }
        let p = asbd.pointee
        return FormatInfo(
            rate: p.mSampleRate,
            channels: p.mChannelsPerFrame,
            isFloat: p.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            bitsPerChannel: p.mBitsPerChannel
        )
    }

    private func isFloatFormat(from buf: CMSampleBuffer) -> Bool {
        return formatInfo(from: buf)?.isFloat ?? true
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build`

Expected: Build succeeds. (No unit test for this change — AudioOutputHandler depends on ScreenCaptureKit which requires a live system. AudioConverter itself is already tested.)

- [ ] **Step 3: Commit**

```bash
git add AudioCaptureHelper/XPC/AudioOutputHandler.swift
git commit -m "feat: normalize mic audio via AudioConverter in AudioOutputHandler"
```

---

## Task 4: XPC Protocol — Add updateMicrophone Method

**Files:**
- Modify: `AudioCaptureProtocol/AudioCaptureProtocol.swift`
- Modify: `AudioCaptureHelper/XPC/AudioCaptureService.swift`
- Modify: `TranscriberApp/Services/AudioCaptureClient.swift`

- [ ] **Step 1: Add `updateMicrophone` to the XPC protocol**

In `AudioCaptureProtocol/AudioCaptureProtocol.swift`, add the new method to the protocol (after `status`):

```swift
    /// Update the microphone device on a live capture session.
    /// Reply: (success: Bool, errorMessage: String?)
    func updateMicrophone(
        deviceId: String,
        reply: @escaping (Bool, String?) -> Void
    )
```

- [ ] **Step 2: Implement `updateMicrophone` in AudioCaptureService**

In `AudioCaptureHelper/XPC/AudioCaptureService.swift`, add the implementation (after the `status` method at line 99):

```swift
    func updateMicrophone(
        deviceId: String,
        reply: @escaping (Bool, String?) -> Void
    ) {
        guard isCapturing, let stream else {
            reply(false, "No capture in progress")
            return
        }

        Logger.audio.info("Switching mic to: \(deviceId, privacy: .public)")

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        config.microphoneCaptureDeviceID = deviceId
        config.excludesCurrentProcessAudio = true
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        Task {
            do {
                try await stream.updateConfiguration(config)
                Logger.audio.info("Mic switched successfully to: \(deviceId, privacy: .public)")
                reply(true, nil)
            } catch {
                Logger.audio.error("Mic switch failed: \(error, privacy: .public)")
                reply(false, "Mic switch failed: \(error.localizedDescription)")
            }
        }
    }
```

- [ ] **Step 3: Add `updateMicrophone` async wrapper to AudioCaptureClient**

In `TranscriberApp/Services/AudioCaptureClient.swift`, add the method (after `stop()`, before `getConnection()`):

```swift
    func updateMicrophone(deviceId: String) async throws {
        let conn = try getConnection()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                cont.resume(throwing: CaptureError.micSwitchFailed(
                    "XPC connection failed: \(error.localizedDescription)"
                ))
            } as! AudioCaptureProtocol

            proxy.updateMicrophone(deviceId: deviceId) { success, errorMessage in
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: CaptureError.micSwitchFailed(
                        errorMessage ?? "Unknown error"
                    ))
                }
            }
        }
    }
```

Also add the new error case to the `CaptureError` enum:

```swift
    case micSwitchFailed(String)
```

And add the case to `errorDescription`:

```swift
        case .micSwitchFailed(let msg): return msg
```

- [ ] **Step 4: Build to verify compilation**

Run: `swift build`

Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add AudioCaptureProtocol/AudioCaptureProtocol.swift AudioCaptureHelper/XPC/AudioCaptureService.swift TranscriberApp/Services/AudioCaptureClient.swift
git commit -m "feat: add updateMicrophone XPC method for live mic switching"
```

---

## Task 5: MicSwitchDialog — SwiftUI View

**Files:**
- Create: `TranscriberApp/Views/MicSwitchDialog.swift`

- [ ] **Step 1: Create MicSwitchDialog**

Create `TranscriberApp/Views/MicSwitchDialog.swift`:

```swift
import SwiftUI
import TranscriberCore

struct MicSwitchDialog: View {
    @State private var selectedDeviceId: String?
    @State private var errorMessage: String?
    @State private var isSwitching = false

    let currentDeviceId: String?
    let devices: [AudioInputDevice]
    let onSwitch: (String?) async throws -> Void
    let onCancel: () -> Void

    init(
        currentDeviceId: String?,
        devices: [AudioInputDevice],
        onSwitch: @escaping (String?) async throws -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._selectedDeviceId = State(initialValue: currentDeviceId)
        self.currentDeviceId = currentDeviceId
        self.devices = devices
        self.onSwitch = onSwitch
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change Microphone")
                .font(.headline)

            MicrophonePicker(
                selectedDeviceId: $selectedDeviceId,
                devices: devices
            )

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Switch") { performSwitch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSwitching || selectedDeviceId == currentDeviceId)
            }
        }
        .padding()
        .frame(width: 380)
        .modifier(GlassBackgroundModifier(cornerRadius: 12))
    }

    private func performSwitch() {
        isSwitching = true
        errorMessage = nil
        Task {
            do {
                try await onSwitch(selectedDeviceId)
            } catch {
                errorMessage = error.localizedDescription
                isSwitching = false
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Views/MicSwitchDialog.swift
git commit -m "feat: add MicSwitchDialog SwiftUI view"
```

---

## Task 6: MicSwitchWindowController — NSPanel Controller

**Files:**
- Create: `TranscriberApp/Services/MicSwitchWindowController.swift`

- [ ] **Step 1: Create MicSwitchWindowController**

Create `TranscriberApp/Services/MicSwitchWindowController.swift`:

```swift
import AppKit
import SwiftUI
import TranscriberCore
import os

@MainActor
final class MicSwitchWindowController {
    static let shared = MicSwitchWindowController()
    private var panel: NSPanel?

    func show(
        currentDeviceId: String?,
        onSwitch: @escaping (String?) async throws -> Void
    ) {
        panel?.close()

        let devices = AudioDeviceEnumerator.availableDevices()
        let resolvedId = AudioDeviceEnumerator.resolveDeviceId(
            lastUsed: currentDeviceId, available: devices
        )

        let closePanel = { [weak self] in
            Logger.state.debug("Panel closed: MicSwitch")
            self?.panel?.close()
            self?.panel = nil
        }

        let dialog = MicSwitchDialog(
            currentDeviceId: resolvedId,
            devices: devices,
            onSwitch: { newDeviceId in
                try await onSwitch(newDeviceId)
                await MainActor.run { closePanel() }
            },
            onCancel: closePanel
        )

        let newPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "Change Microphone"
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        let hostingView = NSHostingView(rootView: dialog)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        newPanel.contentView = hostingView
        newPanel.isFloatingPanel = true
        newPanel.hidesOnDeactivate = false
        newPanel.becomesKeyOnlyIfNeeded = false
        newPanel.center()
        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.panel = newPanel
        Logger.state.debug("Panel shown: MicSwitch")
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Services/MicSwitchWindowController.swift
git commit -m "feat: add MicSwitchWindowController for mic switch panel"
```

---

## Task 7: Wire Up MenuView

**Files:**
- Modify: `TranscriberApp/Views/MenuView.swift`

- [ ] **Step 1: Add "Change Microphone..." menu item during recording**

In `TranscriberApp/Views/MenuView.swift`, add the mic switch item right after the recording toggle button (after line 28, before the `Divider()`):

```swift
        if appState.isRecording {
            Button("Change Microphone...") {
                MicSwitchWindowController.shared.show(
                    currentDeviceId: configManager.config.lastMicrophoneDeviceId
                ) { newDeviceId in
                    try await captureClient.updateMicrophone(deviceId: newDeviceId ?? "")
                    await MainActor.run {
                        configManager.update { $0.lastMicrophoneDeviceId = newDeviceId }
                    }
                }
            }
        }
```

The full `body` should read:

```swift
    var body: some View {
        if let errorText = appState.truncatedErrorMessage {
            Button("⚠ Error: \(errorText)") {}
                .disabled(true)
            Button("Dismiss Error") {
                Logger.state.debug("User dismissed error")
                appState.errorMessage = nil
            }
            Divider()
        }

        Button(appState.recordingToggleLabel) {
            Task { await toggleRecording() }
        }
        .disabled(appState.isTranscribing)

        if appState.isRecording {
            Button("Change Microphone...") {
                MicSwitchWindowController.shared.show(
                    currentDeviceId: configManager.config.lastMicrophoneDeviceId
                ) { newDeviceId in
                    try await captureClient.updateMicrophone(deviceId: newDeviceId ?? "")
                    await MainActor.run {
                        configManager.update { $0.lastMicrophoneDeviceId = newDeviceId }
                    }
                }
            }
        }

        Divider()

        Button("Open Recordings Folder") {
            let dir = URL(fileURLWithPath: configManager.config.recordingDirectory)
            NSWorkspace.shared.open(dir)
        }
        // ... rest unchanged
    }
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Views/MenuView.swift
git commit -m "feat: add Change Microphone menu item during recording"
```

---

## Task 8: Update Test Checklist

**Files:**
- Modify: `scripts/test-checklist.md`

- [ ] **Step 1: Read current test-checklist.md and add mic switch test cases**

Add the following section to `scripts/test-checklist.md`:

```markdown
## Mid-Recording Mic Switch

- [ ] Start recording on built-in mic → click "Change Microphone..." → select USB headset → click "Switch" → verify recording continues
- [ ] After switching, verify the transcription includes audio from both the original and new mic
- [ ] Open the mic WAV file in an audio editor — verify it's 48kHz mono throughout (no format glitch at switch point)
- [ ] Start on USB webcam mic (48kHz stereo) → switch to built-in mic (48kHz mono) → verify no corruption
- [ ] Switch to a device, then unplug it — verify recording continues on system audio and you can switch again
- [ ] Verify "Change Microphone..." only appears in menu during active recording
- [ ] Verify level meter in switch dialog shows live levels for the selected (not-yet-switched) device
- [ ] Verify Cancel dismisses the dialog without switching
- [ ] Verify selecting the same mic that's already active disables the Switch button
```

- [ ] **Step 2: Commit**

```bash
git add scripts/test-checklist.md
git commit -m "docs: add mid-recording mic switch test cases to checklist"
```

---

## Task 9: Run All Tests + Build Verification

- [ ] **Step 1: Run the full test suite**

Run: `swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/`

Expected: All tests pass (existing 102 + new AudioConverter tests).

- [ ] **Step 2: Clean build**

Run: `swift build`

Expected: Build succeeds with no warnings related to the new code.

- [ ] **Step 3: Verify git status is clean**

Run: `git status`

Expected: Working tree clean, all changes committed.
