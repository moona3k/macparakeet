# Nemotron Beta Engine Plan

> Status: **ACTIVE PLAN**
> Drafted: 2026-06-08
> Branch: `plan/nemotron-benchmark`
> Worktree: `/Users/dmoon/code/macparakeet-worktrees/nemotron-benchmark`
> ADRs: `spec/adr/001-parakeet-stt.md`, `spec/adr/016-centralized-stt-runtime-scheduler.md`, `spec/adr/021-whisperkit-multilingual-stt.md`
> Scope: add Nemotron 3.5 as a clean opt-in Beta speech engine, backed by side-by-side benchmarks against MacParakeet's current Parakeet v3/v2 and Whisper paths.

## Current Branch Status

As of 2026-06-08 on `plan/nemotron-benchmark`:

- FluidAudio is bumped to `0.15.2`; the existing Parakeet v3/v2 code path
  builds against it.
- `NemotronEngine` is wired through `STTRuntime` and therefore through the
  existing `STTScheduler` lanes for dictation, file transcription, meeting live
  chunks, and meeting finalization.
- Settings exposes Nemotron as a separate Beta speech engine card and includes
  model download/delete/status controls.
- CLI support covers `transcribe --engine nemotron`, `config set
  speech-engine nemotron`, `config set nemotron-language`, `models list`,
  `models select`, `models download`, `models delete`, `models status`,
  `models warm-up`, and `health --repair-models`. `models select` validates
  that local Nemotron/Whisper artifacts are downloaded before persisting either
  engine as the shared default.
- Telemetry attribution uses the existing safe dimensions:
  `speech_engine=nemotron`, `engine_variant=multilingual-1120ms`, and
  `model_kind=nemotron_stt`. Audio, transcript text, file paths, URLs, and
  language text remain excluded from telemetry payloads.
- The first reproducible side-by-side harness is
  `scripts/dev/benchmark_stt_engines.sh`. It exercises the production CLI path
  and writes TSV, JSON, stderr timing logs, and transcripts under
  `output/benchmarks/stt/`.
- The first smoke benchmark report is
  `docs/planning/2026-06-nemotron-stt-benchmark-report.md`. It compares
  Parakeet v3, Nemotron, and Whisper on five synthetic samples and records why
  Nemotron should remain opt-in Beta rather than replacing Parakeet.

Validated so far:

```bash
swift build
swift test --filter 'SpeechEnginePreferenceTests|TranscribeCommandTests|ConfigCommandTests|ModelLifecycleCommandTests|SettingsViewModelTests|STTSchedulerTests|SettingsStatusRulesTests'
swift test
bash -n scripts/dev/benchmark_stt_engines.sh
git diff --check
```

The focused test slice passed 393 tests with 0 failures after the core,
Settings, and CLI wiring. The full suite passed 3362 tests with 10 expected
skips and 0 failures after the retranscription and Settings model-status
coverage landed; the final full-suite rerun after CLI spec/docs polish and the
missing-Nemotron Settings guard passed 3365 tests with 10 expected skips and 0
failures.

## 1. Intent

MacParakeet's default STT path is already strong: Parakeet TDT v3/v2 through
FluidAudio CoreML on Apple Silicon, owned by one process-wide `STTRuntime` and
scheduled through the two-slot `STTScheduler`. Newer FluidAudio releases add
Nemotron ASR support with broader multilingual coverage and streaming-oriented
APIs.

The product goal is to let MacParakeet users try the new local frontier ASR
engine without destabilizing the proven default path:

**Ship Nemotron 3.5 as an explicit Beta engine for dictation, file
transcription, and meetings, while Parakeet remains the default stable engine.**

Benchmarks are still required, but they should shape the implementation, UX copy,
and known tradeoffs rather than block any user-facing exposure until perfect
proof exists. The answer must come from MacParakeet workloads, not upstream
claims alone. Dictation, meeting live preview, meeting finalization, and file
transcription have different latency and output-quality requirements.

## 2. Product Shape

Add Nemotron as a third first-class speech engine in Settings and CLI:

```text
Speech Recognition
  Parakeet    Stable default, fastest proven local path
  Nemotron    Beta, new local multilingual streaming ASR
  Whisper     Broad compatibility fallback
```

Suggested user-facing card:

```text
Nemotron 3.5    Beta
New local multilingual ASR with streaming support for around 40 languages.

- Around 40 languages
- Low-latency streaming
- Runs locally on Apple Silicon
- Larger download than Parakeet
```

Keep the fine print light. The Beta tag plus the single decision-help line is
enough for the Settings card. Deeper details belong in model status, tooltips,
or docs only when they help a user choose.

Do not put Nemotron inside the existing **Parakeet Model** card. It should be a
separate speech engine because it has different model artifacts, language-hint
behavior, streaming/finalization tradeoffs, and maturity.

## 3. Engineering Idea

Integrate Nemotron as a first-class local engine, not as a parallel app-level
speech stack.

The production implementation should:

- enter through `STTRuntime` and `STTScheduler`
- preserve one shared STT control plane
- keep dictation's interactive lane protected
- keep meeting engine leases deterministic
- treat batch/final and streaming/interim behavior separately
- keep Parakeet v3 as the stable default
- expose Nemotron as opt-in Beta in Settings and CLI
- support model download, status, deletion, and attribution like the other local
  engines

Benchmark harness code may start standalone, but production wiring must not copy
a separate ASR service pattern into the app.

## 4. Hypotheses

1. **Coverage:** Nemotron can cover more languages locally than Parakeet v3,
   reducing the number of users who need Whisper as their first-choice engine.
2. **Streaming:** Nemotron streaming may improve live-preview cadence for
   non-English or mixed-language dictation, but chunk size may trade accuracy
   for latency.
3. **Final quality:** Batch/final Nemotron may be competitive for file
   transcription and meeting finalization, even if streaming interim text has
   punctuation or boundary limitations.
4. **Operational fit:** First-load time, model size, memory, CoreML compile
   behavior, and failure modes may be more important than headline WER.

## 5. Non-Goals

- Do not replace Parakeet as the default.
- Do not fork the STT scheduler or create feature-owned STT runtimes.
- Do not claim language or accuracy superiority from synthetic samples alone.
- Do not ship a cloud STT fallback. This remains a local-first evaluation.
- Do not add heavy warning copy. Use a concise Beta tag and practical model
  details.

## 6. Benchmark Dimensions

Measure each engine and job class with the same audio where possible.

| Dimension | Why it matters |
|---|---|
| Wall-clock transcription time | User-visible completion latency |
| Realtime factor | Cross-audio-length speed comparison |
| First partial latency | Dictation and meeting live-preview feel |
| Segment cadence | Whether interim output feels continuous |
| Final text quality | Shipping transcript quality |
| Boundary integrity | Avoid clipped or duplicated words at emission boundaries |
| Punctuation/capitalization | Whether final text can be inserted directly |
| Language handling | Whether detected/manual language behavior is predictable |
| Peak memory | 8 GB Mac viability and dual-engine residency risk |
| First-load and compile time | Onboarding and model-switch experience |
| Model download size | Storage and setup expectations |
| Failure behavior | Whether errors map cleanly to user-facing states |

## 7. Audio Corpus

Use three corpus layers. Keep generated or downloaded benchmark assets out of
the repo unless they are tiny and license-clean.

### Layer A: Fast Smoke Corpus

Purpose: quickly catch integration failures and estimate latency.

- short English dictation, 5-10 seconds
- longer English monologue, 45-90 seconds
- quiet-input variant of the same English clip
- at least one non-English clip from a Nemotron-covered language outside
  Parakeet's best-known European lane

Synthetic TTS is acceptable here because this layer checks integration and
performance, not final product quality.

### Layer B: Product Corpus

Purpose: approximate real MacParakeet behavior.

- natural spoken dictation with filler words and corrections
- meeting-style two-speaker audio
- long-form file transcription input, 10-30 minutes if practical
- mixed-language or code-switching clip
- quiet microphone clip representative of laptop or headset capture

This layer should use real speech. Preserve transcripts as reference text when
licenses allow.

### Layer C: Regression Corpus

Purpose: protect future changes once a direction is chosen.

- tiny checked-in fixtures only if license-clean
- otherwise scripts that fetch or generate deterministic samples into
  `output/benchmarks/`
- expected metrics stored as thresholds, not brittle exact transcripts

## 8. Delivery Plan

### Phase 1: Baseline Current Main

Run the current `origin/main` CLI on the corpus:

```bash
MACPARAKEET_TELEMETRY=0 swift run macparakeet-cli transcribe sample.wav \
  --engine parakeet --parakeet-model v3 --format json --no-history

MACPARAKEET_TELEMETRY=0 swift run macparakeet-cli transcribe sample.wav \
  --engine parakeet --parakeet-model v2 --format json --no-history
```

Capture:

- wall time with `/usr/bin/time -lp`
- output transcript
- JSON engine attribution
- peak memory
- model warm/cold state

### Phase 2: FluidAudio 0.15.x Build Check and API Inventory

Create a spike branch change that bumps FluidAudio to a concrete 0.15.x release
and verifies compilation:

```bash
swift package update FluidAudio
swift build --target MacParakeetCore
swift test --filter STT
```

Expected decision point:

- if the existing Parakeet API remains source-compatible, continue
- if the API breaks, document the compatibility delta before writing benchmark
  code
- inventory Nemotron APIs and decide which model path maps to dictation,
  meeting live preview, meeting finalization, and file transcription

### Phase 3: Production-Path Benchmark Harness

The first harness should exercise the same path users exercise: the
`macparakeet-cli transcribe` command backed by the production STT wrappers.
This keeps the benchmark honest about model routing, audio conversion,
progress, engine attribution, cancellation/error mapping, and CLI privacy
defaults.

Run shape:

```bash
swift build -c release --product macparakeet-cli
MACPARAKEET_TELEMETRY=0 DO_NOT_TRACK=1 \
  scripts/dev/benchmark_stt_engines.sh output/benchmarks/stt/corpus.tsv
```

Corpus TSV columns:

```text
sample_id<TAB>path<TAB>language<TAB>sample_type<TAB>reference_path<TAB>notes
```

Output includes:

```text
engine
variant
language_hint
sample_id
audio_duration_s
first_progress_s
first_partial_s
final_wall_s
realtime_factor
peak_memory_bytes
wer
punctuation_per_100_words
prefix_ref_words_matched
suffix_ref_words_matched
final_text_path
error
```

The production CLI path currently emits final transcripts plus coarse progress,
not streaming partial transcript text. Therefore this harness records
`first_progress_s` automatically and reserves `first_partial_s` for a direct
FluidAudio streaming probe or app live-preview instrumentation pass. Do not
overstate `first_progress_s` as true first partial latency in the report.

### Phase 4: Production Integration

Implement the Beta engine in the real app:

- add Nemotron to `SpeechEnginePreference` or the equivalent routing model
- add any required model variant/language-hint types
- load/download/delete Nemotron model artifacts through `STTRuntime`
- preserve scheduler job classes and meeting leases
- expose CLI selection for `transcribe`, `config`, and `models`
- add Settings card with the single Beta tag and concise model details
- update model status, download progress, and storage-management surfaces
- add privacy-safe telemetry attribution for engine, variant, duration, and
  coarse failure type only

Current branch state: complete enough for build/test validation and PR review;
remaining work is benchmark evidence beyond the synthetic smoke corpus, final
polish, PR review, and merge-readiness cleanup.

### Phase 5: Side-by-Side Benchmark Report

Produce a report after the implementation path is working:

- Parakeet v3/v2 vs Nemotron vs Whisper where relevant
- dictation, meeting live preview, meeting finalization, and file transcription
- latency, realtime factor, first partial, memory, model setup, and qualitative
  transcript notes
- recommendation for default status, Beta copy, and follow-up fixes

### Phase 6: Product Decision

After real-user and benchmark feedback, choose one:

1. keep Nemotron as Beta
2. promote it for specific languages or workflows
3. make it the default only if evidence clearly beats Parakeet for the default
   user path
4. remove or hide it if the model artifacts or runtime behavior are not good
   enough

## 9. Implementation Shape

Production implementation should be a small extension of existing engine
routing:

- add a local enum case or variant for Nemotron based on the chosen model path
- keep `SpeechEngineSelection` explicit and serializable
- add language hint storage only if manual language meaningfully improves
  output
- load/download models inside `STTRuntime`
- preserve `STTScheduler` admission, priority, backpressure, and meeting leases
- attribute telemetry with engine and variant only, never transcript or audio
  content
- update `spec/06-stt-engine.md` and any ADR only after implementation is real

## 10. Job-Class Mapping

| Job kind | Implementation expectation |
|---|---|
| `dictation` | Needs low first-partial latency, no word clipping, predictable final insert text |
| `meetingLiveChunk` | Can tolerate rough interim text, but must not block finalization or dictation |
| `meetingFinalize` | Prioritizes complete punctuated transcript and stable per-source merge |
| `fileTranscription` | Prioritizes final quality, progress, cancellation, and long-file behavior |

The same selected engine should apply across dictation, file transcription, and
meetings unless a specific model limitation forces a narrower first release.
If streaming and final Nemotron paths differ, keep that distinction internal to
the engine implementation rather than asking users to choose between technical
subtypes prematurely.

## 11. Quality Gates

Nemotron should not ship as Beta unless it passes these gates:

- current Parakeet v3/v2 behavior still passes `swift test --filter STT`
- no regression to current CLI `transcribe --engine parakeet`
- first partial latency is acceptable for dictation if used for dictation
- final output does not systematically lose trailing words at segment or session
  boundaries
- cold setup and warm setup durations are documented
- peak memory is measured on the same machine as the Parakeet baseline
- unsupported-language behavior is explicit, not implicit fallback
- model download/cache paths can be deleted from Settings/CLI model management
- license and model notices are accounted for before distribution

## 12. User-Facing Copy

Keep Settings copy direct:

```text
Nemotron 3.5
Beta
New local multilingual ASR with streaming support for around 40 languages.

Around 40 languages
Low-latency streaming
Runs locally on Apple Silicon
Larger download than Parakeet
```

Avoid copy like "reversible", "try at your own risk", or long caveat blocks in
the card. Save nuanced benchmark conclusions for release notes, docs, or a
model-details tooltip.

## 13. Open Questions

- Which Nemotron path is the best MacParakeet candidate: streaming, offline, or
  both with different job-class routing?
- Does manual language selection materially improve quality over auto mode?
- Does streaming output need a second finalization pass for punctuation and
  capitalization?
- Can one loaded Nemotron manager support the two-slot scheduler cleanly, or do
  we need slot-scoped manager instances like current Parakeet?
- Does FluidAudio 0.15.x preserve the current Parakeet v3/v2 API surface and
  download behavior?
- Are the CoreML model artifacts stable enough for public release, including
  model cache invalidation and notices?

## 14. Immediate Next Steps

1. Add a direct streaming/meeting-live probe if we need true first-partial and
   segment-cadence numbers before PR merge.
2. Run the product-corpus benchmark with real speech before making any
   post-Beta quality claims.
3. Tune the Beta copy if the product-corpus measurements expose a user-facing
   caveat beyond "Beta".
4. Open the PR with implementation/data-flow details and an ASCII diagram, then
   drive review/CI to merge readiness.
