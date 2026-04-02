#!/usr/bin/env python3
"""Download curated test audio files for ASR engine benchmarking.

Downloads from HuggingFace datasets-server API:
  - English: LibriSpeech (openslr/librispeech_asr)
  - French, Portuguese, Spanish: MLS (facebook/multilingual_librispeech)
  - Korean: Zeroth Korean (kresnik/zeroth_korean)
  - Multi-speaker: AMI Meeting Corpus (edinburghcstr/ami)

Files saved to: ~/.audio-transcribe/benchmark/test-audio/
"""

import json
import urllib.request
from pathlib import Path

TEST_DIR = Path.home() / ".audio-transcribe" / "benchmark" / "test-audio"
TEST_DIR.mkdir(parents=True, exist_ok=True)

GROUND_TRUTH = {}

# User-Agent required by some servers
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ASR-Benchmark/1.0"


def download(url: str, filename: str, description: str) -> bool:
    path = TEST_DIR / filename
    if path.exists():
        print(f"  [skip] {filename} already exists")
        return True
    print(f"  Downloading {description}...")
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req) as resp:
            data = resp.read()
        path.write_bytes(data)
        size_mb = path.stat().st_size / (1024 * 1024)
        print(f"  [done] {filename} ({size_mb:.1f} MB)")
        return True
    except Exception as e:
        print(f"  [fail] {filename}: {e}")
        return False


def download_hf_rows(
    dataset: str,
    config: str,
    split: str,
    lang_code: str,
    lang_name: str,
    text_key: str = "text",
    count: int = 5,
):
    """Download audio samples from HuggingFace datasets-server API."""
    print(f"\n  Fetching {count} {lang_name} samples from {dataset}...")
    try:
        url = (
            f"https://datasets-server.huggingface.co/rows"
            f"?dataset={dataset}&config={config}&split={split}"
            f"&offset=0&length={count}"
        )
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req) as resp:
            data = json.load(resp)

        transcripts = []
        for i, row_data in enumerate(data["rows"]):
            row = row_data["row"]
            audio_info = row["audio"]
            audio_url = audio_info[0]["src"] if isinstance(audio_info, list) else audio_info.get("src", "")
            transcript = row.get(text_key, "")
            filename = f"{lang_code}-{i:02d}.wav"
            path = TEST_DIR / filename
            if not path.exists():
                audio_req = urllib.request.Request(audio_url, headers={"User-Agent": UA})
                with urllib.request.urlopen(audio_req) as audio_resp:
                    path.write_bytes(audio_resp.read())
            size_kb = path.stat().st_size / 1024
            transcripts.append({"file": filename, "text": transcript})
            print(f"  [done] {filename} ({size_kb:.0f} KB): {transcript[:60]}...")

        GROUND_TRUTH[lang_name] = transcripts
    except Exception as e:
        print(f"  [fail] {lang_name}: {e}")


def download_ami_sample():
    """Download AMI meeting segments for diarization testing (multi-speaker)."""
    print("  Fetching AMI meeting samples from HuggingFace...")
    try:
        # Get a few consecutive utterances from the same meeting
        url = (
            "https://datasets-server.huggingface.co/rows"
            "?dataset=edinburghcstr/ami&config=ihm&split=test"
            "&offset=0&length=5"
        )
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req) as resp:
            data = json.load(resp)

        for i, row_data in enumerate(data["rows"]):
            row = row_data["row"]
            audio_url = row["audio"][0]["src"] if isinstance(row["audio"], list) else row["audio"].get("src", "")
            text = row.get("text", "")
            speaker = row.get("speaker_id", "unknown")
            filename = f"en-ami-{i:02d}.wav"
            path = TEST_DIR / filename
            if not path.exists():
                audio_req = urllib.request.Request(audio_url, headers={"User-Agent": UA})
                with urllib.request.urlopen(audio_req) as audio_resp:
                    path.write_bytes(audio_resp.read())
            size_kb = path.stat().st_size / 1024
            print(f"  [done] {filename} ({size_kb:.0f} KB) speaker={speaker}: {text[:50]}")

        GROUND_TRUTH["AMI meeting"] = [
            {"file": f"en-ami-{i:02d}.wav", "text": row_data["row"].get("text", ""), "speaker": row_data["row"].get("speaker_id", "")}
            for i, row_data in enumerate(data["rows"])
        ]
    except Exception as e:
        print(f"  [fail] AMI sample: {e}")


def main():
    print("╔═══════════════════════════════════════════╗")
    print("║  ASR Benchmark Test Audio Downloader      ║")
    print("╚═══════════════════════════════════════════╝")
    print(f"\nTarget: {TEST_DIR}")

    # English — LibriSpeech test-clean (openslr/librispeech_asr)
    print("\n── English (LibriSpeech) ──")
    download_hf_rows(
        dataset="openslr/librispeech_asr",
        config="clean",
        split="test",
        lang_code="en",
        lang_name="English",
        text_key="text",
        count=5,
    )

    # English — LibriVox Gettysburg Address (long-form)
    print("\n── English (long-form) ──")
    download(
        "https://archive.org/download/gettysburg_johng_librivox/gettysburg_address.mp3",
        "en-clean-gettysburg.mp3",
        "Gettysburg Address (LibriVox, ~2.5 min)",
    )

    # French — MLS (facebook/multilingual_librispeech)
    print("\n── French (MLS) ──")
    download_hf_rows(
        dataset="facebook/multilingual_librispeech",
        config="french",
        split="test",
        lang_code="fr",
        lang_name="French",
        text_key="transcript",
    )

    # Portuguese — MLS
    print("\n── Portuguese (MLS) ──")
    download_hf_rows(
        dataset="facebook/multilingual_librispeech",
        config="portuguese",
        split="test",
        lang_code="pt",
        lang_name="Portuguese",
        text_key="transcript",
    )

    # Spanish — MLS
    print("\n── Spanish (MLS) ──")
    download_hf_rows(
        dataset="facebook/multilingual_librispeech",
        config="spanish",
        split="test",
        lang_code="es",
        lang_name="Spanish",
        text_key="transcript",
    )

    # Korean — Zeroth Korean (kresnik/zeroth_korean)
    print("\n── Korean (Zeroth) ──")
    download_hf_rows(
        dataset="kresnik/zeroth_korean",
        config="default",
        split="test",
        lang_code="ko",
        lang_name="Korean",
        text_key="text",
    )

    # Multi-speaker meeting audio for diarization testing
    print("\n── Multi-speaker (AMI Meeting Corpus) ──")
    download_ami_sample()

    # Note about missing languages
    print("\n── Notes ──")
    print("  Turkish (tr) and Japanese (ja) require gated HuggingFace datasets.")
    print("  To add them, use `huggingface-cli login` and install the `datasets` library.")

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
    print(f"\nTo benchmark:")
    print(f"  # Single file:")
    print(f"  swift run --package-path tools/engine-benchmark EngineBenchmark <audio.wav> --ground-truth {gt_path}")
    print(f"\n  # Full matrix (all files, all engines):")
    print(f"  bash tools/engine-benchmark/run-benchmark-matrix.sh")
    print(f"\n  # With diarization:")
    print(f"  swift run --package-path tools/engine-benchmark EngineBenchmark <meeting.wav> --diarize")


if __name__ == "__main__":
    main()
