# ADR-026: ASR Engine and Runtime Strategy

> Status: ACCEPTED (strategy; capability-registry implementation tracked in
> `plans/active/2026-07-03-stt-capability-registry.md`)
> Date: 2026-07-03
> Related: ADR-001 (Parakeet primary STT + benchmark amendment), ADR-002
> (local-only), ADR-007 (FluidAudio CoreML), ADR-016 (centralized STT
> runtime + scheduler), ADR-021 (WhisperKit multilingual)
> Evidence: [`docs/research/2026-07-03-asr-landscape-verified.md`](../../docs/research/2026-07-03-asr-landscape-verified.md),
> [`docs/research/2026-06-28-architecture-deepening-opportunities.md`](../../docs/research/2026-06-28-architecture-deepening-opportunities.md) (finding 3)

## Context

MacParakeet ships four speech engines — Parakeet (default), Nemotron
streaming (Beta), Whisper, and Cohere Transcribe — across two runtimes:
FluidAudio CoreML/ANE and WhisperKit. The engine roster has grown one
engine at a time (ADR-001 → ADR-021 → Nemotron → Cohere) without a
standing rule for *how* it grows. Each addition has re-answered the same
questions ad hoc: which runtime, which UI surface, which capability gaps
get hand-coded where.

Three facts, verified July 2026 (see the landscape survey), now make a
deliberate strategy cheap to state and expensive to skip:

1. **FluidAudio has become a de-facto standard library of local ASR for
   Apple Silicon.** Beyond what we use, it already ships a Japanese
   Parakeet, custom-vocabulary Parakeet CTC builds, streaming EOU models,
   CJK models (SenseVoiceSmall, Paraformer-zh), Cohere Transcribe, VAD,
   and three diarization families. NVIDIA's open ASR line (Parakeet,
   Nemotron-3.5 streaming, Canary) keeps compounding and lands there.
2. **The open Whisper line is frozen** (no v4; OpenAI moved to API-only
   audio). WhisperKit remains Whisper-only. Whisper's unique value to us —
   broad language coverage, especially CJK — erodes as alternatives land
   in FluidAudio.
3. **Apple's SpeechTranscriber (macOS 26)** offers a zero-download,
   out-of-process engine with contextual-strings support, but has no
   published quality benchmarks and no visible competitor adoption yet.

Meanwhile the July 2026 architecture survey confirmed the June finding:
engine capability knowledge is duplicated across ~13 switch-on-engine
sites (runtime routing/warm-up/readiness/switch/telemetry, scheduler
admission, dictation preview gate, meeting chunk gates, Settings, CLI),
Parakeet TDT is inlined in `STTRuntime` rather than adapted, and Cohere
is visibly bolted on. The current shape absorbs roughly one more
FluidAudio-like engine safely; it does not absorb an engine *strategy*.

Cloud ASR is permanently out of scope (ADR-002). This is distinct from
the LLM surface, where cloud providers are an explicit product choice
(ADR-011).

## Decision

### 1. Local-only ASR, reaffirmed

No cloud ASR engines, ever (no Deepgram/Groq/etc.). Speech audio and
transcripts stay on-device for all three capture modes. This is the
product's identity, not a temporary posture.

### 2. Two runtimes, and only two

FluidAudio is the primary runtime and center of gravity; WhisperKit is a
maintained legacy fallback. **Adding a third runtime requires a new ADR**
with evidence that a needed model cannot reach FluidAudio/WhisperKit.
Cost basis: a new FluidAudio variant is ~200–500 LOC; a new runtime is
1,500–3,000+ LOC across 12–20+ files plus sandbox/notarization review
and a permanent maintenance seat.

The one credible future third runtime is MLX (active `mlx-audio`
ecosystem; Qwen3-ASR, Parakeet, speech-LLMs). Trigger conditions to
revisit: a Swift-usable MLX speech path exists **and** a model we need
(e.g. Voxtral Realtime) is available there but not in FluidAudio. Note
the on-device-LLM plan may bring MLX into the app for *LLM* work; that
does not by itself justify MLX *ASR* — the ASR bar stays "new ADR".

### 3. Engines grow as variants, not new cards

The Settings surface stays at approximately four engine cards; new
models join as variants within an existing family (as Parakeet
v2/v3/Unified already do). Near-term roadmap, all within FluidAudio,
in priority order:

1. **Custom-vocabulary Parakeet CTC** — Phase 1 ships this as a
   recognition-time CTC sidecar for Parakeet TDT v2/v3 enabled anchors.
   Future work is chunked long-audio sidecar rescoring and any support
   FluidAudio exposes for non-TDT engines.
2. **CJK coverage: Parakeet Japanese + SenseVoiceSmall** — closes the
   gap that currently forces Korean/Japanese/Chinese users onto Whisper
   (and that Parakeet v3 fails outright, per the ADR-001 amendment).
3. **Nemotron-3.5 streaming 0.6B** when FluidAudio ships it — upgrades
   the Beta streaming engine and adds multilingual streaming (~32
   languages, 80 ms chunks).
4. **Cohere Transcribe stays opt-in premium** (16 GB+ gate, ~11 GB RSS)
   per the ADR-001 amendment — accuracy leader, wrong default.

Each adoption still gets a run through the `benchmarks/asr` harness
before shipping; the harness, not vendor claims, decides copy like
"highest accuracy".

### 4. Foundation before the next engine family

Before any new engine *family* is added, the `(engine, variant)`
capability registry described in research finding 3 must land: a single
exhaustively-keyed declaration of what each engine supports (native
live, preview, word timestamps, languages, scheduling class, memory
gate, model lifecycle) that drives runtime routing, scheduler admission,
Settings availability/copy, CLI listings, and capability tests.
Implementation plan: `plans/active/2026-07-03-stt-capability-registry.md`.
New *variants* of existing families may ship before the registry, but
each one raises its cost and is another migration to do later — prefer
registry-first when sequencing allows.

### 5. Whisper's trajectory: maintained fallback, shrinking role

Whisper remains the broad-language fallback and is fully supported, but
receives no deepening investment (no new Whisper-specific features).
Once CJK-capable FluidAudio models plus multilingual Nemotron streaming
cover its practical language surface — and telemetry shows Whisper
selection collapsing — retiring WhisperKit becomes a real option worth
its own ADR (it is a heavy dependency and our second runtime seat).

### 6. Apple SpeechTranscriber: spike, do not ship yet

Run a small spike behind a flag when convenient. Its strategic slot is
**not** a fifth engine card; it is (a) an onboarding bridge — instant
dictation on macOS 26 while the ~465 MB Parakeet download completes —
and (b) a possible long-tail language fallback. Adoption is gated on:
locales actually enumerating on a clean machine, a `benchmarks/asr` run
showing acceptable quality, and it being macOS 26+ only (so it can never
be the default engine while we support earlier macOS).

### 7. Explicit non-goals

Not pursuing: on-device speech-LLMs for dictation (10–20× the
compute/battery for no dictation win; no Swift runtime), Meta
Omnilingual ASR (no Swift runtime), Moonshine (English slot already
covered), sherpa-onnx / whisper.cpp (no unique value over the two
runtimes we hold). Diarization needs stay on FluidAudio's diarization
families rather than a new runtime.

## Consequences

- Engine proposals get a fast, cheap test: *is it in FluidAudio (or
  WhisperKit)? Is it a variant or a family? Did it pass the benchmark
  harness?* Most proposals resolve without design meetings.
- The capability registry becomes the standing prerequisite for engine-
  family growth; its plan is the next STT foundation work item.
- The Settings UI stays comprehensible (four-ish cards) even as the
  model count grows underneath.
- We accept a real dependency concentration risk on FluidAudio. Partial
  mitigations: models are open weights (CoreML conversion is repeatable),
  WhisperKit remains a second seat, and the MLX ecosystem is a monitored
  exit path. If FluidAudio stalls, that triggers the "third runtime" ADR.
- Whisper users see no regression; the engine simply stops accreting
  features until a retirement ADR is justified by data.
