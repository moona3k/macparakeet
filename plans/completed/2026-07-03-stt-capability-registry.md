# STT capability registry + optional-engine adapters

> Status: **DONE / ARCHIVED 2026-07-16** (Phase A shipped as #720; Phases B/C
> remain separately gated and are not implied active by this record)
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

1. Define `SpeechEngineCapabilities` — field set DECIDED 2026-07-04
   (design grilling; renamed from the original `EngineCapabilities` draft
   to align with the `SpeechEnginePreference` naming family). Admission
   test: a field earns a row only if it is a stable fact about the
   engine/variant consulted by existing call sites — not a policy, not a
   mechanism, not speculation. Two-part structure:
   - **Behavioral capabilities** (each kills existing switch sites):
     `supportsNativeLiveDictation` (backed by the NativeLiveDictating
     conformance invariant), `supportsTailPreview`,
     `providesWordTimestamps`, `supportedLanguages`/language policy,
     `supportsCustomVocabulary` (consumed by the custom-vocabulary plan
     for honest UI gating).
   - **Declarative metadata**: `modelLifecycle` (download size, deletable,
     variants, `minimumMemoryBytes: UInt64?` — the Cohere 16 GB gate reads
     this; it is asset metadata, not a behavioral capability) and telemetry
     identity (`telemetryModelKind`, `telemetryEngineVariant` — makes
     wrong-label emission for a new variant structurally impossible).
   - **Cut: `schedulingClass`.** Exactly one engine is exclusive-admission
     (Cohere) and a "generic" class named after it is a costume, not an
     abstraction. `STTScheduler` keeps its explicit Cohere single-flight
     special case. Reintroduce only when a second exclusive-admission
     engine actually lands — registry rows are cheap to add later;
     speculative fields widen what every variant must declare, forever.
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
dry run (add a fake variant in a test) touches registry + adapter only
**at capability read sites** — persisted variant IDs, defaults bridging
(`SpeechEnginePreference` enums, `ParakeetModelVariant+ASR`), and model
lifecycle helpers stay enum-backed for now and still enumerate cases;
collapsing those is a later variant-model abstraction, not Phase A. No
behavior change (characterization suites green).

Phase A completion evidence (2026-07-04):

- Capability source: `Sources/MacParakeetCore/STT/SpeechEngineCapabilities.swift`
  declares the registry, rows, language policy, model lifecycle, and telemetry
  identity; `Tests/MacParakeetTests/STT/SpeechEngineCapabilitiesTests.swift`
  covers totality and core invariants.
- Read-only adoption: runtime live/preview/readiness/telemetry/default-language
  gates, scheduler live admission and leases, DictationService preview gating,
  MeetingRecordingService live-chunk gating, Settings model/copy surfaces, and
  CLI model/transcribe checks now read `SpeechEngineCapabilityRegistry`.
- New-variant dry run: `MeetingRecordingServiceTests.testMeetingLivePreviewDryRunUsesInjectedCapabilitiesForNextVariant`
  injects a synthetic `dry-run-next-variant` capability payload into the
  meeting live-chunk read site and routes that chunk through the lease
  selection. This intentionally leaves persisted variant enums, defaults
  bridging, and model-lifecycle enumeration unchanged; a real persisted
  variant still updates those enum-backed surfaces outside this read-site dry
  run.
- Characterization coverage: `SpeechEngineCapabilitiesTests`,
  `SpeechEnginePreferenceTests`, `STTSchedulerTests`, `DictationServiceTests`,
  `MeetingRecordingServiceTests`, `AppEnvironmentTests`,
  `EngineSettingsViewModelTests`, `SettingsStatusRulesTests`,
  `ModelLifecycleCommandTests`, `TranscribeCommandTests`, and
  `RetranscribeCommandTests`.

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
