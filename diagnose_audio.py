"""Quick audio capture diagnostic — run from both terminal and via launchd to compare."""
import sys
import time
import numpy as np

try:
    import sounddevice as sd
except ImportError:
    print("ERROR: sounddevice not installed")
    sys.exit(1)

try:
    import soundfile as sf
    HAS_SF = True
except ImportError:
    HAS_SF = False

print(f"Python: {sys.executable}")
print(f"sounddevice version: {sd.__version__}")
print()

# List devices
print("=== Input devices ===")
devices = sd.query_devices()
for i, d in enumerate(devices):
    if d["max_input_channels"] > 0:
        marker = " <-- DEFAULT" if i == sd.default.device[0] else ""
        print(f"  [{i}] {d['name']} (in={d['max_input_channels']}, rate={d['default_samplerate']}){marker}")
print()

default_input = sd.query_devices(kind="input")
print(f"Default input device: {default_input['name']}")
print(f"Default sample rate:  {default_input['default_samplerate']} Hz")
print()

# Record 3 seconds
DURATION = 3
RATE = 16000
print(f"Recording {DURATION}s at {RATE} Hz mono...")
chunks = []

def callback(indata, frames, time_info, status):
    if status:
        print(f"  status: {status}")
    chunks.append(indata.copy())

with sd.InputStream(samplerate=RATE, channels=1, dtype="float32", callback=callback):
    time.sleep(DURATION)

audio = np.concatenate(chunks, axis=0) if chunks else np.zeros((RATE * DURATION, 1), dtype=np.float32)

rms = float(np.sqrt(np.mean(audio**2)))
peak = float(np.max(np.abs(audio)))
db = 20 * np.log10(rms + 1e-9)

print(f"Captured {len(audio)} samples ({len(audio)/RATE:.1f}s)")
print(f"RMS:  {rms:.6f}  ({db:.1f} dB)")
print(f"Peak: {peak:.6f}")
print()

if rms < 1e-6:
    print("RESULT: SILENT — microphone returning zeros")
    print("  Possible causes:")
    print("  - macOS audio session not available in this process context")
    print("  - Input device muted at system level")
    print("  - PortAudio not initialising CoreAudio correctly")
else:
    print(f"RESULT: AUDIO OK — signal detected at {db:.1f} dB")

if HAS_SF:
    out = "/tmp/diagnose_audio_test.wav"
    sf.write(out, audio, RATE)
    print(f"\nWrote test file: {out}")
    print("Play it to verify: afplay /tmp/diagnose_audio_test.wav")
