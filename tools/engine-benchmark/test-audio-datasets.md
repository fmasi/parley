# ASR Benchmark Test Audio Datasets

Reference for audio files and datasets used to benchmark speech-to-text engines.

---

## 1. Standard ASR Benchmark Datasets

These are the datasets used by the [Open ASR Leaderboard](https://huggingface.co/blog/open-asr-leaderboard) (60+ models, 11 datasets) to compare Whisper, Parakeet, Canary, etc.

### LibriSpeech (English, read speech)

The de-facto standard English ASR benchmark. ~1000 hours of 16kHz read audiobook speech (FLAC format).

| Split | URL | Size | Description |
|-------|-----|------|-------------|
| test-clean | `https://openslr.trmal.net/resources/12/test-clean.tar.gz` | 346 MB | Clean speech test set |
| test-other | `https://openslr.trmal.net/resources/12/test-other.tar.gz` | 328 MB | Challenging speech test set (accents, noise) |
| dev-clean | `https://openslr.trmal.net/resources/12/dev-clean.tar.gz` | 337 MB | Clean speech dev set |
| dev-other | `https://openslr.trmal.net/resources/12/dev-other.tar.gz` | 314 MB | Challenging speech dev set |

- **License:** CC BY 4.0
- **Ground truth:** Yes, orthographic transcripts included in tar
- **Format:** FLAC files, 16kHz, with `.trans.txt` transcript files
- **Source:** https://www.openslr.org/12
- **HuggingFace:** https://huggingface.co/datasets/openslr/librispeech_asr

```bash
# Download and extract test-clean (~5.4h of audio, 40 speakers)
curl -L -O https://openslr.trmal.net/resources/12/test-clean.tar.gz
tar -xzf test-clean.tar.gz
# Structure: LibriSpeech/test-clean/{speaker_id}/{chapter_id}/{speaker}-{chapter}-{utterance}.flac
```

### TED-LIUM 3 (English, conference talks)

~452 hours of English TED Talk speech. Single-speaker, clear but with natural disfluencies.

| Split | URL | Size |
|-------|-----|------|
| Full dataset | `https://openslr.trmal.net/resources/51/TEDLIUM_release-3.tgz` | ~50 GB |

- **License:** CC BY-NC-ND 3.0
- **Ground truth:** Yes, STM format transcripts
- **Source:** https://www.openslr.org/51
- **HuggingFace:** https://huggingface.co/datasets/LIUM/tedlium

### Earnings21 / Earnings22 (English, earnings calls -- "ASR in the wild")

Real-world multi-speaker earnings calls with domain-specific vocabulary, accents, telephony audio.

| Dataset | Files | Hours | Description |
|---------|-------|-------|-------------|
| Earnings21 | 44 | ~39h | US earnings calls, 2020 |
| Earnings22 | 125 | ~119h | Global earnings calls, accented English |

- **License:** CC BY-SA 4.0
- **Ground truth:** Yes, with speaker labels, punctuation, entity tags
- **Source:** https://github.com/revdotcom/speech-datasets (requires Git LFS)
- **HuggingFace:** https://huggingface.co/datasets/Revai/earnings21, https://huggingface.co/datasets/distil-whisper/earnings22

### Other Leaderboard Datasets

| Dataset | Type | Hours | Source |
|---------|------|-------|--------|
| GigaSpeech | Podcasts, YouTube, audiobooks | 10,000h | https://github.com/SpeechColab/GigaSpeech |
| SPGISpeech | S&P earnings calls (professional transcription) | 5,000h | https://datasets.kensho.com/datasets/spgispeech |
| VoxPopuli | European Parliament proceedings (16 languages) | 400k+ h | https://github.com/facebookresearch/voxpopuli |
| Common Voice | Crowd-sourced, 100+ languages | Varies | https://commonvoice.mozilla.org/datasets |

---

## 2. Multilingual / Code-Switching Datasets

### FLEURS (102 languages)

Google's multilingual benchmark. ~12 hours per language, 102 languages. The speech version of FLoRes MT benchmark.

- **Languages:** 102 including English, French, Portuguese, Spanish
- **License:** CC BY 4.0
- **Ground truth:** Yes
- **HuggingFace:** https://huggingface.co/datasets/google/fleurs
- **Note:** No single-file download; use HuggingFace datasets library

```python
from datasets import load_dataset
# Load French test split
fleurs_fr = load_dataset("google/fleurs", "fr_fr", split="test")
# Load Portuguese test split
fleurs_pt = load_dataset("google/fleurs", "pt_br", split="test")
```

### Multilingual TEDx (mTEDx)

TEDx talks in 8 languages with sentence-level aligned transcripts. Large files (full corpora).

| Language | URL | Size |
|----------|-----|------|
| French | `https://openslr.trmal.net/resources/100/mtedx_fr.tgz` | 34 GB |
| Portuguese | `https://openslr.trmal.net/resources/100/mtedx_pt.tgz` | 29 GB |
| Spanish | `https://openslr.trmal.net/resources/100/mtedx_es.tgz` | 35 GB |
| German | `https://openslr.trmal.net/resources/100/mtedx_de.tgz` | 2.6 GB |
| Arabic | `https://openslr.trmal.net/resources/100/mtedx_ar.tgz` | 3.6 GB |

- **License:** CC BY-NC-ND 4.0
- **Ground truth:** Yes, sentence-aligned transcripts
- **Source:** https://www.openslr.org/100

### SwitchLingua (Code-Switching, 12 languages)

The largest open-source code-switching dataset: 420K text samples + 80+ hours of audio, 12 languages, 63 ethnic groups.

- **Languages:** 12 languages including French (English-French pairs available)
- **License:** Check repository
- **Ground truth:** Yes
- **GitHub:** https://github.com/Shelton1013/SwitchLingua
- **HuggingFace Audio:** https://huggingface.co/datasets/Shelton1013/SwitchLingua_audio

### CS-FLEURS (Code-Switching, 52 languages)

Massively multilingual code-switched ASR dataset: 52 languages, 113 code-switched pairs.

- **Subsets:** CS-FLEURS-READ (14 X-English pairs), CS-FLEURS-XTTS (76 pairs), CS-FLEURS-MMS (45 pairs)
- **Paper:** https://www.isca-archive.org/interspeech_2025/yan25c_interspeech.pdf

### OpenSLR Code-Switching (Hindi-English, Bengali-English)

| Split | URL | Size |
|-------|-----|------|
| Hindi-English test | `https://openslr.trmal.net/resources/104/Hindi-English_test.tar.gz` | 443 MB |
| Bengali-English test | `https://openslr.trmal.net/resources/104/Bengali-English_test.tar.gz` | 606 MB |

- **License:** CC BY-SA 4.0
- **Ground truth:** Yes
- **Format:** WAV, 16kHz, 16-bit
- **Source:** https://www.openslr.org/104

---

## 3. Meeting-Style Multi-Speaker Recordings

### AMI Meeting Corpus

100 hours of meeting recordings with multiple synchronized signals (close-talking mics, far-field mics, video).

- **Speakers:** Multi-speaker (typically 4 per meeting)
- **Ground truth:** Yes, orthographic transcripts + dialogue acts + speaker labels
- **License:** CC BY 4.0
- **Download:** https://groups.inf.ed.ac.uk/ami/download/
- **OpenSLR mirror:** https://www.openslr.org/16
- **HuggingFace:** https://huggingface.co/datasets/diarizers-community/ami

### ICSI Meeting Corpus

Natural meeting recordings from UC Berkeley. Close-talking and mixed WAV files.

- **Ground truth:** Yes, orthographic transcripts + dialogue acts
- **Download:** https://groups.inf.ed.ac.uk/ami/icsi/download/

### VoxConverse (Diarization benchmark)

Multi-speaker clips from YouTube videos. Audio-visual diarisation dataset.

- **Ground truth:** RTTM diarization annotations (speaker segments, not full transcripts)
- **GitHub:** https://github.com/joonson/voxconverse
- **HuggingFace:** https://huggingface.co/datasets/diarizers-community/voxconverse

### CALLHOME (Multi-language telephone conversations)

Telephone conversations in 5 languages: English (20.3h), Mandarin (20.3h), Japanese (18.7h), German (18.4h), Spanish (21.3h).

- **Ground truth:** Yes, transcripts with speaker labels
- **HuggingFace:** https://huggingface.co/datasets/talkbank/callhome

### Columbia Meeting Recorder

5-minute multi-speaker meeting excerpt with 6 participants, significant speaker overlap.

- **Format:** Stereo WAV, 16kHz
- **Ground truth:** Yes, timestamped transcript
- **Page:** https://www.ee.columbia.edu/~dpwe/sounds/mr/
- **Transcript:** https://www.ee.columbia.edu/~dpwe/sounds/mr/transcript.txt

---

## 4. Quick-Download Single Files for Immediate Testing

### A) English, Clear Speech (~2 min, clean)

**LibriVox Gettysburg Address** -- public domain, single speaker, clear narration.

```bash
# MP3 (2.4 MB, ~2.5 min, 128kbps, single speaker)
curl -L -o gettysburg.mp3 \
  "https://archive.org/download/gettysburg_johng_librivox/gettysburg_address.mp3"
```

- **Duration:** ~2.5 minutes
- **Language:** English
- **Ground truth:** The text of the Gettysburg Address is well-known (available at https://archive.org/stream/gettysburg_johng_librivox/gettysburg_address_1101_djvu.txt)
- **Quality:** Clean studio recording, male narrator

### B) English, Short Sentences (Harvard Sentences)

**Open Speech Repository** -- 8kHz WAV, Harvard sentence lists. Short clips (~30s each), good for quick WER tests.

```bash
# Female speaker, Harvard sentences, 8kHz WAV
curl -O https://www.voiptroubleshooter.com/open_speech/american/OSR_us_000_0010_8k.wav
# Male speaker
curl -O https://www.voiptroubleshooter.com/open_speech/american/OSR_us_000_0030_8k.wav
```

- **Duration:** ~30 seconds each
- **Format:** 16-bit PCM WAV, 8kHz (telephony quality)
- **Ground truth:** Harvard Sentences (standardized text, findable online)
- **Source:** https://www.voiptroubleshooter.com/open_speech/american.html

### C) Noisy/Challenging Audio

**Microsoft MS-SNSD** -- clean speech + noise files to generate noisy test audio at any SNR.

```bash
git clone https://github.com/microsoft/MS-SNSD.git
# Clean test files in: MS-SNSD/clean_test/
# Pre-mixed noisy test files in: MS-SNSD/noisy_test/
# All WAV, 16kHz
```

- **Ground truth:** Clean reference audio provided (for signal comparison, no text transcripts)
- **License:** MIT
- **Note:** No text transcripts -- use for testing noise robustness, not WER calculation

For noisy speech WITH transcripts, use LibriSpeech test-other (accented/noisy read speech with ground truth):

```bash
curl -L -O https://openslr.trmal.net/resources/12/test-other.tar.gz
tar -xzf test-other.tar.gz
# FLAC files with .trans.txt ground truth
```

### D) LibriSpeech Individual Utterances (Best for WER Testing)

Once you extract test-clean, individual utterances are available as FLAC files (~5-30 seconds each). For a quick single-file test:

```bash
# Download, extract, and pick one utterance
curl -L -O https://openslr.trmal.net/resources/12/test-clean.tar.gz
tar -xzf test-clean.tar.gz
# Example: speaker 1089, chapter 134686
ls LibriSpeech/test-clean/1089/134686/
# 1089-134686-0000.flac  1089-134686-0001.flac  ...  1089-134686-0000.trans.txt
```

### E) Multilingual Single Files

For single multilingual files, use the HuggingFace datasets-server API to fetch individual rows:

```bash
# Fetch a single French FLEURS utterance (returns JSON with audio URL)
curl -s "https://datasets-server.huggingface.co/rows?dataset=google/fleurs&config=fr_fr&split=test&offset=0&length=1" | python3 -c "
import json, sys
row = json.load(sys.stdin)['rows'][0]['row']
print('Text:', row['transcription'])
print('Audio URL:', row['audio'][0]['src'])
"

# Fetch a single Portuguese FLEURS utterance
curl -s "https://datasets-server.huggingface.co/rows?dataset=google/fleurs&config=pt_br&split=test&offset=0&length=1" | python3 -c "
import json, sys
row = json.load(sys.stdin)['rows'][0]['row']
print('Text:', row['transcription'])
print('Audio URL:', row['audio'][0]['src'])
"
```

- **Note:** Audio URLs from datasets-server are signed and expire after a few hours

---

## 5. Recommended Test Matrix for Engine Comparison

| Test Scenario | Dataset | Why |
|--------------|---------|-----|
| English baseline WER | LibriSpeech test-clean | Industry standard, every paper reports this |
| English challenging WER | LibriSpeech test-other | Accented/noisy speech |
| Real-world English | Earnings21 | Domain vocabulary, telephony, multiple speakers |
| French | FLEURS fr_fr or mTEDx French | Standardized multilingual benchmark |
| Portuguese | FLEURS pt_br or mTEDx Portuguese | Standardized multilingual benchmark |
| Spanish | FLEURS es_419 or mTEDx Spanish | Standardized multilingual benchmark |
| Code-switching | SwitchLingua or CS-FLEURS | Multi-language in single recording |
| Meeting diarization | AMI corpus | Multi-speaker with ground truth |
| Conference talks | TED-LIUM 3 | Natural speech, single speaker |

---

## 6. Current SOTA Reference (as of early 2026)

From the [Open ASR Leaderboard](https://huggingface.co/blog/open-asr-leaderboard) and [Northflank benchmarks](https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2026-benchmarks):

| Model | WER (avg) | Speed (RTFx) | Multilingual |
|-------|-----------|--------------|--------------|
| NVIDIA Canary Qwen 2.5B | 5.63% | -- | Yes |
| NVIDIA Parakeet CTC 1.1B | 6.68% | 2793x | English only |
| OpenAI Whisper Large v3 | 6.43% | 68x | 99 languages |

- **Leaderboard:** https://huggingface.co/spaces/hf-audio/open_asr_leaderboard
- **Evaluation scripts:** https://github.com/huggingface/open_asr_leaderboard
