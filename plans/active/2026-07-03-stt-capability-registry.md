# STT capability registry + optional-engine adapters

> Status: **TODO** (Phase A executor-ready after a short design grilling;
> Phases B/C gated as described)
> Date: 2026-07-03
> Governing decision: [ADR-026 §4](../../spec/adr/026-asr-engine-strategy.md)
> Design source: [`docs/research/2026-06-28-architecture-deepening-opportunities.md`](../../docs/research/2026-06-28-architecture-deepening-opportunities.md)
> finding 3 — read it in full before executing; its constraints section is
> normative for this plan.

## Goal

One declared answer to "what can this engine/variant do?" — replacing the
~13 hand-maintained switch-on-engine sites that each re-answer it — so that
adding an engine variant is a registry row + adapter, and UI/CLI/scheduler
capability claims are generated, tested facts rather than copy.

## Why now

ADR-026 commits to growing models as variants (custom-vocab Parakeet, CJK
models, Nemotron-3.5) on the existing four families. Every one of those
additions today means lockstep edits across `STTRuntime` (routing, preview,
live selection, warm-up, readiness, switch, telemetry, default language),
`STTScheduler` (single-flight, live filtering), `DictationService`,
`MeetingRecordingService`, Settings VM/View, and CLI. The matrix is not
unit-testable without loading real models. Doing the seam before the next
wave is the cheap ordering.

## Non-negotiable constraints (from finding 3 — do not relearn these)

- **Preserve loud failure.** The status-quo `switch` blocks are
  compiler-enforced exhaustive. The registry must be exhaustively keyed by
  `(engine, variant)` (e.g. built from `CaseIterable` with a totality test)
  so a missing row is a test failure, not a silent mis-route. Whisper is
  the current exception: its variant is stored as a normalized `String`, so
  Phase A must either introduce a strongly-typed `WhisperModelVariant` or
  define an equivalent closed validation source before totality can be
  claimed for Whisper rows.
- **Scheduler concerns stay in `STTScheduler`.** Leases, slots, and Cohere
  single-flight admission do not move. The registry may *inform* admission
  (e.g. `schedulingClass`), but the mechanism stays put.
- **The shared ANE inference gate stays correct.** Any adapter that wraps
  `AsrManager` work must receive the one process-wide `ANEInferenceGate`
  by injection and call it inline within its own isolation (the
  `NativeLiveDictating` implementations prove the pattern).
- **Job/lane routing is not engine dispatch.** `route(for:)` /
  `manager(for:)` stay in the runtime.
- **ADR-016 prose touch.** Relocating engine dispatch into adapters
  requires updating ADR-016's implementation-direction prose in the same
  PR that does the relocation (repo rule for contracts/ADR drift).

## Phases

### Phase A — capability registry, read-only adoption (the bulk of the win)

1. Define `EngineCapabilities` (small, deliberate field set — start from:
   `supportsNativeLiveDictation`, `supportsTailPreview`,
   `providesWordTimestamps`, `supportedLanguages`/language policy,
   `schedulingClass` (concurrent / cohereSingleFlight),
   `minimumMemoryBytes: UInt64?`,
   `modelLifecycle` (download size, deletable, variants), telemetry
   identity (`telemetryModelKind`, `telemetryEngineVariant`)).
2. Build the exhaustively-keyed registry over `(SpeechEnginePreference,
   variant)`; totality + invariant tests (e.g. "an engine claiming native
   live must conform to `NativeLiveDictating`" — compile-time where
   possible, test elsewhere). For Whisper, first close the variant set with
   a `CaseIterable` enum or a single canonical list used by
   `WhisperEngine.normalizeModelVariant`, Settings, CLI, and these tests.
3. Migrate the *read* sites to consult the registry, mechanically and in
   small PRs: runtime preview/live-selection/readiness/telemetry/default-
   language switches; `DictationService` preview gate;
   `MeetingRecordingService` live-chunk gates; Settings availability/copy
   (`SettingsStatusRules`, engine cards); CLI `models`/`transcribe`
   capability checks. Batch-`transcribe` routing may stay a plain switch —
   it is dispatch, not capability.
4. Characterization tests first where Settings behavior is load-bearing
   (`EngineSettingsViewModel` already has a test seam).

Exit criteria: capability questions answered from one file; a new-variant
dry run (add a fake variant in a test) touches registry + adapter only;
no behavior change (characterization suites green).

### Phase B — wrap the optional engines as full adapters

Nemotron ml/en, Whisper, Cohere become adapters owning their warm-up /
readiness / model-lifecycle behind one protocol surface; `STTRuntime`
shrinks toward registry + dispatcher for them. These engines already have
their own actors and `ensure*` helpers and carry no inline ANE-gate
capture complication. Cohere's bolt-ons (16 GB gate, compute policy,
explicit download) become adapter- and registry-declared facts.

### Phase C — Parakeet TDT extraction (gated, may be declined)

TDT stays a named special case inlined in `STTRuntime` until:

- a microbenchmark shows the added cross-actor hop on the hot dictation
  path is acceptable (measure, don't assert), and
- the init-serialization guard (`ensureInitialized` generation logic) has
  a designed home in the adapter that warm-up orchestration can still see
  (two adapters must never load large models concurrently — 16 GB machines
  + Cohere's ~11 GB are the constraint).

Declining Phase C after measurement is a valid outcome; Phases A+B capture
most of the value.

## Verification

Focused suites per phase (`STT*`, `EngineSettingsViewModel*`, CLI command
tests, meeting/dictation gate tests); full `swift test` once as the final
gate per repo rules. Registry totality tests are the new safety floor.

## Out of scope

New engines/models (ADR-026 roadmap items ship separately, preferably
after Phase A); scheduler redesign; any UI redesign of the engine cards
beyond sourcing their copy/availability from the registry.
