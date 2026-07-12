# mlx-qwen3-asr Deep-Dive Review

> Status: upstream repository review and MacParakeet recommendation<br>
> Date: 2026-07-11<br>
> Target: [`moona3k/mlx-qwen3-asr`](https://github.com/moona3k/mlx-qwen3-asr)<br>
> Inspected target SHA: [`d1a035514e1d6ac31da7658b273482656eacba61`](https://github.com/moona3k/mlx-qwen3-asr/commit/d1a035514e1d6ac31da7658b273482656eacba61)<br>
> Official-reference SHA: [`QwenLM/Qwen3-ASR@7c6daf7`](https://github.com/QwenLM/Qwen3-ASR/commit/7c6daf77a2421100f5fb066495372c00129d39ff)
> Related MacParakeet decision: [ADR-026](../../spec/adr/026-asr-engine-strategy.md)

## Verdict

`mlx-qwen3-asr` is a real, unusually thorough native-MLX implementation, not a
README-shaped wrapper. The core offline transcription path is credible and
worked end to end against the current official 0.6B checkpoint. The model
architecture tracks the official Qwen implementation in the places where
silent divergence is most dangerous: the encoder length formula, windowed
attention, interleaved MRoPE, Q/K normalization, audio-token injection, and
greedy decoder cache.

The repository is strong enough to use today as:

- a Python library or CLI for local Apple-Silicon batch transcription;
- a high-value Qwen3-ASR benchmark runner for MacParakeet's Phase 2 model
  comparison;
- a reference implementation for any future Swift/MLX port;
- a local development server after its upload-limit defects are fixed.

It is not yet a reason to add a third production runtime to MacParakeet. This
package is Python-first, uses the GPU/Metal path, and does not solve native Swift
embedding, sandbox/App Store packaging, scheduler integration, or GPU contention.
ADR-026's “new ADR” gate still applies.

My overall assessment is **strong core, credible research, maintenance release
needed around boundary contracts and evidence hygiene**.

## What It Actually Implements

The runtime is roughly:

```text
audio file / ndarray
  -> native WAV reader or ffmpeg resample to mono 16 kHz
  -> energy-aware chunks, normally at most 20 minutes
  -> native 128-bin log-mel frontend
  -> Qwen audio encoder (conv stem + windowed transformer)
  -> audio features injected at <|audio_pad|> prompt positions
  -> Qwen text decoder with interleaved MRoPE + KV cache
  -> language/text parser
  -> optional native MLX forced alignment
  -> optional pyannote diarization
  -> text / JSON / SRT / VTT / TSV, Python API, CLI, or HTTP API
```

The architecture description matches the current implementation and the
official PyTorch reference. The official code uses the same convolution output
length formula and interleaved MRoPE layout
([official encoder formula](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/qwen_asr/core/transformers_backend/modeling_qwen3_asr.py#L310-L317),
[official MRoPE](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/qwen_asr/core/transformers_backend/modeling_qwen3_asr.py#L786-L832)).
The MLX port implements the corresponding model structure rather than routing
through PyTorch ([architecture](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/docs/ARCHITECTURE.md#L5-L123)).

The public surface is broader than a typical research port:

- one-shot, batch, and async transcription;
- explicit `Session` ownership for repeated calls;
- native BPE tokenizer and mel frontend;
- fp16, bfloat16, 4-bit, and 8-bit loading/conversion;
- timestamps, subtitles, diarization, streaming, microphone capture;
- an OpenAI-compatible endpoint and an async job API.

## Verification Performed

All checks ran in a temporary clone and isolated virtual environment. The
MacParakeet checkout was not used to build or execute the target repository.

### Current source gate

```text
ruff: pass
mypy typed core: pass
pytest: 526 passed, 3 skipped
collection: 528 tests
pip check: pass
```

The target's own `quality_gate.py --mode fast` passed. Live GitHub CI on the
same inspected SHA was also green for lint, the fast gate, PyPI core install,
PyPI diarization-extra install, and the enabled live diarization integration
job ([CI run](https://github.com/moona3k/mlx-qwen3-asr/actions/runs/29181640869),
[workflow](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/.github/workflows/ci.yml#L9-L102)).

### Real checkpoint smoke and latency

Using the current official `Qwen/Qwen3-ASR-0.6B` snapshot
`5eb144179a02acc5e5ba31e748d22b0cf3e303b0`:

```text
fixture: tests/fixtures/test_speech.wav (2.53325 seconds)
output:  "The quick brown fox jumps over the lazy dog."
language: English
finish:   eos, not truncated

M4 Pro, fp16, warm model, 5 measured runs:
mean:   0.4360 s
median: 0.4328 s
RTF:    0.1721
```

This closely reproduces the repository's published short-clip fp16 claim of
about 0.46 seconds, so the basic performance story is believable
([published table](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/README.md#L244-L265)).

### Live project signals

At review time the project had 158 stars, 13 forks, one open issue, five GitHub
releases, and PyPI `0.3.5` was current. PyPI Stats reported roughly 5,984
downloads in the preceding month. Almost all code is maintained by one person,
with one merged external contribution. That is healthy early adoption, but the
bus factor remains one ([GitHub](https://github.com/moona3k/mlx-qwen3-asr),
[PyPI](https://pypi.org/project/mlx-qwen3-asr/),
[download API](https://pypistats.org/api/packages/mlx-qwen3-asr/recent)).

## What Is Strong

### 1. Correctness work is concentrated in the right places

The project correctly treats plausible-but-wrong inference as the main risk.
Its model code and tests explicitly cover MRoPE interleaving, Q/K normalization,
GQA, convolution weight transposition, audio placeholder injection, mel parity,
tokenizer parity, tied/partially quantized checkpoints, decoder termination,
and long-context encoder execution. Those are more valuable than a large pile
of shallow CLI tests.

### 2. The offline path is a deep module

The caller sees `transcribe()` or `Session.transcribe()`, while model resolution,
tokenization, chunking, alignment, generation stop reasons, GPU cleanup, and
output assembly stay behind that surface. Long-audio processing explicitly
releases per-chunk GPU tensors after a real user report of unbounded growth
([chunk loop and cleanup](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/mlx_qwen3_asr/transcribe.py#L643-L829)).

### 3. The dependency posture is disciplined

Core transcription depends on `mlx`, `numpy`, `regex`, and
`huggingface-hub`; PyTorch, FastAPI, sounddevice, alignment tokenizers, and
pyannote are extras ([package metadata](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/pyproject.toml#L24-L37)).
The native tokenizer and mel frontend reduce the usual Transformers dependency
and version-drift surface.

### 4. The benchmark archive is unusually broad

The repository contains 182 benchmark/evaluation artifacts covering
LibriSpeech, multilingual FLEURS, real-world AMI/Earnings22 samples,
long-form recordings, quantization, alignment, streaming stability, and MLX
versus PyTorch comparisons. A weekly 100-sample LibriSpeech WER/latency job has
been consistently green ([nightly workflow](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/.github/workflows/nightly-regression.yml#L17-L70)).

### 5. User-reported core failures have been handled quickly

The history shows concrete fixes for >4-minute truncation, runaway no-EOS
generation, long-audio GPU memory growth, pyannote 4 compatibility, and
mlx-community tied/partial-quant checkpoints. That is a much better maturity
signal than the raw star count.

## Prioritized Findings

### P1 — Non-16 kHz streaming input silently uses the wrong sample rate

`init_streaming(sample_rate=...)` accepts any positive rate and uses it to
derive chunk/context sizes, and the microphone CLI exposes
`--mic-sample-rate`. But the selected rate is not stored as a signal-processing
input and `_decode_chunk_incremental()` calls `compute_features(audio)` without
passing it. `compute_features()` therefore assumes 16 kHz and does not resample.
Valid 8 kHz, 44.1 kHz, or 48 kHz microphone input is interpreted with the wrong
time/frequency scale, producing silent quality failure rather than an error
([stream initialization](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/mlx_qwen3_asr/streaming.py#L97-L178),
[decode call](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/mlx_qwen3_asr/streaming.py#L407-L445),
[mel resampling contract](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/mlx_qwen3_asr/audio.py#L378-L422),
[microphone flag](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/mlx_qwen3_asr/cli.py#L694-L751)).

Fix: either enforce 16 kHz at the streaming boundary or store the source rate
and resample before buffering/feature extraction. Add an end-to-end test that
compares the same tone/speech at 8/16/48 kHz after normalization.

### P1 — The HTTP server does not enforce its advertised duration limit

`ServerConfig.max_duration_sec` is parsed, validated as positive, and
documented as returning `422` for overlong audio, but neither upload endpoint
ever measures or checks duration. Both endpoints read the entire upload into a
bytes object before checking its size, with a default cap of 2 GB. Capacity is
checked only after the upload is materialized and written to disk. A valid API
key can therefore bypass the eight-hour contract and create large transient
memory pressure even when the inference queue is already full
([server config](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/mlx_qwen3_asr/server.py#L61-L74),
[async upload path](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/mlx_qwen3_asr/server.py#L319-L389),
[OpenAI upload path](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/mlx_qwen3_asr/server.py#L448-L541),
[documented contract](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/docs/server/API-SPEC.md#L58-L96)).

Fix: reject at capacity before reading the body where possible, stream uploads
to a capped temp file, then probe decoded duration before queue admission. Test
both endpoints for duration rejection and cleanup.

### P1 — The long-media regression workflow has never exercised transcription

Every scheduled `Long Media Regression` run since the workflow began has
failed. The fixture is IEEE float WAV (`format tag 3`), while the workflow uses
Python's `wave` reader, which raises `wave.Error: unknown format: 3` before the
10-minute fixture is built. The ordinary nightly WER job is healthy, so this is
not evidence of a core transcription regression; it means the specific
multi-minute JSON/SRT gate provides no protection at all
([workflow](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/.github/workflows/long-media-regression.yml#L35-L111),
[representative failed run](https://github.com/moona3k/mlx-qwen3-asr/actions/runs/28785174959)).

Fix: generate/repeat the fixture with the package's native WAV parser,
`soundfile`, ffmpeg, or a committed PCM16 fixture, then require this job before
claiming continuous long-media coverage.

### P2 — Published memory requirements describe decoder labels, not runtime memory

The README says about 1.2 GB for “0.6B fp16” and 3.4 GB for “1.7B.” The current
official checkpoints contain 938,008,576 and 2,349,217,408 parameters,
respectively: about 1.75 GiB and 4.38 GiB of BF16/fp16 weights before temporary
buffers and caches. In the local 0.6B smoke, `/usr/bin/time -l` reported about
2.07 GB maximum RSS and a 6.22 GB peak memory footprint on the M4 Pro process.
The “0.6B/1.7B” names describe the text-model class, not the entire ASR stack
([README requirement](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/README.md#L35-L40),
[official 0.6B metadata](https://huggingface.co/api/models/Qwen/Qwen3-ASR-0.6B),
[official 1.7B metadata](https://huggingface.co/api/models/Qwen/Qwen3-ASR-1.7B)).

Fix: publish download size, resident parameter memory, measured peak RSS/footprint,
and timestamp/diarization add-ons separately. This matters for 8 GB and 16 GB
Macs and for any MacParakeet runtime decision.

### P2 — Benchmark artifacts are broad but not self-authenticating

The headline artifacts record model ID, dtype, sample rows, WER/CER, and
latency, but generally omit target git SHA, model snapshot revision, package
versions, hardware/OS, generation time, and dirty-tree state. Many committed
manifest rows contain absolute `/Users/dmoon/...` audio paths. The results are
inspectable but not fully reproducible from the artifact alone
([LibriSpeech payload](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/scripts/eval_librispeech.py#L308-L332),
[manifest-quality payload](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/scripts/eval_manifest_quality.py#L327-L350),
[microbenchmark payload](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/scripts/benchmark_asr.py#L106-L136)).

Fix: define a shared provenance envelope (`schema_version`, generated UTC,
git SHA/dirty, Python/MLX versions, model revision, machine/OS, dataset builder
version/seed) and make dataset paths logical or cache-relative.

### P2 — Documentation has crossed from rich into contradictory

The README is mostly current, but the contributor guide still calls the project
v0.1.0, reports 441 tests, references a nonexistent `test_audio.wav`, claims a
Hugging Face mel fallback that was removed, and describes a PyTorch aligner
fallback after the runtime became native-only. The README says 462 tests while
the current gate runs 526. It also says all 52 language/dialect variants are
“validated,” while the committed multilingual quality lane covers ten
languages; 52 is the upstream support count, not this port's validation count
([README test claim](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/README.md#L17-L40),
[validation scope](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/README.md#L283-L367),
[contributor guide](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/CLAUDE.md#L1-L109),
[broken smoke path](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/CLAUDE.md#L180-L205)).

Fix: one truth sweep, then add documentation integrity tests for version, test
fixture paths, runtime backend claims, and generated benchmark/test counts.

### P3 — CJK subtitle grouping has a known product-quality gap

Open issue #15 reports Chinese SRT cues split at exactly ten characters. That
matches the implementation: the default `max_words=10` is applied to forced
alignment units, which are often individual CJK characters. The joiner is
CJK-aware, but the grouping threshold is not
([issue #15](https://github.com/moona3k/mlx-qwen3-asr/issues/15),
[grouping logic](https://github.com/moona3k/mlx-qwen3-asr/blob/d1a035514e1d6ac31da7658b273482656eacba61/mlx_qwen3_asr/writers.py#L123-L189)).

Fix: use language-aware cue heuristics—characters/punctuation/display width for
CJK, word count for space-delimited languages—and test real Chinese/Japanese
subtitle sequences.

## Benchmark Interpretation

The repository's own numbers are good evidence that this MLX port is near the
official PyTorch implementation. They are not sufficient to decide that Qwen3
beats MacParakeet's current engines:

- the LibriSpeech lanes use 100 speaker-balanced samples, not MacParakeet's
  complete benchmark protocol;
- normalization, datasets, chunking, and hardware/runtime differ;
- multilingual results are 10 samples per language, useful directionally but
  too small for product copy;
- memory numbers need correction before comparing operational cost;
- the strongest Qwen differentiation is likely CJK/noise/context bias, not
  English dictation latency against ANE-native Parakeet.

For MacParakeet, run Qwen3-ASR through the existing `benchmarks/asr` harness
with the same normalizer and datasets as Parakeet, Nemotron, Whisper, and Cohere.
The minimum useful matrix is:

1. 0.6B fp16, 0.6B q8, 1.7B fp16;
2. English clean/noisy, Korean, Japanese, Mandarin, and mixed meeting audio;
3. cold load, warm RTFx, peak RSS/footprint, model download size;
4. timestamps/aligner quality and cost;
5. 30/60-minute long-form memory stability;
6. context-vocabulary lift on MacParakeet's custom-vocab corpus;
7. streaming partial stability at the required 16 kHz input.

## MacParakeet Implication

This review corrects one stale sentence in the June landscape note: an
Apple-local Qwen3-ASR runtime does exist and is usable. It does **not** change
the accepted architecture decision:

- the target is Python/MLX rather than an in-process Swift production runtime;
- MacParakeet already has two runtime seats and ADR-026 requires a new ADR for
  a third;
- GPU ASR competes with any local MLX LLM work, while the default FluidAudio
  path stays on CoreML/ANE;
- native distribution, sandboxing, model lifecycle, scheduler admission,
  telemetry, and UI capability declarations remain integration work.

Recommended disposition:

- **Adopt now as an external benchmark/reference tool.** Add a Qwen runner to
  Phase 2 of `asr-benchmark-and-model-expansion` and compare on MacParakeet's
  corpus.
- **Do not embed this Python package in the shipped app.** Keep ADR-026 intact.
- **Revisit production integration only if Qwen wins a needed product lane by
  a material margin**—most plausibly CJK, domain-context accuracy, or meeting
  robustness—and a Swift-usable MLX path passes lifecycle/distribution review.
- **Use the server only for local development after P1 upload fixes**, not as a
  production or internet-facing service in its current form.

## Recommended Upstream 0.3.6 Scope

Keep the next release narrow:

1. Fix/enforce streaming sample-rate semantics.
2. Enforce server duration, stream upload size, and check capacity early.
3. Repair the long-media workflow and get its first green 10-minute JSON/SRT run.
4. Correct memory/download requirements from measured full-model data.
5. Add benchmark provenance and run the documentation truth sweep.
6. Resolve CJK subtitle grouping issue #15.

That would move the project from “excellent research implementation with a few
soft boundaries” to a dependable standalone Apple-Silicon ASR package without
expanding its architecture.
