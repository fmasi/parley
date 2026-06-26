# Microphone capture — design & API tradeoff

**Status:** current (since #96). **Last updated:** 2026-06-26.

## Context

The mic must keep recording across audio **route changes** mid-session — AirPods connecting/disconnecting,
HFP↔A2DP transitions, USB devices appearing/vanishing. In #96 the mic was decoupled from the system-audio
`SCStream` onto its **own `AVCaptureSession`** (`AudioCaptureHelper/XPC/MicCaptureSession.swift`), so a mic
route change can no longer tear down system-audio capture.

A device test (2026-06-26, "Test B") then exposed a second problem: when a **pinned AirPods mic was
physically removed**, the mic went silent for ~40 s and never recovered. Root cause: we were detecting
device loss with the wrong events.

## Decision

**Capture the mic with `AVCaptureSession` (device-pinned), and detect device changes with a Core Audio HAL
property listener — not AVFoundation device notifications, and not a buffer watchdog.**

- **Capture:** `AVCaptureSession` + `AVCaptureAudioDataOutput`. Lets the user pin a *specific* input device
  (`AVCaptureDeviceInput`), gives `CMSampleBuffer`s with host-clock PTS (used for mic↔system timeline
  alignment, council HOL-1), and matches the capture-pipeline model we already use for system audio
  (ScreenCaptureKit).
- **Device-change detection:** `AudioObjectAddPropertyListenerBlock` on `kAudioObjectSystemObject` for
  `kAudioHardwarePropertyDevices` ('dev#', device set changed) and `kAudioHardwarePropertyDefaultInputDevice`
  ('dIn ', default input switched). This is the canonical macOS mechanism (it's the same HAL layer the
  higher-level audio APIs sit on) — event-driven, fires within milliseconds, needs no microphone TCC grant.

### Rejected alternatives

- **`AVCaptureDevice.wasDisconnectedNotification` / KVO on `isConnected` / `AVCaptureSession.runtimeErrorNotification`** —
  these are camera-oriented and **empirically do not fire for audio-input removal on macOS** (the device just
  stops delivering buffers, silently). This is the actual bug we hit. See `docs/gotchas.md`. (Apple Dev
  Forums 766106 documents the exact "pull EarPods from a MacBook" repro; resolution is to use Core Audio.)
- **`AVAudioSession.routeChangeNotification` (`.oldDeviceUnavailable`)** — the elegant iOS idiom, but
  `AVAudioSession` is **unavailable on native macOS** (Mac Catalyst only). Not an option here.
- **Buffer-delivery watchdog** (recover if no buffer for N seconds) — a polling proxy for an event the OS
  already emits. Tech debt; rejected in favour of the HAL listener.

## The device-selection philosophy (the direction this serves)

We currently make the user **pick** a mic only because we hadn't had a reliable way to auto-pick the right
one. The **ideal**: the user never thinks about mic selection — the app **follows the system default input**,
which macOS already chooses based on the active route (AirPods when connected, built-in otherwise). Manual
pinning stays as an **override that should rarely be needed**.

The HAL listener is precisely the mechanism that realises this ideal:

- **"System Default" mode (the default, ideal-world):** capture the current default input; on
  `kAudioHardwarePropertyDefaultInputDevice` change, rebuild on the **new** default. The mic always tracks
  whatever macOS considers correct — AirPods in → follow to AirPods; AirPods out → follow to built-in. No
  user action.
- **Explicit pin (override):** capture a specific device; on `kAudioHardwarePropertyDevices` change, if the
  pinned device vanished, fall back to default (and optionally re-pin when it returns).

So "fix the disconnect bug" and "deliver the auto-pick ideal" are the **same** change.

## When to revisit: switch the mic path to `AVAudioEngine`

`AVAudioEngine` (audio-graph API) is the other first-party way to capture the mic. Its `inputNode` +
`installTap` give `AVAudioPCMBuffer`s, and `AVAudioEngineConfigurationChangeNotification` **is** macOS-native
(unlike `AVAudioSession`). We did **not** choose it now because:

- Its headline advantage (native config-change notification) is just the **HAL surfaced one layer up** — we
  get the same signal, more precisely, by listening to the HAL directly. So it isn't "more correct."
- On macOS its `inputNode` is built around **following the default input**; pinning a *specific* device means
  dropping to the input node's AUHAL (`kAudioOutputUnitProperty_CurrentDevice`) — i.e. Core Audio anyway.
  Since explicit device choice is a current feature, `AVCaptureSession` models it more cleanly.
- Switching would rewrite the #96 mic path (built + reviewed across three council rounds) and rework the
  PTS-based timeline alignment — risk with no correctness gain today.

**Revisit `AVAudioEngine` when either becomes true:**

1. **We add live / real-time audio processing** — live noise cancellation, streaming (live) transcription,
   in-graph format conversion or effects. The audio graph is purpose-built for this; today we write WAV
   chunks and transcribe **offline**, so that advantage is unused.
2. **We fully commit to auto-follow-default** and explicit pinning becomes vestigial — `AVAudioEngine`'s
   inputNode is default-following by design, so that world tilts toward it.

Until one of those lands, `AVCaptureSession` + Core Audio HAL listener is the correct, lower-risk architecture.

## References

- `AudioCaptureHelper/XPC/MicCaptureSession.swift` — the mic session + (to be added) HAL listener.
- `TranscriberCore/AudioDeviceEnumerator.swift` — device enumeration (live `DiscoverySession`).
- `docs/gotchas.md` — "AVCaptureDevice disconnect notifications don't fire for audio input on macOS."
- Core Audio: `AudioHardware.h` / `AudioHardwareBase.h` (`kAudioHardwarePropertyDevices`,
  `kAudioHardwarePropertyDefaultInputDevice`, `kAudioDevicePropertyDeviceIsAlive`,
  `AudioObjectAddPropertyListenerBlock`).
- Apple Dev Forums 766106 (audio disconnect → use Core Audio), `AVAudioEngineConfigurationChangeNotification`
  (macOS 10.10+), `AVAudioSession` (no native macOS).
