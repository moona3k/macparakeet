# Cohere Transcribe STT Research Brief

Last updated: 2026-06-19

Status: research complete; benchmark spike required before product commitment.

## Executive Takeaway

Cohere Transcribe is feasible to run locally and is a credible candidate for an
optional high-accuracy final transcript engine in MacParakeet. It should not
replace Parakeet as the default engine without MacParakeet corpus benchmarks.

The best MacParakeet-shaped runtime path is local MLX on Apple Silicon through a
native Swift wrapper, currently `mlx-audio-swift` on its `main` branch. The
reference/evaluation path is `transformers`; the server-throughput path is
vLLM. Cohere's hosted API should not be the default MacParakeet path because it
sends audio off-device and conflicts with the current local-first STT promise.

## Model Facts

Current public model: `cohere-transcribe-03-2026`.

Cohere describes it as a 2B-parameter audio-in/text-out ASR model released under
Apache 2.0, supporting 14 languages:

- English
- German
- French
- Italian
- Spanish
- Portuguese
- Greek
- Dutch
- Polish
- Vietnamese
- Chinese
- Arabic
- Japanese
- Korean

The model is a Conformer-style encoder-decoder ASR model. Cohere's docs state
that audio waveforms are converted to mel spectrograms, processed by a Conformer
encoder, then decoded to text tokens by a lightweight Transformer decoder.

Important limitations:

- It expects a single pre-specified language and has no explicit automatic
  language detection.
- It does not provide timestamps.
- It does not provide speaker diarization.
- It can hallucinate on silence/non-speech unless paired with a noise gate or
  VAD.

Sources:

- Cohere model docs:
  https://docs.cohere.com/docs/transcribe
- Cohere release notes:
  https://docs.cohere.com/changelog
- Hugging Face model card:
  https://huggingface.co/CohereLabs/cohere-transcribe-03-2026
- Hugging Face technical blog:
  https://huggingface.co/blog/CohereLabs/cohere-transcribe-03-2026-release

## Accuracy And Speed Claims

Cohere's model card reports:

- Mean WER: 5.42 on the Hugging Face Open ASR Leaderboard
- RTFx: 524.88
- English leaderboard comparison that places Cohere ahead of Whisper Large v3
  on the cited benchmark table

That is strong evidence that Cohere is a serious final-transcript model. It is
not enough evidence to claim it beats MacParakeet's current default on
MacParakeet's real workloads.

MacParakeet's authoritative STT spec currently documents Parakeet v3/v2 as:

- WER: about 2.5 percent for v3 multilingual and about 2.1 percent for v2
  English-only
- Speed: about 155x realtime on Apple Silicon
- Peak working RAM: about 66 MB per active Parakeet inference slot
- Output: word-level timestamps and confidence

Those numbers are from a different benchmark context than Cohere's leaderboard
numbers. Treat cross-source WER comparison as directional only. A same-corpus
MacParakeet benchmark is mandatory before any product claim.

Internal references:

- `spec/06-stt-engine.md`
- `docs/planning/2026-06-nemotron-stt-benchmark-report.md`

External references:

- https://huggingface.co/CohereLabs/cohere-transcribe-03-2026
- https://huggingface.co/blog/CohereLabs/cohere-transcribe-03-2026-release

## Local Availability

Cohere Transcribe is available as local open weights and not only as a hosted
Cohere API. The model card lists ecosystem support for:

- `transformers`
- vLLM
- `mlx-audio` for Apple Silicon
- a Rust implementation
- browser/WebGPU experiments
- downstream apps and minimal PyTorch implementations

The hosted Cohere API remains useful for quick experimentation, but its contract
is not the MacParakeet default path:

- Endpoint: `/v2/audio/transcriptions`
- Required `model`
- Required `language` in ISO-639-1 format
- Multipart file upload
- Supported file extensions include flac, mp3, mpeg, mpga, ogg, and wav
- Response is text
- Cohere docs list a 25 MB maximum file size for the API

MacParakeet core STT should remain local by default. ADR-002 says the core
product's transcription and dictation run on-device and audio never leaves the
device. A cloud Cohere mode would need separate product/ADR treatment as an
explicit user-configured cloud STT provider, not as a normal speech engine.

Internal reference:

- `spec/adr/002-local-only.md`

External references:

- https://docs.cohere.com/reference/create-audio-transcription
- https://docs.cohere.com/docs/transcribe
- https://huggingface.co/CohereLabs/cohere-transcribe-03-2026

## Runtime Options

### 1. MLXAudio Swift - best MacParakeet app candidate

`mlx-audio-swift` is the best current shape for a native MacParakeet spike
because it is Swift, local, Apple Silicon-oriented, async/await-friendly, and
does not require embedding Python or PyTorch.

The current `mlx-audio-swift` Cohere README documents:

- Product: `MLXAudioSTT`
- Supported model:
  `beshkenadze/cohere-transcribe-03-2026-mlx-fp16`
- Example flow:
  - load audio with `loadAudioArray(from: audioURL, sampleRate: 16000)`
  - load model with `CohereTranscribeModel.fromPretrained(...)`
  - call `model.generate(audio:)`
- `generateStream(audio:)` exists and yields tokens/results
- Input should be mono 16 kHz
- The Swift port currently enables punctuation and disables timestamps

Shipping caveat: the latest published GitHub release for `mlx-audio-swift`
observed during this research is `v0.1.2`, published 2026-03-14, while Cohere
Transcribe was announced on 2026-03-26. Cohere support is on `main`, whose HEAD
observed during this research was `3f6b0553188a921f635df54b5e20442001037336`.
A spike should pin a commit or wait for a tagged release; it should not depend
on a moving branch.

Toolchain caveat: current `mlx-audio-swift/main` uses Swift tools version 6.2
and depends on `mlx-swift`, `mlx-swift-lm`, `swift-transformers`, and
`swift-huggingface`. MacParakeet's root package is Swift tools version 5.9 and
currently depends on FluidAudio, GRDB, ArgumentParser, Sparkle, and optional
WhisperKit. Adding `mlx-audio-swift` therefore changes the dependency and
toolchain surface materially.

Sources:

- https://github.com/Blaizzy/mlx-audio-swift
- https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/CohereTranscribe/README.md
- https://github.com/Blaizzy/mlx-audio-swift/blob/main/Package.swift
- https://github.com/Blaizzy/mlx-audio-swift/releases/tag/v0.1.2
- https://huggingface.co/beshkenadze/cohere-transcribe-03-2026-mlx-fp16

### 2. `transformers` - best reference/evaluation path

The Hugging Face model card says Cohere Transcribe is supported natively in
`transformers` and recommends that path for offline inference. This is the best
path for a benchmark harness or behavior reference because it is closest to the
published model card examples.

It is not the right production app path for MacParakeet because it brings in
Python, PyTorch, audio Python packages, and a heavier distribution story than a
native Swift app should accept.

Source:

- https://huggingface.co/CohereLabs/cohere-transcribe-03-2026

### 3. vLLM - best server path

The Cohere model card recommends vLLM for production serving. vLLM's supported
model docs list `CohereAsrForConditionalGeneration` for Cohere Transcribe, and
the model card includes an OpenAI-compatible `/v1/audio/transcriptions` example.
Cohere's technical blog says vLLM work improved variable-length encoder handling
and produced up to 2x throughput improvement for the model in serving contexts.

This is not the right default path for MacParakeet because MacParakeet is a
local desktop app, not a server product. vLLM is valuable if we ever test a
self-hosted or enterprise server mode, but not for the app's normal STT engine.

Sources:

- https://huggingface.co/CohereLabs/cohere-transcribe-03-2026
- https://docs.vllm.ai/en/latest/models/supported_models/
- https://docs.vllm.ai/en/latest/contributing/model/transcription/
- https://huggingface.co/blog/CohereLabs/cohere-transcribe-03-2026-release

### 4. Other local ports - useful fallback/evaluation only

There are additional MLX, Rust, ONNX, and minimal PyTorch efforts. The most
interesting for MacParakeet evaluation is an int8 MLX conversion because the
fp16 MLX artifact is large.

The `beshkenadze` fp16 MLX conversion reports:

- Converted MLX fp16 weights
- Conversion artifacts only
- License metadata `other`, with usage/licensing delegated to the upstream
  Cohere model card
- Hugging Face size display around 4.13 GB

The `appautomaton/cohere-asr-mlx` repo reports:

- MLX-native int8 conversion
- Intended for local transcription with `mlx-speech`
- No PyTorch or cloud API dependency at inference time
- Apache 2.0 following the upstream model license
- Resampling to 16 kHz before transcribing

These may be useful for comparing memory/quality tradeoffs, but the Python
runtime shape is less directly aligned with MacParakeet than MLXAudio Swift.

Sources:

- https://huggingface.co/beshkenadze/cohere-transcribe-03-2026-mlx-fp16
- https://huggingface.co/appautomaton/cohere-asr-mlx
- https://github.com/second-state/cohere_transcribe_rs

## Streaming Semantics

Cohere should be treated as a final-pass transcript engine first.

Why:

- Cohere's public docs describe audio-in/text-out transcription, not a true
  frame-fed live microphone API.
- The model requires a language tag and is tuned for monolingual audio.
- The model does not provide timestamps.
- MLXAudio Swift has `generateStream(audio:)`, but this streams decoded tokens
  from an already-provided audio buffer. It is not equivalent to Nemotron-style
  live microphone streaming where the app feeds incremental samples into an
  active session.
- vLLM lists Cohere under transcription support, while realtime transcription
  support is documented for other architectures such as Voxtral Realtime and
  Qwen3-ASR Realtime.

MacParakeet implication:

- Dictation: feasible as "record utterance, transcribe after stop."
- File transcription: feasible.
- Meeting finalization: feasible.
- Live dictation preview or live meeting captions: not the first shipping goal.
  Treat any Cohere live preview as a later experiment.

Sources:

- https://docs.cohere.com/docs/transcribe
- https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/CohereTranscribe/README.md
- https://docs.vllm.ai/en/latest/models/supported_models/

## Product Fit For MacParakeet

Best product posture: optional local "Cohere Transcribe" engine for users who
prioritize final transcript quality and accept manual language selection.

Do not position it as:

- a Parakeet default replacement
- a live streaming engine
- a diarization engine
- a timestamped export engine
- an automatic language detection path

Expected UX:

- Engine selector tile: Cohere Transcribe
- Required language picker: no "auto" value
- Explicit model download: likely multi-GB
- Warning/copy: high-quality final text, no timestamps or speaker diarization
  from the ASR model, manual language required
- CLI: `transcribe --engine cohere --language en`

The no-timestamp limitation is the most important product compromise. It weakens
or removes:

- word/audio alignment
- SRT/VTT quality
- word-level speaker attribution
- precise transcript navigation
- confidence/timing-derived downstream features

MacParakeet can still store a Cohere transcript because `STTResult` already
allows empty `words`, and Nemotron is already a precedent for a fast local
engine without word timestamps surfaced through MacParakeet. But exports and
meeting artifacts need explicit degradation handling.

Internal references:

- `Sources/MacParakeetCore/STT/STTResult.swift`
- `spec/06-stt-engine.md`

## Architecture Fit

MacParakeet already has the right integration shape:

- `SpeechEnginePreference` for persisted engine selection
- `SpeechEngineSelection` for engine plus language
- one process-wide `STTRuntime`
- one `STTScheduler`
- two execution slots: dictation and background
- routed jobs for pinned meeting/session engine selection
- meeting leases that freeze the engine/language at recording start
- CLI per-invocation engine selection

Cohere should extend this path rather than create a separate service.

Implementation shape:

1. Add `.cohere` to `SpeechEnginePreference`.
2. Add a Cohere language catalog of the 14 supported ISO-639-1 codes.
3. Add `cohereDefaultLanguageKey`; default to `en`, not `nil`.
4. Add a `CohereEngine` actor around MLXAudio Swift.
5. Load local MLX weights explicitly; do not auto-download during a
   transcription job.
6. Normalize audio to mono 16 kHz.
7. Serialize inference initially to avoid unified-memory contention.
8. Return `STTResult(text: output.text, words: [], language: language,
   engine: .cohere, engineVariant: "cohere-transcribe-03-2026-mlx-fp16")`.
9. Add CLI model lifecycle support before GUI selection.
10. Add Settings model status/download row only after CLI proof.

Internal references:

- `Sources/MacParakeetCore/SpeechEnginePreference.swift`
- `Sources/MacParakeetCore/STT/STTRuntime.swift`
- `Sources/MacParakeetCore/STT/STTScheduler.swift`
- `Sources/CLI/Commands/TranscribeCommand.swift`
- `Sources/CLI/Commands/ModelsCommand.swift`
- `spec/adr/021-whisperkit-multilingual-stt.md`

## Risks And Open Questions

### 1. Benchmark truth

External benchmark results are promising but not enough. We need the same audio
through Parakeet v3, Parakeet v2, Nemotron, Whisper, and Cohere on the same
machine.

### 2. Memory and disk footprint

The fp16 MLX artifact is roughly 4 GB on Hugging Face and will use GPU/unified
memory at runtime. This is a much heavier desktop footprint than Parakeet's
CoreML/ANE path and heavier than the current Nemotron Beta download.

### 3. Runtime maturity

The Swift Cohere wrapper exists on `mlx-audio-swift/main`, but it is not in the
latest observed tagged release. Pinning and QA are mandatory.

### 4. Toolchain and dependency surface

Adding MLXAudio Swift introduces MLX Swift, MLX Swift LM, Hugging Face Swift,
and Transformers Swift dependencies. That is a substantial change to
MacParakeet's currently conservative STT dependency surface.

### 5. Distribution and licensing of converted weights

The upstream model is Apache 2.0, but the fp16 MLX conversion repo marks its
metadata as `other` and points back to upstream. Before shipping an automatic
download flow, verify whether MacParakeet should download from upstream,
download a conversion repo, host its own conversion, or require user-managed
weights.

### 6. No timestamps

This is not a cosmetic gap. It affects export, playback, speaker attribution,
and meeting artifact quality.

### 7. Silence and VAD

Cohere itself warns that the model benefits from VAD/noise gating to avoid
non-speech hallucination. MacParakeet already has VAD/speech-boundary work in
the meeting path; Cohere should use or extend those safeguards before broad
release.

## Benchmark Spike Plan

### Phase 0 - external harness

Goal: verify local Cohere works and produce apples-to-apples numbers before
touching product UI.

Use `transformers` or MLX Python first for reference:

- English dictation
- English meeting with names, owners, and product terms
- quiet microphone input
- code-switched or mixed-language sample
- long 10-30 minute recording
- one or two non-English languages from the supported set
- silence/noise sample

Metrics:

- WER/CER
- stop-to-final-text latency
- realtime factor
- cold model load time
- warm model latency
- peak memory
- disk footprint
- hallucination on silence
- punctuation quality
- named-entity handling

### Phase 1 - CLI-only MacParakeet spike

Goal: prove app-architecture fit without committing GUI product surface.

- Add `CohereEngine` behind a feature flag or branch-only experiment.
- Add `macparakeet-cli transcribe --engine cohere --language <code>`.
- Add model status/download/delete only as needed for the experiment.
- Keep Cohere final-pass only.

### Phase 2 - product decision

Ship only if:

- Cohere wins materially on final transcript quality for at least one important
  user segment.
- Memory remains acceptable on 16 GB Macs, with an explicit decision for 8 GB.
- No legal/distribution blocker exists for local weights.
- No app stability regression appears from MLX dependencies.
- Export/UI degradation for missing timestamps is explicit and tested.

### Phase 3 - GUI

If Phase 2 passes:

- Add Settings engine tile.
- Add required language picker.
- Add local model row.
- Add warning copy for no auto language detection and no timestamps.
- Update CLI docs and STT spec.

## Recommendation

Proceed with a benchmark spike, not a product integration yet.

Recommended first implementation target:

- MLXAudio Swift Cohere wrapper
- pinned commit
- local fp16 model first
- optional int8 comparison after fp16 proof
- CLI-only path
- final transcription only
- no live preview or timestamps claim

Recommended issue/support response:

> Cohere Transcribe is promising and it is available for local inference. The
> main product tradeoffs are explicit language selection, a much larger local
> model/runtime footprint, and no timestamps or diarization from the ASR model.
> The right next step is a MacParakeet benchmark spike against Parakeet,
> Nemotron, and Whisper on real dictation and meeting audio. If it wins cleanly,
> it fits our existing optional-engine architecture as a local final transcript
> engine.

## Reference Index

Primary model and API:

- Cohere Transcribe docs:
  https://docs.cohere.com/docs/transcribe
- Cohere Audio Transcriptions API:
  https://docs.cohere.com/reference/create-audio-transcription
- Cohere release notes:
  https://docs.cohere.com/changelog
- Hugging Face model card:
  https://huggingface.co/CohereLabs/cohere-transcribe-03-2026
- Hugging Face technical blog:
  https://huggingface.co/blog/CohereLabs/cohere-transcribe-03-2026-release

Local/runtime:

- MLXAudio Swift:
  https://github.com/Blaizzy/mlx-audio-swift
- MLXAudio Swift Cohere README:
  https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/CohereTranscribe/README.md
- MLXAudio Swift Package.swift:
  https://github.com/Blaizzy/mlx-audio-swift/blob/main/Package.swift
- MLX fp16 conversion:
  https://huggingface.co/beshkenadze/cohere-transcribe-03-2026-mlx-fp16
- MLX int8 conversion:
  https://huggingface.co/appautomaton/cohere-asr-mlx
- vLLM supported models:
  https://docs.vllm.ai/en/latest/models/supported_models/
- vLLM STT model support:
  https://docs.vllm.ai/en/latest/contributing/model/transcription/

MacParakeet architecture:

- `spec/06-stt-engine.md`
- `spec/adr/002-local-only.md`
- `spec/adr/021-whisperkit-multilingual-stt.md`
- `docs/planning/2026-06-nemotron-stt-benchmark-report.md`
