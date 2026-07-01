# system-tap-spike — #103 Phase 1 device validation

Read-only spike for issue **#103** (replace the ScreenCaptureKit system-audio stream with a
Core Audio output tap). It answers the one empirical question the migration hinges on:

> Does a Core Audio **global output tap** capture **Continuity / telephony** call audio that
> ScreenCaptureKit returns at the noise floor (−57 dB) for?

It is deliberately standalone — its own SPM package, no `TranscriberCore`/FluidAudio
dependency, nothing wired into the app. It stands up `AudioHardwareCreateProcessTap` +
`CATapDescription(stereoGlobalTapButExcludeProcesses: [])` + a private aggregate device, pulls
the captured system output via an `AudioDeviceIOProc`, writes a mono 16-bit WAV, and prints
**live RMS in dBFS once per second** so you can watch the system channel during a real call.

## Build

```bash
cd tools/system-tap-spike
bash build.sh            # build + assemble + ad-hoc sign dist/ParleySpike.app
```

A bare `swift run` will **not** work: the System Audio Recording TCC grant is keyed off a code
signature + an `Info.plist` carrying `NSAudioCaptureUsageDescription`. `build.sh` packages a
minimal signed `.app` (stable bundle id `eu.fmasi.parley.spike`) and you run the **inner
binary** from Terminal — that keeps live stdout while TCC attributes capture to the bundle.

## Run

```bash
"dist/ParleySpike.app/Contents/MacOS/system-tap-spike"            # WAV → ~/Desktop/parley-tap-spike.wav
# or choose the output path:
"dist/ParleySpike.app/Contents/MacOS/system-tap-spike" /tmp/call.wav
```

On first run macOS shows the **System Audio Recording** permission prompt — allow it. Ctrl-C
stops cleanly (destroys the tap + aggregate device, finalizes the WAV).

## What to test (the actual validation)

For each source below, start the spike, play/hold audio for ~10 s, and read the `rms dBFS`
column:

1. **Baseline silence** — nothing playing. Expect roughly **−90 to −120 dBFS**.
2. **A known-good case** — play a YouTube video or a Zoom/Teams test call. Expect a large jump
   (tens of dB above the floor). Confirms the tap + WAV path works at all.
3. ⭐ **iPhone-relay cellular call** — answer an iPhone call **on the Mac** (Continuity / "answer
   on Mac"). This is the case SCK misses. **If the RMS jumps like case 2, #103 is validated.**
4. ⭐ **WhatsApp (or FaceTime) call** — same check for a VoIP app that may also live outside
   SCK's shareable-content audio.

Run cases 3 and 4 on **headphones/AirPods** to rule out the mic-bleed/speaker echo path — we
want to prove the *tap itself* captures the far end, not the room.

> ⚠️ Recording phone calls is legally sensitive (many jurisdictions require all-party consent).
> This is a local validation spike; treat any captured WAV accordingly.

## Interpreting results

| Observation | Meaning |
|---|---|
| Cases 3 & 4 RMS well above floor | ✅ Tap captures telephony — proceed to Phase 2 (`SystemTapSession` behind a flag). |
| Cases 3 & 4 stay at the floor while case 2 works | ❌ Telephony bypasses the output graph after all — revisit the plan before migrating. |
| **Everything** (incl. case 2) at the floor | TCC/signing issue, not an audio one — the grant didn't take. See below. |
| `AudioHardwareCreateProcessTap` error at startup | Missing System Audio Recording grant — allow the prompt, or reset TCC (below). |

## TCC / rebuild friction (expected)

Ad-hoc signatures change their cdhash on every rebuild, so the grant can be invalidated and
macOS may re-prompt — or silently keep denying. If capture goes silent after a rebuild:

```bash
tccutil reset All eu.fmasi.parley.spike    # then re-run and re-grant
```

## Cleanup

The spike destroys its tap + aggregate device on Ctrl-C, and sweeps any orphaned
`eu.fmasi.parley.spike.*` aggregate devices on startup (in case a prior run was killed). None
of this appears in Audio MIDI Setup (the aggregate is private).

## If validated → next

Phase 2 in `~/.claude/plans/continuity-call-capture.md`: add `SystemTapSession` in the XPC
helper behind a config flag, feeding `AudioOutputHandler.handleSystemAudio` (reuse
`AudioConverter`, shared timeline anchor, chunk rotation), plus a HAL listener on
`kAudioHardwarePropertyDefaultOutputDevice` for mid-call output switches.
