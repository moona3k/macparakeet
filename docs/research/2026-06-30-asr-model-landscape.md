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

## Open Research Questions

These are the external-source questions this report resolves in the final
sections below.

1. Which published WER/CER claims are comparable, and which are benchmark
   apples-to-oranges?
2. Which models expose real timestamps that can support MacParakeet exports,
   speaker-labeled meetings, and transcript navigation?
3. Which models have true streaming semantics versus chunked batch semantics?
4. Which models are credible local-first additions beyond the current engine
   set, especially Qwen-family audio/ASR models?
5. Which model should MacParakeet recommend per product surface rather than as a
   single global "best ASR" answer?

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
- `docs/cli-testing.md`

### External sources

External model sources are gathered in the next pass. The final version should
prefer official model cards, papers, SDK docs, and vendor release notes over
third-party summaries.
