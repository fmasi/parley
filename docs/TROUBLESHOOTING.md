# Troubleshooting & Issues Log

This document captures every significant bug, crash, and design decision encountered
during development, along with the root cause and fix. It exists so a new Claude instance
(or a new developer) has full context without re-discovering these issues.

---

## 1. pyannote `use_auth_token` deprecated

**Symptom:** `TypeError: Pipeline.from_pretrained() got an unexpected keyword argument 'use_auth_token'`

**Root cause:** pyannote.audio 3.x renamed the parameter from `use_auth_token` to `token`.

**Fix:** Changed `Pipeline.from_pretrained(..., use_auth_token=token)` to `Pipeline.from_pretrained(..., token=token)` in `transcribe.py`.

---

## 2. Audio sample count mismatch during diarization

**Symptom:** `AssertionError: 477888 != 480000` or similar mismatch when pyannote processes audio.

**Root cause:** pyannote expects audio at exactly 16kHz mono. Input files at slightly different sample rates produce sample counts that don't align to expected frame boundaries after naive resampling.

**Fix:** Pre-convert every input audio file to 16kHz mono WAV via ffmpeg before passing to pyannote:
```python
subprocess.run(["ffmpeg", "-i", input_path, "-ar", "16000", "-ac", "1", wav_path])
```

---

## 3. `DiarizeOutput` has no `itertracks` attribute

**Symptom:** `AttributeError: 'DiarizeOutput' object has no attribute 'itertracks'`

**Root cause:** pyannote 3.x wraps the diarization result in a `DiarizeOutput` dataclass. The actual `Annotation` object with `itertracks()` is nested inside as an attribute — but the attribute name changed between minor versions.

**Fix:** Runtime introspection — scan all attributes of the output object to find the one that has `itertracks`:
```python
if hasattr(output, "itertracks"):
    diarization = output
else:
    diarization = None
    for attr in vars(output) if hasattr(output, "__dict__") else []:
        val = getattr(output, attr)
        if hasattr(val, "itertracks"):
            diarization = val
            break
```

---

## 4. Whisper hallucination loops

**Symptom:** Transcripts contain dozens of repeated identical lines, e.g. "Thank you. Thank you. Thank you." repeated 50 times.

**Root cause:** Whisper's beam search gets stuck in a loop when the audio is silent or low-confidence. `condition_on_previous_text=True` (default) feeds the hallucinated output back as context, reinforcing the loop.

**Fix:** Three parameters combined in `mlx_whisper.transcribe()`:
```python
condition_on_previous_text=False,
compression_ratio_threshold=1.8,  # default 2.4 — stricter
no_speech_threshold=0.8,          # default 0.6 — stricter
```
Plus post-processing deduplication that removes consecutive identical segments.

---

## 5. GitHub email privacy block on push

**Symptom:** `push declined due to email privacy restrictions`

**Root cause:** GitHub account has "Keep my email address private" enabled. Git commits were using the real email address.

**Fix:** Use the GitHub no-reply email format in git config:
```bash
git config --global user.email "894368+fmasi@users.noreply.github.com"
```

---

## 6. `.gitignore` blocking `requirements-service.txt`

**Symptom:** `requirements-service.txt` was not being tracked by git.

**Root cause:** The `.gitignore` pattern `*.txt` matched all `.txt` files including requirements files.

**Fix:** Add a negation pattern after the `*.txt` line:
```
*.txt
!requirements*.txt
```

---

## 7. Silence detector tests failing — `torchaudio` not available

**Symptom:** `ModuleNotFoundError: No module named 'torchaudio'` in test suite.

**Root cause:** Silero VAD requires `torchaudio` to load the model. Tests were trying to load the real model.

**Fix:** Rewrote tests to mock the VAD model entirely instead of loading real Silero VAD. Also added `torchaudio` to `requirements-service.txt`.

---

## 8. `soundfile` not installed — audio capture guard

**Symptom:** `ImportError: No module named 'soundfile'` at runtime.

**Root cause:** `soundfile` was used in `audio_capture.py` but not guarded.

**Fix:** Added `SOUNDFILE_AVAILABLE` guard pattern matching the existing `AVFOUNDATION_AVAILABLE` pattern. Raises `RuntimeError` at write time (not import time) if missing.

---

## 9. Pipeline test off-by-one in subprocess args

**Symptom:** Integration test for pipeline was passing the wrong argument index for the audio path.

**Root cause:** The test's fake transcribe function used `args[0][2]` to get the audio path, but after adding the `-i` flag the audio path moved to `args[0][3]`.

**Fix:** Updated test to use `args[0][3]`.

---

## 10. AVAudioEngine `outputNode` tap crash — `_isInput` constraint

**Symptom:** `objc.error: com.apple.coreaudio.avfaudio - required condition is false: _isInput`

**Root cause:** `AVAudioEngine.outputNode()` is an output-only sink node. macOS enforces that only input nodes can have taps installed. The original design assumed tapping `outputNode` would capture system audio playback — this is not supported.

**Fix:** Removed `outputNode` tap entirely. Switched to mic-only recording. True system audio capture requires ScreenCaptureKit which has no Python/PyObjC bindings.

---

## 11. AVAudioEngine tap callback crashes with `ctypes.ArgumentError`

**Symptom:** `ctypes.ArgumentError: argument 1: TypeError: 'objc.varlist' object cannot be interpreted as ctypes.c_void_p`

**Root cause:** `AVAudioPCMBuffer.floatChannelData()` returns an `objc.varlist` (PyObjC's opaque wrapper for `float**`). Passing elements of this to `ctypes.cast()` fails because PyObjC objects are not raw C pointers.

**Fix:** Replaced the entire `AVAudioEngine` approach with `sounddevice` (PortAudio). `sounddevice` provides a clean Python callback API backed by the same CoreAudio stack, with no ctypes bridge required:
```python
stream = sd.InputStream(samplerate=16000, channels=1, dtype="float32", callback=_callback)
```

---

## 12. rumps menu item key lookup after title change

**Symptom:** After clicking "Stop Recording", the menu item title reverted to "Stop Recording" permanently (couldn't switch back to "Start Recording").

**Root cause:** `rumps` keys menu items in its internal dict by the **original title at creation time**. After `item.title = "Stop Recording"`, the dict key is still `"Start Recording"`. Calling `self.menu["Stop Recording"]` raises a `KeyError` silently, leaving the menu stuck.

**Fix:** Store a direct reference to the menu item at `__init__` time:
```python
self._record_item = rumps.MenuItem("Start Recording", callback=self.start_recording)
```
Then always use `self._record_item.title = ...` instead of dict lookup.

---

## 13. Audio output format `.m4a` — soundfile can only write WAV

**Symptom:** Recording completed but audio file was unreadable / had wrong format.

**Root cause:** `_build_output_path()` returned a path ending in `.m4a`. `soundfile.write()` only supports uncompressed formats (WAV, FLAC, etc.) and silently wrote invalid data or raised an error.

**Fix:** Changed extension to `.wav`.

---

## 14. Background process suspended — `SIGTTOU`

**Symptom:** `[1] + suspended (tty output) python service/main.py` when running with `&`.

**Root cause:** macOS sends `SIGTTOU` to background jobs that write to the controlling terminal. Even with stdout/stderr redirected, AppKit/rumps internally touches the tty when showing dialogs. The subprocess (`transcribe.py`) also tried to write progress bars.

**Fix (subprocess):** Capture subprocess stdout/stderr via `subprocess.PIPE` in `pipeline.py` and log via the service logger.

**Fix (service):** Run via launchd (which has no controlling terminal) or use `nohup python service/main.py &; disown` for testing.

---

## 15. Name prompt dialog hidden behind other windows

**Symptom:** Clicking "Start Recording" showed no dialog; the process appeared to hang. Dialog was actually behind other open windows.

**Root cause:** Menu bar apps (`LSUIElement`) are background agents. macOS does not bring them to the front automatically when they create dialogs.

**Fix:** Call `NSApp.activateIgnoringOtherApps_(True)` on the main thread before `rumps.Window().run()`.

---

## 16. Background thread AppKit calls — spinning beach ball / deadlock

**Symptom:** After clicking the dialog, spinning beach ball. App became unresponsive.

**Root cause:** An attempt to keep raising the dialog window used a background thread calling `NSApp.activateIgnoringOtherApps_()` and `win.orderFrontRegardless()` repeatedly. **AppKit is not thread-safe** — all UI calls must happen on the main thread. Calling them from a background thread while the main thread was blocked on `rumps.Window().run()` caused a deadlock.

**Fix:** Removed the threading approach entirely. Single `activateIgnoringOtherApps_` call on the main thread before `.run()` is sufficient.

---

## 17. Keyboard input goes to desktop instead of dialog text field

**Symptom:** Dialog appeared but typing selected files on the desktop instead of entering text in the dialog.

**Root cause:** The app was running as `NSApplicationActivationPolicyAccessory` (menu-bar-only mode). In this mode, the app can display windows but macOS does not route keyboard events to it — keyboard focus stays with whichever app was previously active.

**Fix:** Temporarily switch to `NSApplicationActivationPolicyRegular` before showing the dialog (causes dock icon to appear briefly), then switch back to `Accessory` after:
```python
NSApp.setActivationPolicy_(NSApplicationActivationPolicyRegular)
NSApp.activateIgnoringOtherApps_(True)
# ... show dialog ...
NSApp.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
```

---

## 18. rumps notification center — missing `Info.plist`

**Symptom:** `RuntimeError: Failed to setup the notification center. This issue occurs when the "Info.plist" file cannot be found or is missing "CFBundleIdentifier".`

**Root cause:** macOS notification center requires the app to have a bundle identifier. When running directly from the conda env (not a proper `.app` bundle), there is no `Info.plist`.

**Fix (one-time per conda env):**
```bash
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string "rumps"' \
  /opt/miniconda3/envs/transcribe/bin/Info.plist
```

---

## 19. `ffmpeg` not found when launched via launchd

**Symptom:** `FileNotFoundError: [Errno 2] No such file or directory: 'ffmpeg'` in transcription subprocess.

**Root cause:** launchd launches processes with a minimal `PATH` (`/usr/bin:/bin`). Homebrew (`/opt/homebrew/bin`) is not included, so `ffmpeg` can't be found even though it's installed.

**Fix:** Add an explicit `PATH` to the launchd plist's `EnvironmentVariables`:
```xml
<key>PATH</key>
<string>/opt/homebrew/bin:/opt/miniconda3/envs/transcribe/bin:/usr/local/bin:/usr/bin:/bin</string>
```

---

## 20. HF token committed to git in plist

**Symptom:** The filled-in `com.audio-transcribe.plist` (containing the real HuggingFace token) was tracked by git.

**Fix:**
1. Added `com.audio-transcribe.plist` to `.gitignore`
2. Created `com.audio-transcribe.plist.template` with placeholder values for new users to copy and fill in
3. Removed the plist from git tracking: `git rm --cached com.audio-transcribe.plist`

---

## Architecture Decisions & Rationale

### Why sounddevice instead of AVAudioEngine?
AVAudioEngine via PyObjC is too fragile — the buffer callback delivers `objc.varlist` objects that can't be bridged to numpy via ctypes on Python 3.14. `sounddevice` wraps the same CoreAudio stack through PortAudio with a clean Python API.

### Why mic-only (no system audio)?
System audio capture on macOS without a virtual audio device (BlackHole) requires ScreenCaptureKit, which has no Python bindings. The user explicitly did not want to use BlackHole.

### Why AppKit + PyObjC instead of SwiftUI?
More Python-native, better suited for iterative development in a Python project. Claude Opus 4.6 has stronger AppKit knowledge than SwiftUI.

### Why launchd instead of running from terminal?
launchd launches apps without a controlling terminal, eliminating SIGTTOU issues and AppKit focus problems that occur with shell background jobs. It also auto-starts on login.

### Why sequential job queue?
The workload (one recording at a time) doesn't benefit from parallelism. The queue is designed so `ThreadPoolExecutor` can be swapped in later without changing callers.
