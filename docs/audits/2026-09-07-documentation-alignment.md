# Documentation and architecture alignment audit

> Date: 2026-09-07 (America/Los_Angeles)
> Status: **Documentation corrections verified; runtime qualification excluded.**
> Audited source baseline: `c79d3f52fc07f6b771cf5cc0d6666ba3e2c88159`.

## Outcome

The architecture map, feature/release summaries, affected ADRs, subsystem
READMEs and operational guides now describe the committed implementation more
accurately. The main drift was contradictory copies of implementation details,
stale candidate statuses and guarantees that the code does not provide.
Accepted product decisions and executable behavior are unchanged.

The rebuilt [architecture guide](../../spec/03-architecture.md) replaces long
copied protocol/schema examples with target ownership, capture/speech flows,
persistence boundaries and source links. It covers the new speaker-correction,
retrieval, saved-note and AI-request paths. [The documentation map](../README.md)
separates current contracts from plans, historical context and dated evidence.
[Follow-up recommendations](../research/2026-09-07-documentation-audit-followups.md)
remain proposals, including a CLI compatibility decision and release hash checks.

## Scope and provenance

Work used an isolated branch/worktree based on freshly fetched `origin/main`.
The original checkout contained unrelated source, recovery, workflow and release
documentation edits; those were not copied, committed or overwritten.
`docs/distribution.md`, `docs/pr-review-workflow.md`, `spec/09-testing.md`,
`spec/10-ai-coding-method.md`, ADR-025 and meeting recovery/artifact contracts
were read for context but left to their concurrent owners.

At audit time GitHub showed these integrations:

| Change | Observed state | Merge |
|---|---|---|
| [Saved notes #959](https://github.com/moona3k/macparakeet/pull/959) | Merged | `c14b1ed43543dde1e73805f48bbabfcb4e03909d` |
| [Speaker corrections #960](https://github.com/moona3k/macparakeet/pull/960) | Merged | `c79d3f52fc07f6b771cf5cc0d6666ba3e2c88159` |
| [Inference settings #968](https://github.com/moona3k/macparakeet/pull/968) | Merged | `57e3391a4e25a0ea87fd9519d2a01dfdcf78e6cf` |

GitHub release metadata still showed app `v0.7.3` and standalone CLI
`cli-v3.1.0`; source CLI reports `3.3.0`. No 0.8.0 publication was inferred from
the [existing QA package](../qa/2026-09-07-0.8.0/README.md). Its recorded
candidates and acceptance results remain separate from this documentation head.
The live DMG, Sparkle feed and Homebrew package were not independently inspected.

## Coverage

The initial mechanical scope comprised 82 active Markdown entrypoints: root
README, all numbered specs/ADR/contract documents, top-level docs, integration
Markdown and source READMEs. Historical research, old plans and QA evidence were
not rewritten as current guidance. Three recently merged feature plans and the
plan status board received targeted status reconciliation.

All 28 ADR headers/key decisions were reviewed. Detailed source tracing focused
on current cross-cutting boundaries and suspected drift; this was not exhaustive
re-execution of every acceptance criterion or a line-by-line audit of all code.

| Area | Documentation checked | Implementation evidence and disposition |
|---|---|---|
| Product, architecture, release framing | Specs 00/02/03, spec index, root README, ADR-027 | `Package.swift`, `AppFeatures`, `AppEnvironment`, current Git/GitHub metadata. Rebuilt architecture map; added development features without claiming stable availability. |
| Storage and derived state | Spec 01, Database README, contracts | `DatabaseManager`, repositories, `KnowledgeSegmenter`, correction and card services. Corrected storage boundaries, migration guidance, omitted Transform history table and segmenter v4. |
| Microphone, meeting and recovery | Spec 05/08, Audio README, ADR-014/015/019/025/028, recovery/artifact contracts | Capture/converter, finalizer, source reconciler, settlement and recovery owners. Corrected duration/downmix/error guarantees and AEC ownership; concurrent recovery contract edits excluded. |
| Speech routing and diarization | Spec 06, STT README, ADR-001/007/010/016/021/026 | Scheduler/runtime, `DiarizationService`, capabilities and pinned package. Corrected backlog policy, captured routes, historical benchmark qualification and current engine availability. |
| Deterministic processing | Spec 07, TextProcessing README, ADR-004 | `CustomWordReplacer`, pipeline and refinement owners. Blank replacement anchors also restore stored casing; trailing-action step is already in the ADR. |
| Onboarding, hotkeys, calendar and gated detection | ADR-005/009/017/023/024, feature/UI specs | Current flags and source owners. Existing staged/gated labels retained; no claim of hardware or full detection-matrix verification. |
| Notes, prompts, AI and UI | Specs 04/11–14, ADR-011/013/018/020/022 | Saved-note coordinators, prompt/result models/repositories, generation/context flows, Markdown views. Corrected modal-vs-autosave interaction, category names, snapshots and implementation tense. |
| Local AI history | ADR-008 and references in ADR-001/007/011, runtime checklist | Build gate, `AppFeatures`, routing/configuration. Historical runtime removal does not imply absence of the current developer-gated MLX target. |
| Privacy, licensing and telemetry | ADR-002/003/006/012, telemetry docs/contract, Licensing README | Actual entitlement app/CLI callers, queue/serialization code and test sources. Corrected conditional legacy validation, Discover gating, event envelope and launch-session denominator. |
| CLI and agent integration | Integration guides/skill, CLI README and changelog, public contracts | ArgumentParser command definitions, catalog tests, export implementation. Recipes source-checked; TXT stdout compatibility recorded separately. |
| Development and QA | Top-level operational guides, System README, review/distribution docs | Dev/smoke scripts and platform service APIs. Corrected quit scope, isolation/readiness and source-vs-runtime evidence claims. |
| Design and historical material | Brand/UI references, UI inspiration, historical/planning entrypoints | Preserved historical context and clarified precedence. No current competitor, external model or market survey was performed. |

## Material corrections

- The package has separate app, Core, ViewModels, CLI, Objective-C shim and gated
  MLX targets. App coordinators perform orchestration; “no business logic” and
  “every service has a protocol, no singletons” were inaccurate absolute claims.
- SQLite holds structured records; UserDefaults, Keychain, retained audio,
  models, locks and artifacts are separate storage. Migration labels are not
  release versions, and cross-table domain migrations/transactions already exist.
- Saved-note editing is an autosaving Notes tab with flush gates, not a modal
  Save/Cancel workflow. Speaker corrections project over automatic evidence and
  participate in derived-state invalidation and stale-context checks.
- Current source pins GRDB from 7.0.0 and FluidAudio 0.15.6, includes Sparkle,
  yyjson and rich Markdown, and keeps MLX opt-in at both build and product levels.
- Older diarization DER/throughput and ASR-plus-diarization totals do not qualify
  the current corrected clustering/high-accuracy preset. Single-speaker
  processing is not free, and transcript-local IDs are not cross-run identity.
- Pending meeting-finalize priority does not preempt a running file job.
  Backpressure discards old queued live chunks, not arbitrary lower-priority
  durable work. The lifecycle watchdog observes stalls; it is not a global STT
  deadline or proof of cancellation.
- No configurable four-hour import limit or app-managed database corruption/WAL
  repair was found. Those claims were removed.
- Offline cleaned-mic AEC is the current primary echo path; the supporting
  transcript duplicate-speech heuristic still exists and is now acknowledged.
- Free builds remain unlocked but can validate an existing legacy activation
  during app setup. Privacy docs now describe that conditional network path.
- Telemetry POSTs an object containing an `events` array, not a bare array;
  `app_launched` counts launch sessions rather than unique people/DAU.
- Plan statuses for #959/#968 and the merged portion of #960 no longer ask a
  future agent to repeat implemented work. Remaining speaker UI/replay work is
  explicitly retained; proposals were not silently declared complete.

## Verification and limits

- Reviewed the combined Markdown diff against source owners and governing docs.
  Independent speech and data/AI reviewers checked the rewritten architecture
  sections; their buffer-copy ownership and content-derived fingerprint wording
  findings were corrected.
- Checked local Markdown link destinations and heading anchors across the active
  scope plus changed/new documents. No missing local paths or unresolved anchors
  remained after the audit artifacts were added.
- Compared all 102 `TelemetryEventName` raw values with `docs/telemetry.md`;
  every value occurs in the catalog. This does not prove the separate website
  allowlist or deployed ingestion behavior.
- Checked the feature-gate table against `AppFeatures.swift`, source CLI version
  against its entrypoint, and package claims against `Package.swift`. Reviewed
  relevant enforcing test sources without executing their runtime paths.
- `scripts/check-readme-references.sh` passed for all subsystem source links.
- `git diff --check` passed. All task changes are Markdown; no code, migrations,
  package locks, assets, user preferences or retained artifacts were changed.
- No app build, full test suite, UI/hardware run, model download, benchmark,
  provider request, notarization or deployment was performed. The parallel
  release owns those gates. A source/doc audit is not a release approval.
