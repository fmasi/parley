#!/usr/bin/env python3
"""Download curated test audio files for ASR engine benchmarking.

Downloads:
  - English clean speech (LibriVox Gettysburg Address)
  - French, Portuguese, Spanish samples (FLEURS dataset)
  - English noisy/accented (Harvard sentences, 8kHz telephony)

Files saved to: ~/.audio-transcribe/benchmark/test-audio/
"""

import json
import os
import urllib.request
from pathlib import Path

TEST_DIR = Path.home() / ".audio-transcribe" / "benchmark" / "test-audio"
TEST_DIR.mkdir(parents=True, exist_ok=True)

GROUND_TRUTH = {}


def download(url: str, filename: str, description: str) -> bool:
    path = TEST_DIR / filename
    if path.exists():
        print(f"  [skip] {filename} already exists")
        return True
    print(f"  Downloading {description}...")
    try:
        urllib.request.urlretrieve(url, str(path))
        size_mb = path.stat().st_size / (1024 * 1024)
        print(f"  [done] {filename} ({size_mb:.1f} MB)")
        return True
    except Exception as e:
        print(f"  [fail] {filename}: {e}")
        return False


def download_fleurs(lang_code: str, lang_name: str, count: int = 5):
    """Download multiple FLEURS samples for a language."""
    print(f"\n  Fetching {count} {lang_name} samples from FLEURS...")
    try:
        url = f"https://datasets-server.huggingface.co/rows?dataset=google/fleurs&config={lang_code}&split=test&offset=0&length={count}"
        with urllib.request.urlopen(url) as resp:
            data = json.load(resp)

        transcripts = []
        for i, row_data in enumerate(data["rows"]):
            row = row_data["row"]
            audio_url = row["audio"][0]["src"]
            transcript = row["transcription"]
            filename = f"{lang_code.replace('_', '-')}-fleurs-{i:02d}.wav"
            path = TEST_DIR / filename
            if not path.exists():
                urllib.request.urlretrieve(audio_url, str(path))
            transcripts.append({"file": filename, "text": transcript})
            print(f"  [done] {filename}: {transcript[:60]}...")

        GROUND_TRUTH[lang_name] = transcripts
    except Exception as e:
        print(f"  [fail] FLEURS {lang_name}: {e}")


def main():
    print("╔═══════════════════════════════════════════╗")
    print("║  ASR Benchmark Test Audio Downloader      ║")
    print("╚═══════════════════════════════════════════╝")
    print(f"\nTarget: {TEST_DIR}")

    # English clean
    print("\n── English (clean speech) ──")
    download(
        "https://archive.org/download/gettysburg_johng_librivox/gettysburg_address.mp3",
        "en-clean-gettysburg.mp3",
        "Gettysburg Address (LibriVox, ~2.5 min)",
    )
    GROUND_TRUTH["English clean"] = "Four score and seven years ago our fathers brought forth on this continent..."

    # English telephony
    print("\n── English (telephony quality, 8kHz) ──")
    download(
        "https://www.voiptroubleshooter.com/open_speech/american/OSR_us_000_0010_8k.wav",
        "en-telephony-harvard.wav",
        "Harvard sentences (female, 8kHz)",
    )

    # FLEURS multilingual
    print("\n── French ──")
    download_fleurs("fr_fr", "French")

    print("\n── Portuguese ──")
    download_fleurs("pt_br", "Portuguese")

    print("\n── Spanish ──")
    download_fleurs("es_419", "Spanish")

    print("\n── Turkish ──")
    download_fleurs("tr_tr", "Turkish")

    print("\n── Finnish ──")
    download_fleurs("fi_fi", "Finnish")

    print("\n── Korean ──")
    download_fleurs("ko_kr", "Korean")

    print("\n── Japanese ──")
    download_fleurs("ja_jp", "Japanese")

    # Save ground truth
    gt_path = TEST_DIR / "ground-truth.json"
    with open(gt_path, "w") as f:
        json.dump(GROUND_TRUTH, f, indent=2, ensure_ascii=False)
    print(f"\nGround truth saved: {gt_path}")

    # Summary
    files = list(TEST_DIR.glob("*"))
    audio_files = [f for f in files if f.suffix in (".wav", ".mp3", ".flac")]
    total_mb = sum(f.stat().st_size for f in audio_files) / (1024 * 1024)
    print(f"\n══════ Complete ══════")
    print(f"  {len(audio_files)} audio files, {total_mb:.1f} MB total")
    print(f"  Location: {TEST_DIR}")
    print(f"\nTo benchmark all test files:")
    print(f"  for f in {TEST_DIR}/*.wav {TEST_DIR}/*.mp3; do")
    print(f'    swift run --package-path tools/engine-benchmark EngineBenchmark "$f" --engines fluid,speech')
    print(f"  done")


if __name__ == "__main__":
    main()
