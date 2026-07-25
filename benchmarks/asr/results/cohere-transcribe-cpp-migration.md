# Cohere transcribe.cpp Migration Benchmark Record

> Status: IMMUTABLE OWNED RELEASE MEASURED
> Date: 2026-07-25

## Required target run

The release gate requires one representative fixture for each of English,
German, Japanese, and Chinese, run without language hints through the shipping
`macparakeet-cli`. Record cold first-transcript latency, warm transcription
time, realtime factor, and peak RSS with
`cohere_multilingual_speed.py`.

The `DudeMeister23/transcribe.cpp` fork has an arm64-only build lane
and model-backed unhinted transcription tests. Cohere has no native
language-identification head, so MacParakeet classifies the returned text
locally. The framework was measured through the actual MacParakeet CLI, then
published byte for byte as the immutable owned release artifact.

| Language | Fixture | Cold first transcript | Warm transcription | Realtime factor | Peak RSS |
|----------|---------|----------------------:|-------------------:|----------------:|---------:|
| English | `jfk.wav`, 11.000 s | 1.291 s | 0.392 s | 0.0357 (28.05x) | 1,841.9 MiB |
| German | `german.wav`, 29.336 s | 1.645 s | 0.771 s | 0.0263 (38.05x) | 1,865.9 MiB |
| Japanese | `ja.wav`, 7.224 s | 1.190 s | 0.313 s | 0.0433 (23.08x) | 1,835.2 MiB |
| Chinese | `zh.wav`, 5.616 s | 1.139 s | 0.272 s | 0.0484 (20.65x) | 1,832.4 MiB |

All cold and repeated transcripts matched the shipped fixture references.
No run passed a language hint. Each warm value is the per-file wall-time slope
from one process-cold input to a 12-copy process, which amortizes model-load
variance for short fixtures. Cold means a fresh process and fresh native
model/context; the OS file cache was not purged.

The run used an Apple M1 Max with 64 GB memory on arm64 macOS 27.0
(`26A5388g`), Metal compute, owned runtime commit
`51aa23592167cc32f8f3c5d2155d9f9937324c8d`, and immutable release archive
SHA-256
`caad2e1ce80801e5d0adb7e2bb9bcf8e7d1fd295657af281d8260d5dcc629350`.
The release tag is `macparakeet-v0.1.3-arm64.1`. GitHub reports the release as
immutable, and `gh release verify` validated its Sigstore attestation binding
the tag commit and artifact digest. A fresh download matched the measured
archive byte for byte.

## Historical CoreML comparison

The prior committed FluidAudio/CoreML Cohere reference measured about 73
seconds to the first transcript, about 11 times realtime after loading, and
about 11.6 GB peak RSS on an Apple M4 Pro with 48 GB RAM and macOS 15. Those
aggregate numbers were not recorded per language. German has no committed
speed row. Japanese and Chinese have committed accuracy evidence, not
per-language latency or memory evidence.

These values are historical comparison points only. They must not be labeled
as transcribe.cpp performance:

| Backend | English | German | Japanese | Chinese |
|---------|---------|--------|----------|---------|
| FluidAudio/CoreML cold, warm, peak | 73 s, about 11x, 11.6 GB | Not recorded | Not recorded | Not recorded |
| transcribe.cpp Q5_K_M immutable release | 1.291 s, 28.05x, 1.80 GiB | 1.645 s, 38.05x, 1.82 GiB | 1.190 s, 23.08x, 1.79 GiB | 1.139 s, 20.65x, 1.79 GiB |

## Reproduction command

```bash
python3 benchmarks/asr/cohere_multilingual_speed.py \
  --cli /absolute/path/to/macparakeet-cli \
  --artifact-zip /absolute/path/to/TranscribeCpp-macOS-arm64-v0.1.3-macparakeet.1.xcframework.zip \
  --fixture en=/absolute/path/to/english.wav \
  --fixture de=/absolute/path/to/german.wav \
  --fixture ja=/absolute/path/to/japanese.wav \
  --fixture zh=/absolute/path/to/chinese.wav \
  --warm-repetitions 12 \
  --output benchmarks/asr/results/cohere-transcribe-cpp-multilingual.json
```

Run on an idle system and record hardware and macOS version beside the output.
The script repeats each fixture inside a single CLI batch to isolate a warm
increment, never passes `--language`, disables history and diarization, and
captures peak process RSS with `/usr/bin/time -l`. Before measuring, it loads
the immutable runtime, artifact, model, fixture, and transcript pins from
`benchmarks/asr/cohere_transcribe_cpp_release.json`; hashes the local archive
and fixtures; and uses `gh release view` plus `gh release verify` to confirm the
immutable release and its Sigstore attestation.
