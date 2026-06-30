# ASR Model Landscape for MacParakeet

Research date: 2026-06-30

Audience: product, engineering, and release reviewers deciding which speech
models should power MacParakeet's dictation, meetings, and file/media
transcription surfaces.

## Executive Readout

MacParakeet is no longer a single-model speech app. The current app exposes
seven selectable local ASR builds across four engine families:

1. Parakeet TDT 0.6B v3, the default multilingual Parakeet build.
2. Parakeet TDT 0.6B v2, an English-only TDT fallback for users who value
   English stability over language breadth.
3. Parakeet Unified EN 0.6B, an English-only, punctuated/capitalized Parakeet
   runtime with native live dictation partials but no word timings.
4. Nemotron 3.5 ASR Streaming 0.6B, a multilingual beta streaming build.
5. Nemotron Speech Streaming EN 0.6B, an English-only beta streaming build.
6. Whisper Large v3 Turbo through WhisperKit, MacParakeet's broad-language
   local fallback.
7. Cohere Transcribe through FluidAudio, a batch-only local accuracy engine.

The most important product distinction is not simply "which model has the
lowest WER." MacParakeet has four different ASR jobs with different failure
costs:

| Product surface | Primary success criterion | Capabilities that matter most |
| --- | --- | --- |
| System-wide dictation final paste | Low latency, no dropped final words, strong punctuation, predictable language behavior | Fast warm path, short-clip quality, trailing-silence robustness, language control, local execution |
| Dictation live preview | Useful rolling feedback without corrupting the final paste | Native streaming partials or cheap tail-window preview, graceful fallback, no slot starvation |
| Meeting live preview | Useful in-meeting transcript context while capture continues | Chunked/bounded inference, backpressure behavior, timestamps if speaker/segment UX depends on them |
| Meeting final transcript | Durable, searchable, exportable artifact | Long-audio quality, timestamp/word timing support, diarization compatibility, recovery/retranscribe behavior |
| File, folder, media URL transcription | Best offline accuracy and coverage over latency | Long-form robustness, multilingual coverage, timestamps/export support, controllable model lifecycle |

## Evaluation Rubric

Every ASR model should be reviewed against the same set of questions before it
is promoted as a default, recommended fallback, or experimental option.

| Dimension | What to ask | Why MacParakeet cares |
| --- | --- | --- |
| Recognition quality | What benchmark datasets, languages, domains, noise conditions, and audio lengths were measured? Are WER/CER claims vendor-reported or independent? | A model that wins LibriSpeech may still fail meetings, accents, crosstalk, or casual dictation. |
| Latency shape | What is cold start, warm first token/partial latency, real-time factor, and long-audio throughput on Apple Silicon? | Dictation needs fast stop-to-paste; file/media jobs can trade latency for quality. |
| Streaming semantics | Does the model emit native partials, chunk-level results, or only batch output? Are partials stable or volatile? | Live preview is display-only for dictation, but live meeting context shapes trust during capture. |
| Timestamps | Are word, token, segment, or no timestamps exposed? Are confidences available? | Word timings feed exports, transcript navigation, speaker labels, and visualizations. |
| Language behavior | Is language fixed, hinted, auto-detected, or unsupported? Does forced language improve or hurt results? | Wrong language detection is more damaging for dictation than a visible setup requirement. |
| Punctuation and casing | Does the model emit readable punctuation/capitalization natively, or does MacParakeet need post-processing? | Raw unpunctuated output is tolerable for some transcripts but poor for daily dictation. |
| Audio-length envelope | What happens at 30 seconds, 5 minutes, 60 minutes, and dense speech? Is chunking native or app-owned? | Meetings and media files need explicit long-audio strategy; silent truncation is unacceptable. |
| Runtime footprint | Download size, RAM, Core ML compile cost, ANE/GPU/CPU policy, concurrent-lane behavior. | MacParakeet must remain resident, local-first, and responsive while other jobs run. |
| Local/offline posture | Can the model run fully on-device? What network, telemetry, license, and redistribution constraints apply? | Local-first is a product promise, not an implementation detail. |
| Integration maturity | Is the model already in FluidAudio/WhisperKit with tested Swift surfaces, or would MacParakeet own conversion/runtime glue? | "Great model" is not enough if the app would inherit brittle model conversion or scheduler risk. |
| Recovery and observability | Can failures be diagnosed, retried, and attributed by engine and variant? | Support needs to know which engine produced a bad transcript and whether retranscription can help. |

## Current MacParakeet Inventory

This inventory is grounded in the current `origin/main` code used for this
branch, not older plans or memory.

| Engine/build | Current role in app | Live dictation preview | Meeting live preview | Word timings | Language behavior | Repo evidence |
| --- | --- | --- | --- | --- | --- | --- |
| Parakeet TDT 0.6B v3 | Default Parakeet build; multilingual default | Tail-window batch preview | Routed through meeting live chunks | Yes, through FluidAudio TDT path | App ignores `--language`; model auto behavior | `Sources/MacParakeetCore/STT/README.md`, `SpeechEnginePreference.swift` |
| Parakeet TDT 0.6B v2 | English-only Parakeet opt-in | Tail-window batch preview | Routed through meeting live chunks | Yes, through FluidAudio TDT path | Fixed English-only posture | `SpeechEnginePreference.swift`, `ParakeetModelVariant+ASR.swift` |
| Parakeet Unified EN 0.6B | English-only Parakeet variant; separate FluidAudio runtime | Native streaming partials, final still uses offline recorded-file result | Routed through meeting live chunks | No | Fixed English | `ParakeetUnifiedEngine.swift`, `STTRuntime.swift` |
| Nemotron 3.5 ASR Streaming 0.6B | Multilingual beta engine | Native streaming partials | Routed through meeting live chunks | Yes, from token timings when available | Optional language hint or auto | `NemotronEngine.swift`, `STTRuntime.swift` |
| Nemotron Speech Streaming EN 0.6B | English-only beta engine | Native streaming partials | Routed through meeting live chunks | Yes, from token timings when available | Fixed English | `NemotronEnglishEngine.swift`, `STTRuntime.swift` |
| Whisper Large v3 Turbo | Optional broad-language local fallback | Tail-window batch preview path exists; no native streaming session | Routed through meeting live chunks | Yes, through WhisperKit word timings | Hint or auto detect | `WhisperEngine.swift`, `docs/cli-testing.md` |
| Cohere Transcribe | Optional batch-only local accuracy engine | None; record-then-transcribe | Explicitly not routed to live preview chunks | No | Requires supported language hint/default; no auto detect | `CohereTranscribeEngine.swift`, `STTRuntime.swift`, `docs/cli-testing.md` |

## Product-Fit Chart

Legend: `++` strong fit, `+` usable, `0` constrained or situational, `-` poor
fit without additional product work.

| Engine/build | Dictation final | Dictation live preview | Meeting final | Meeting live preview | File/media transcription |
| --- | --- | --- | --- | --- | --- |
| Parakeet TDT v3 | ++ | + | ++ | + | + |
| Parakeet TDT v2 | ++ for English | + | + for English | + for English | + for English |
| Parakeet Unified EN | ++ for English readability | ++ | + but no word timings | 0 | + for English |
| Nemotron multilingual | + beta | ++ | + | + | + |
| Nemotron English | + beta for English | ++ | + for English | + for English | + for English |
| Whisper Large v3 Turbo | 0 to + depending language and cold state | 0 | + | 0 to + | ++ for broad language coverage |
| Cohere Transcribe | + for batch-only dictation | - | 0 to + plain text only | - | + when batch quality beats timestamp needs |

## Internal Constraints That Shape Recommendations

- Dictation final output is deliberately not taken from live partials. The app
  records the WAV and transcribes the recorded file for the final paste/history
  result; live partials are display-only.
- Active meetings capture the speech engine selection at session start. Switching
  engines mid-meeting is blocked because a single meeting transcript cannot
  safely mix incompatible timing/output formats.
- Meeting live chunks and meeting final transcription share the background STT
  lane. Meeting finalize outranks queued file transcription, while dictation has
  its own reserved interactive lane.
- Cohere is admitted as a batch-only engine in the scheduler/runtime and has no
  live dictation preview, no meeting live preview route, and no word timings.
- Whisper has word timestamps and a preview-capable sample path, but in this app
  it is not a native live dictation engine.
- Parakeet Unified and both Nemotron builds can drive native live dictation
  partials through `NativeLiveDictating`, but MacParakeet still treats those
  partials as preview, not the authoritative final result.

## Benchmark Reading Rules

Published ASR numbers are useful, but they are easy to misuse. The report uses
these rules when turning vendor model cards into product recommendations.

1. Do not compare WER across unrelated corpora as if it were a league table.
   LibriSpeech clean, AMI meetings, FLEURS, Common Voice, MLS, GigaSpeech, and
   earnings calls stress different things.
2. For Japanese, Mandarin, and other languages without whitespace-delimited
   words, CER is often more meaningful than WER. A high WER can be a tokenizer
   artifact rather than a failed transcript.
3. Treat "streaming" as three separate capabilities: native cache-aware
   streaming, buffered streaming that recomputes context, and repeated batch
   windows. They have different latency and battery costs.
4. Timestamp claims must say what level is exposed. Segment timestamps, token
   timings, word timings, and forced-alignment timestamps are not equivalent.
5. Core ML numbers matter more than CUDA/server numbers for MacParakeet's
   local-first Mac product, but Core ML conversions can change quality, cold
   start, memory footprint, and supported features.

## Supported Model Deep Dives

### Parakeet TDT 0.6B v3

Best current use: default local-first engine for users who want European
language coverage, word timings, and balanced meeting/file behavior.

NVIDIA describes Parakeet TDT v3 as a 600M-parameter FastConformer-TDT ASR
model covering English plus 24 European languages with punctuation,
capitalization, automatic language detection, and word/segment timestamp
support. The official model card reports English Open ASR leaderboard results
close to Parakeet v2, plus multilingual FLEURS/MLS/CoVoST numbers. FluidAudio's
Core ML conversion is the app-relevant runtime: it runs on-device on Apple
platforms after download, targets macOS 14+ and iOS 17+, and reports about
110x real-time factor on M4 Pro batch ASR.

MacParakeet implication: keep this as the "works for most local users" default,
but do not oversell it as universal multilingual ASR. Its coverage is European,
and language auto-detection can be more product-risky than an explicit English
model for short dictations.

### Parakeet TDT 0.6B v2

Best current use: English-only stability option when the user wants the TDT
path's word timings and wants to avoid multilingual mis-detection.

NVIDIA's v2 card describes a 600M English FastConformer-TDT model with
punctuation, capitalization, accurate word-level timestamps, and support for up
to 24 minutes in a full-attention pass. It is CC-BY-4.0 and commercial-ready.
The card reports strong English leaderboard WER but also shows quality drops
under noise, which matters for laptop microphones and meetings.

MacParakeet implication: v2 is still valuable even with newer English models
because it has the cleanest timestamp story in the existing Parakeet TDT path.
It should remain available for English meeting final transcripts and exports.

### Parakeet Unified EN 0.6B

Best current use: English dictation and English final transcripts where
readability matters more than word-level timings.

Parakeet Unified is a 600M FastConformer-RNNT model trained for both offline and
streaming inference. NVIDIA reports strong offline English WER and a smooth
latency/quality curve from about 2.08 seconds down to 160 ms. The caveat is
material: current inference is buffered streaming, which recomputes left
context, not cache-aware streaming. MacParakeet's implementation uses
FluidAudio's offline 15-second overlapping path for final output and a native
streaming manager for display partials. It does not expose word timings in the
current app.

MacParakeet implication: Unified is a strong English dictation/readability
option. It is not a drop-in replacement for timestamped meeting/export
workflows until the word-timing gap is solved.

### Nemotron Speech Streaming EN 0.6B

Best current use: English native live preview and English streaming beta
experiments.

NVIDIA describes the English Nemotron streaming model as a 600M
FastConformer-cache-aware-RNNT model with 80 ms, 160 ms, 560 ms, and 1120 ms
operating points. Unlike buffered streaming, it processes new chunks while
reusing encoder context. FluidAudio's Core ML conversion exposes the same tier
shape, with an int8 encoder around 564 MB and reported LibriSpeech test-clean
Core ML results that are strongest at 1120 ms and 560 ms. The low-latency 160
ms and 80 ms tiers are much weaker in the FluidAudio card and were tested on
only 20 files.

MacParakeet implication: the 1120 ms tier MacParakeet surfaces is the right
conservative beta choice. Resist the temptation to chase 80 ms UI responsiveness
unless the preview is explicitly labeled unstable and product QA proves users
prefer speed over obvious errors.

### Nemotron 3.5 ASR Streaming 0.6B

Best current use: multilingual native live preview where Parakeet v3's
European-only coverage is too narrow and beta risk is acceptable.

NVIDIA's multilingual Nemotron 3.5 ASR card describes a 600M
FastConformer-cache-aware-RNNT model with language-ID prompt conditioning,
optional auto language detection, punctuation/capitalization, and configurable
80/160/320/560/1120 ms chunks. It lists 40 language-locales across three tiers:
19 transcription-ready, 13 broad-coverage, and 8 adaptation-ready. The last
tier is important: those languages require fine-tuning for full transcription.
The model card also recommends the English-only Nemotron model for English-only
use.

MacParakeet implication: this is the right strategic direction for live
multilingual preview, but not a blanket "40 languages solved" claim. Product UI
and docs should distinguish transcription-ready, broad-coverage, and
adaptation-ready quality tiers.

### Whisper Large v3 Turbo through WhisperKit

Best current use: broad-language fallback for file/media transcription and
retranscription when Parakeet/Nemotron language coverage is insufficient.

OpenAI's Whisper model card frames Whisper as a weakly supervised
sequence-to-sequence model trained for multilingual ASR, speech translation, and
language identification. The current `turbo` model is an inference-speed
optimized large-v3 derivative. The OpenAI README lists roughly 809M parameters,
about 6 GB VRAM in the original PyTorch context, and around 8x relative speed
versus the large model on A100; actual Apple performance depends on WhisperKit's
Core ML conversion. WhisperKit supports on-device Swift usage and recommends
large-v3 Turbo variants for macOS/iOS accuracy/speed. MacParakeet specifically
pins WhisperKit through `argmax-oss-swift` exact 0.18.0 when
`MACPARAKEET_SKIP_WHISPERKIT` is not set, and defaults to
`large-v3-v20240930_turbo_632MB`; describe the shipped artifact as roughly
632-646 MB rather than using upstream PyTorch memory as a download-size proxy.

Whisper's strengths are breadth and maturity. Its risks are also well
documented: hallucinated text, repetition, uneven low-resource language
performance, and poor behavior on silence or clipped short segments. In
MacParakeet, Whisper has word timings through WhisperKit and can power the
tail-window display-preview path, but it is not a native streaming dictation
engine.

MacParakeet implication: keep Whisper as the broad-language fallback and a
retranscription tool, not the default dictation experience. Avoid adding
trailing silence padding to Whisper final dictation paths because silence can
increase hallucination risk.

### Cohere Transcribe through FluidAudio

Best current use: opt-in local batch accuracy engine for files, media, and
post-stop final transcripts where plain text is acceptable.

Cohere documents Transcribe as an Apache-2.0, 2B-parameter audio-to-text ASR
model for 14 languages: English, German, French, Italian, Spanish, Portuguese,
Greek, Dutch, Polish, Vietnamese, Chinese, Arabic, Japanese, and Korean. The API
requires a language and returns only `text`. Cohere explicitly says it has no
automatic language detection, no timestamps, and no speaker diarization.

FluidAudio's local integration is more specific for MacParakeet: a
48-layer Conformer encoder, 8-layer Transformer decoder, 35-second baked encoder
window, 108-token decoder cache, 16,384-token SentencePiece vocabulary, and
long-audio chunking with 35-second windows and 5-second overlap. Its Core ML
docs report strong LibriSpeech/FLEURS numbers, but also an important Apple
runtime shape: multi-GB assets and a large one-time ANE compile cost in fresh
processes.

MacParakeet implication: Cohere is correctly implemented as batch-only. It
should not enter live dictation preview or meeting live preview without a
different model/runtime. It also cannot support SRT/VTT-quality exports or
speaker/timing-rich meeting UX by itself.

## Side-by-Side Capabilities

| Model/build | Architecture | Coverage | Native streaming | Timestamps in current MacParakeet path | Primary risk |
| --- | --- | --- | --- | --- | --- |
| Parakeet TDT v3 | FastConformer-TDT | 25 European languages | No; tail-window batch preview | Word timings | European-only scope and language auto-detect on short speech |
| Parakeet TDT v2 | FastConformer-TDT | English | No; tail-window batch preview | Word timings | English-only and noise sensitivity |
| Parakeet Unified EN | FastConformer-RNNT unified offline/streaming | English | Yes, buffered streaming | No | No word timings; buffered streaming recomputes context |
| Nemotron English | Cache-aware FastConformer-RNNT | English | Yes | Token-derived word timings in app | Beta maturity and chunk-size quality tradeoff |
| Nemotron 3.5 | Cache-aware FastConformer-RNNT with language prompt | 40 locales, uneven tiers | Yes | Token-derived word timings in app | Uneven language tiers; Core ML/local parity needs continuing QA |
| Whisper Large v3 Turbo | Seq2seq Transformer | Broad multilingual | No native session in app | Word timings | Hallucination/repetition, cold optimize, uneven languages |
| Cohere Transcribe | Conformer encoder + Transformer decoder | 14 languages | No | No | No auto-detect, no timings, heavy batch runtime |

## Candidate Models Not Yet First-Class

| Candidate | Why it matters | Near-term MacParakeet verdict |
| --- | --- | --- |
| Qwen3-ASR 0.6B/1.7B + Qwen3-ForcedAligner | Purpose-built Qwen ASR family with 30 languages, 22 Chinese dialects, offline/streaming unified inference, and a separate forced aligner for word/character timestamps in 11 languages. Apache-2.0. | High research value, but not ready for native MacParakeet until an Apple-local runtime exists. Current docs are CUDA/vLLM/bfloat16/FlashAttention-first; streaming has no timestamps. |
| Qwen2.5-Omni / Qwen2-Audio / Qwen-Audio | Strong audio-language baselines and useful benchmark context. | Do not prioritize as MacParakeet ASR engines. They are general audio/omni LLMs, not tight local STT runtimes with timestamps and scheduler-friendly footprints. |
| NVIDIA Canary 1B Flash/v2 | Strong NVIDIA multilingual batch ASR/ST candidate with word/segment timestamps in some cards and four-language or European-language focus depending variant. | Good batch/file research candidate if a NeMo sidecar is acceptable. Less attractive for native Mac live preview than Nemotron. |
| SenseVoiceSmall / FunASR | Practical edge candidate for Chinese, Cantonese, Japanese, Korean, and multilingual ASR; GGUF/CPU deployment path exists. | Worth a prototype for CJK file/media and maybe meeting final transcripts. Legal/license review and timestamp story are blockers for first-class adoption. |
| Moonshine Streaming | Tiny English ASR family designed for low-latency live transcription and voice commands; MIT license. | Best English live-preview experiment outside NVIDIA. Not a meeting/export engine because timestamp and long-form stories are weak. |
| Vosk/Kaldi | Mature offline streaming API with partials, word timings, compact models, Swift-adjacent bindings. | Useful as a control/reference for streaming UX and word timing, but not a quality upgrade over modern neural engines. |
| wav2vec2/XLSR | Strong self-supervised/fine-tuning substrate. | Research substrate only; too much productization for current MacParakeet needs. |
| SeamlessM4T v2 | Translation-heavy speech model with broad language ambition. | Not viable for bundled commercial MacParakeet because of non-commercial license and translation-first scope. |

## Recommendations

### Defaults and User-Facing Positioning

1. Keep Parakeet v3 as the default because it is local, fast, timestamp-capable,
   and has the best default coverage for MacParakeet's current user base.
2. Keep Parakeet v2 visible as the "English stability / timestamps" option, not
   as a legacy leftover.
3. Position Parakeet Unified as "best English readability/live partials, no word
   timings" rather than a universal Parakeet upgrade.
4. Keep Nemotron behind beta framing until real MacParakeet QA covers the exact
   Apple devices, chunk sizes, languages, and meeting/dictation paths.
5. Keep Whisper as the broad-language fallback and retranscription tool.
6. Keep Cohere as batch-only and accuracy-focused, with explicit language setup
   and plain-text/timing limitations.

### Product-Surface Recommendations

| Surface | Recommended primary | Recommended fallback | Do not use |
| --- | --- | --- | --- |
| Dictation final paste | Parakeet v3; Parakeet v2/Unified for English-specific preference | Whisper for unsupported languages; Cohere for deliberate batch-only accuracy | Cohere for users expecting live preview; unproven Qwen/omni models |
| Dictation live preview | Parakeet Unified or Nemotron for native partials; Parakeet TDT tail-window preview | Whisper tail-window preview when explicitly selected | Cohere |
| Meeting final transcript | Parakeet TDT v3/v2 when word timings matter | Nemotron/Whisper for coverage; Cohere for plain text only | Timestamp-free engines when export/speaker UX depends on words |
| Meeting live preview | Parakeet/Nemotron/Whisper chunk path as currently routed, with preference for native streaming where quality is proven | Fixed chunking when VAD or engine support is weak | Cohere |
| File/media transcription | Whisper for broad language; Parakeet v3 for supported European languages; Cohere when plain text accuracy is the goal | Qwen3/Canary/SenseVoice prototypes in research branches | Live-preview-optimized engines without long-form validation |

### Next Research Spikes

1. Run a MacParakeet-owned benchmark set instead of relying on model-card WER:
   short dictations, noisy laptop mic, 30/60 minute meetings, YouTube/media,
   CJK no-space speech, and silence/clipped-tail adversarial cases.
2. Prototype Qwen3-ASR 0.6B only if the spike explicitly answers Apple-local
   deployment: MLX/Core ML feasibility, memory, cold start, timestamps, and
   streaming without vLLM.
3. Prototype SenseVoiceSmall/GGUF for CJK/edge file transcription if licensing
   is acceptable.
4. Prototype Moonshine for English live preview if MacParakeet wants a tiny
   non-NVIDIA fallback for low-latency partials.
5. Add a user-facing model capability matrix in Settings only after the product
   wording avoids misleading "best model" claims.

## Source Log

### Repository sources

- `Sources/MacParakeetCore/STT/README.md`
- `Sources/MacParakeetCore/SpeechEnginePreference.swift`
- `Sources/MacParakeetCore/STT/STTRuntime.swift`
- `Sources/MacParakeetCore/STT/ParakeetModelVariant+ASR.swift`
- `Sources/MacParakeetCore/STT/ParakeetUnifiedEngine.swift`
- `Sources/MacParakeetCore/STT/NemotronEngine.swift`
- `Sources/MacParakeetCore/STT/NemotronEnglishEngine.swift`
- `Sources/MacParakeetCore/STT/WhisperEngine.swift`
- `Sources/MacParakeetCore/STT/CohereTranscribeEngine.swift`
- `Sources/MacParakeetCore/Services/Capture/LiveChunkTranscriber.swift`
- `Sources/MacParakeetCore/Services/Dictation/DictationService.swift`
- `Package.swift`
- `spec/06-stt-engine.md`
- `docs/cli-testing.md`

### External sources

- NVIDIA Parakeet TDT 0.6B v2 model card:
  <https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2>
- NVIDIA Parakeet TDT 0.6B v3 model card:
  <https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3>
- NVIDIA Parakeet Unified EN 0.6B model card:
  <https://huggingface.co/nvidia/parakeet-unified-en-0.6b>
- NVIDIA Nemotron Speech Streaming EN 0.6B model card:
  <https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b>
- NVIDIA Nemotron 3.5 ASR Streaming 0.6B model card:
  <https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b>
- FluidAudio Parakeet TDT v3 Core ML model card:
  <https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml>
- FluidAudio Nemotron Speech Streaming EN Core ML model card:
  <https://huggingface.co/FluidInference/nemotron-speech-streaming-en-0.6b-coreml>
- OpenAI Whisper model card and README:
  <https://github.com/openai/whisper/blob/main/model-card.md>,
  <https://github.com/openai/whisper/blob/main/README.md>
- OpenAI Whisper Large v3 Turbo model card:
  <https://huggingface.co/openai/whisper-large-v3-turbo>
- WhisperKit / Argmax Open-Source SDK README:
  <https://github.com/argmaxinc/argmax-oss-swift>
- Cohere Transcribe docs and API reference:
  <https://docs.cohere.com/docs/transcribe>,
  <https://docs.cohere.com/docs/audio-transcription-quickstart>,
  <https://docs.cohere.com/reference/create-audio-transcription>
- FluidAudio Cohere documentation and source:
  <https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/Cohere.md>,
  <https://github.com/FluidInference/FluidAudio/tree/main/Sources/FluidAudio/ASR/Cohere>
- Qwen3-ASR repository and model cards:
  <https://github.com/QwenLM/Qwen3-ASR>,
  <https://huggingface.co/Qwen/Qwen3-ASR-0.6B-hf>,
  <https://huggingface.co/Qwen/Qwen3-ASR-1.7B-hf>
- NVIDIA Canary model card:
  <https://huggingface.co/nvidia/canary-1b-flash>
- SenseVoiceSmall model card:
  <https://huggingface.co/FunAudioLLM/SenseVoiceSmall>
- Moonshine Streaming model card:
  <https://huggingface.co/UsefulSensors/moonshine-streaming-medium>
- Vosk documentation:
  <https://alphacephei.com/vosk/>
