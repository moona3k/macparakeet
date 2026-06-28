# Implementation Plans — Status Board

> Single source of truth for what's actually in flight. Reconciled
> **2026-06-14** against `main` after the meeting wave (#522 auto-stop, #523
> mic-watchdog, #524/#525 activity detection), the Nemotron English build
> (#503), the live dictation preview pipeline (#517), and onboarding warm-up
> (#519) all landed, by cross-referencing every plan in `active/` with git
> history, merged PRs, and the live codebase.
>
> Layout: `active/` = open or partially-open work · `completed/` = shipped
> (kept as the record, never deleted) · `deferred/` = parked.
> Per-subsystem rules live in `Sources/MacParakeetCore/<subsystem>/README.md`.
> A second plan set with YAML frontmatter lives in `docs/plans/` (the
> `/ce-plan` convention; some entries — e.g. ADR-024 Phase C rich-meeting
> detection — overlap the feature areas tracked here).

## How to read a status

| Status | Meaning |
|--------|---------|
| **TODO** | Not started. Drift-check before executing. |
| **EXECUTOR-READY** | Self-contained, verified, a cheap model can run it now. |
| **PARTIAL** | Some phases shipped; a defined remainder is open. |
| **ON HOLD** | Deliberately parked (usually pending telemetry/decision). |
| **DECISION** | A settled product rule, not buildable work; follow-up hardening only. |
| **PROPOSED** | Exploration/direction; not committed work. |
| **VERIFY-THEN-ARCHIVE** | Appears shipped; confirm acceptance criteria before moving to `completed/`. |

## Active plans

| Plan | Title | Status | Priority | What's left |
|------|-------|--------|----------|-------------|
| [2026-06-27-on-device-local-llm](active/2026-06-27-on-device-local-llm.md) | On-device local LLM (self-optimized MLX model) | **PROPOSED** | P2 | First-principles plan for a first-party on-device LLM powering transcript cleanup + summary + QA + (later) tool-calling, one click (not bundled). Strategy: hyper-focus on **one engine (MLX)** + one self-optimized model (Apache base → convert/quantize/fine-tune, Qwen3-4B start; our own model as endgame). BYO = MLX models; Apple Foundation Models = optional no-download fallback. Addresses #439/#265/#550; relates #460/#563/#408. Needs Daniel decisions (§11) + a Phase 0 spike/eval gate. |
| [2026-06-27-on-device-local-llm-phase0-eval](active/2026-06-27-on-device-local-llm-phase0-eval.md) | On-device local LLM — Phase 0 eval design | **PROPOSED** | P2 | Companion to the plan above: defines **what to measure and how** before any inference code. Reframes cleanup as a near-subtractive edit (dominant risk = over-editing) → asymmetric eval: deterministic fidelity **gates** (entity/number diff, bidirectional NLI) + graded quality (SARI, ERRANT-F0.5) + calibrated cloud LLM-judge. Long transcripts → map-reduce/RAG (architecture > model size). Includes gold-set recipe, MLX perf benchmarks to run, model bake-off, and go/no-go. Research-backed (5-agent synthesis). |
| [2026-05-dictation-first-onboarding](active/2026-05-dictation-first-onboarding.md) | Dictation-first onboarding | **VERIFY-THEN-ARCHIVE** (A+B shipped) | **P1** | **Part A shipped** as #515 (`4e2303d4b`): onboarding is now 6 steps (Meeting Recording + Calendar removed), recovering the **−21pt completion cliff**. **Part B shipped** as #519 (`76073c79a`): the ~465 MB speech-model download now starts at onboarding open and overlaps the permission/hotkey steps (timing only). Guards §5.1–5.4 implemented (engineBusy decoupling, CJK-fork preserved, failure suppressed before the engine step, telemetry shift documented); 4 tests incl. a mutation-verified suppression test. Remaining: verify the funnel lift by app version, then archive. |
| [2026-06-onboarding-stall-watchdog-test](active/2026-06-onboarding-stall-watchdog-test.md) | Make the warm-up stall watchdog testable + test it | **VERIFY-THEN-ARCHIVE** ✅ | **P1** | Shipped as #518 (`89298746d`): timeout made injectable, `MockSTTClient` hang mode, stall→`.failed` test + healthy-path negative test, mutation-verified. No production behavior change at the 180s default. Confirm merge then move to `completed/`. |
| [2026-06-12-telemetry-allowlist-ci-guard](active/2026-06-12-telemetry-allowlist-ci-guard.md) | Cross-repo telemetry allowlist CI guard | **EXECUTOR-READY** ✅ | P2 | Re-verified 2026-06-13: assumptions hold, repos in sync (97 events, 0 missing). Closes a 3×-recurring silent data-loss class. **One follow-up only a maintainer can do:** add the `WEBSITE_REPO_TOKEN` CI secret to flip it from skip→enforce. |
| [2026-06-12-june-churn-regression-tests](active/2026-06-12-june-churn-regression-tests.md) | Regression tests: mic self-heal + Nemotron live dictation | **EXECUTOR-READY** | P2 | Adds the missing assertions on the June audio/STT hardening (#496, #507). Dispatchable now. |
| [2026-06-19-meetings-workspace-productization](active/2026-06-19-meetings-workspace-productization.md) | Meetings workspace productization | **PROPOSED** | P2 | Product research-backed staged plan: make Meetings a compact daily workspace, expose artifact folders/paths, add DB-backed folders/projects, add local indexing before cross-meeting Ask, and create a full-app meeting smoke harness. |
| [2026-06-14-meeting-auto-stop](active/2026-06-14-meeting-auto-stop.md) | Activity-based meeting auto-stop | **PARTIAL** | P2 | Phases A+B shipped as #522 (silence + app-quit signals, veto countdown) behind `AppFeatures.meetingAutoStopEnabled` (flag on `main`; per-user setting default off). Phase C (attribution-aware stop) deferred to ADR-024 — see the orchestration plan. ADR-023, REQ-MEET-015. |
| [2026-06-14-meeting-auto-stop-orchestration](active/2026-06-14-meeting-auto-stop-orchestration.md) | Meeting auto-stop — execution/orchestration guide | **VERIFY-THEN-ARCHIVE** | P3 | Execution aid for the now-shipped #522; remaining value is the Phase C handoff context. Fold into the auto-stop plan or archive once Phase C scope is settled. |
| [2026-06-14-meeting-mic-reliability](active/2026-06-14-meeting-mic-reliability.md) | Meeting capture reliability — mic-health watchdog | **PARTIAL** | P2 | Phase A shipped as #523 (metadata-only mic-health telemetry watchdog) behind default-on `AppFeatures.meetingCaptureReliabilityEnabled`. Phase B (warning UI) + Phase C (post-stop coverage repair) remain. ADR-025, REQ-MEET-017/018. |
| [2026-06-14-meeting-activity-detection](active/2026-06-14-meeting-activity-detection.md) | Activity-based meeting detection foundation | **PARTIAL** | P2 | Phases A+B shipped as #524/#525 (per-process audio attribution + camera activity + pure detector) behind default-off `AppFeatures.meetingActivityDetectionEnabled`; no runtime coordinator/UI yet. Coordinator/prompt phases tracked in `docs/plans/2026-06-14-001-feat-rich-meeting-detection-plan.md`. ADR-024, REQ-MEET-016. |
| [2026-06-27-meeting-aec-measurement-harness](active/2026-06-27-meeting-aec-measurement-harness.md) | Meeting AEC measurement harness | **PARTIAL** | **P1** | Gates the #605 echo/bleed cluster (next meeting P0). Test-only harness shipped: ground-truth fixtures (far-end-only / near-end-only / double-talk) + ERLE/near-end metrics + NLMS & oracle baselines, run through the real `StreamingMeetingEchoSuppressor`. First numbers: aligned oracle 56 dB vs 2.5 ms-misaligned −2.7 dB (alignment is the dominant risk); NLMS 36 dB single-talk but a slight regression under double-talk. Remaining: adaptive delay estimation, LocalVQE + WebRTC AEC3 adapters scored on the same fixtures, nonlinear/real-recording fixtures. |
| [nemotron-english-streaming-variant](active/nemotron-english-streaming-variant.md) | Nemotron Speech Streaming EN 0.6B build | **VERIFY-THEN-ARCHIVE** | P3 | Shipped as #503 (`nemotron-english-1120ms`, English-only, ~600 MB, opt-in Beta). Live dictation partials added on the `nemotron-english-live-transcript-preview` branch. Header still reads "awaiting PR" — update/archive. |
| [2026-04-settings-ia-overhaul](active/2026-04-settings-ia-overhaul.md) | Settings IA Overhaul | **PARTIAL** | P2 | Tabbed `Modes/Engine/AI/System` shell, search index, tab persistence, card moves all shipped. Remaining: follow-up polish + the `SettingsView`/`SettingsViewModel` god-file decomposition (3278 / 2246 LOC). |
| [2026-05-ai-setup-ux](active/2026-05-ai-setup-ux.md) | AI Setup UX | **VERIFY-THEN-ARCHIVE** | P2 | Most shipped (#419/#428/#484: discovery, fallback, save-above-formatter, app-aware profiles). Confirm Phase 5 (LM Studio/Ollama one-click) + Phase 6 test coverage landed, then archive. |
| [2026-05-engine-switch-ux-revamp](active/2026-05-engine-switch-ux-revamp.md) | Engine Switch UX Revamp | **PARTIAL** | P2 | Stage A shipped (PR #335: cold/warm tile copy, optimized-variant persistence). A3 + the full reactive flow are **on hold pending telemetry**. |
| [2026-05-engine-switch-stage-b-background-optimize](active/2026-05-engine-switch-stage-b-background-optimize.md) | Engine Switch Stage B (background optimize + real cancel) | **ON HOLD** | P3 | A3 (`was_cold`/`mode` telemetry) ready to build; full reactive Stage B **not greenlit** — cold-compile contention was unmeasurable on-device (§0). Instrument first, then decide. |
| [2026-05-dictation-stall-integration-tests](active/2026-05-dictation-stall-integration-tests.md) | Dictation stall — real-audio integration tests | **PARTIAL** | P2 | Tier 1 expanded/shipped; Tier 2 (broader real-platform matrix) deferred. |
| [2026-06-13-live-dictation-streaming-parakeet-and-preview-ui](active/2026-06-13-live-dictation-streaming-parakeet-and-preview-ui.md) | Live dictation preview — pill UI revamp + single-flight tail-window preview | **PARTIAL** | P2 | Preview pipeline shipped as #517 and `AppFeatures.liveDictationStreamingEnabled = true` on `main`; the Nemotron English build also streams live partials now (this branch). Settled after two adversarial reviews. **Part A** lifts the preview out of the capsule so the pill keeps its shape (view-only, LOW risk, ship-alone). **Part B** extends the preview from Nemotron-only to Parakeet (+ Whisper if a latency probe clears), behind `AppFeatures.liveDictationStreamingEnabled`. Durable decision: **preview is display-only ephemeral tail text, never the paste**. Mechanism = simplest that works: **single-flight tail-window batch re-transcribe** reusing the existing manager (NOT SlidingWindow/LocalAgreement/confirmed-volatile/trimming — cut as owned, unneeded complexity). The real work is the well-defined plumbing: a decoupled sample sink + an explicit sample-preview scheduler API + single-flight + cancel/drain-on-stop — **build that vertical slice first** (Parakeet/Whisper have no live frames today; the scheduler rejects an interactive final while a live session is held). Amends REQ-STT-002. Design+reviews: `docs/research/live-dictation-streaming.md` §0. |
| [2026-06-issue-474-instant-dictation-media-pause-bleed](active/2026-06-issue-474-instant-dictation-media-pause-bleed.md) | Issue #474 — media bleeds into transcript head | **PARTIAL** | P2 | Tiers 0+1 shipped (#474/#482). Tier 2 owner-deferred pending instrumentation + a 2nd report. Plan's own rule: don't archive until Tier 2 is built or formally rejected. |
| [2026-05-speaker-diarization-quality](active/2026-05-speaker-diarization-quality.md) | Speaker Diarization Quality | **PARTIAL** | P3 | The headline deliverable — speaker-count hint plumbing (`SpeakerDiarizationConstraint.exact/.range` into `OfflineDiarizerConfig.withSpeakers`) — is shipped in `DiarizationService`. Quality-tuning follow-ups and the `Deferred Work` tail remain. See also the newer `docs/plans/2026-06-14-002-speaker-diarization-world-class-architecture.md` (speaker-identity/memory layer, PROPOSED) and `docs/research/speaker-diarization-frontier-2026-06.md`. |
| [2026-05-dictation-paste-targeting-ux](active/2026-05-dictation-paste-targeting-ux.md) | Dictation Paste Targeting UX | **DECISION** | P3 | Finish-target model is the settled product rule. Follow-up hardening (editable-target detection, insertion verification, diagnostics) open. |
| [cli-as-canonical-parakeet-surface](active/cli-as-canonical-parakeet-surface.md) | CLI as canonical Parakeet-on-Apple-Silicon surface | **PARTIAL** | P3 | CLI completeness shipped (PR #138). Remaining is positioning/distribution (semver-public surface, brew path) for the agent-operator audience — a packaging push, not a build. |
| [2026-05-voice-command-agent-mode](active/2026-05-voice-command-agent-mode.md) | Voice Command & Agent Mode | **PROPOSED** | — | Exploration/direction. The selected-text-rewrite slice is carved out into the buildable [2026-06-21-spoken-transforms](active/2026-06-21-spoken-transforms.md); only the broader app-action / agent-handoff / macro scope stays parked here. Candidate to relocate to `deferred/` if the rest stays parked. |
| [2026-06-21-spoken-transforms](active/2026-06-21-spoken-transforms.md) | Spoken Transforms — voice instruction over a selection | **PROPOSED** | — | Revives the removed F10a "Command Mode" (select text → speak an instruction → LLM rewrites it in place) by composing the shipped Transforms pipeline (ADR-022) with the dictation hold-to-talk/Parakeet path — the original local-LLM blocker is gone. Text-in/text-out on a selection only; no app actions or agent loop (those stay in the agent-mode plan). New code = one `SpokenTransformCoordinator` + a dedicated hold hotkey; the LLM/CLI path is already proven (`llm transform --prompt`). Behind `AppFeatures.spokenTransformsEnabled` (default off). Resolves ADR-022's reserved voice-trigger non-decision. |
| [2026-06-15-dx-format-lint-baseline](active/2026-06-15-dx-format-lint-baseline.md) | swift-format + .editorconfig + dev scripts + informational CI | **VERIFY-THEN-ARCHIVE** | P2 | Implemented in this branch: `.editorconfig`, `.swift-format`, opt-in format/check scripts, non-blocking CI lint, and AGENTS inner-loop note. Confirm merge, then archive. |
| [2026-06-15-settings-observer-fanout-collapse](active/2026-06-15-settings-observer-fanout-collapse.md) | Table-driven AppSettingsObserverCoordinator | **VERIFY-THEN-ARCHIVE** ✅ | P2 | Implemented in this branch: 10 plain setting-change observers now register through a table-driven loop + token array, with onboarding/settings payload observers still explicit. Verified with `swift build`, focused coordinator tests, full `swift test`, Swift 6 no-Whisper build, and structural counts. Confirm commit/merge, then archive. |
| [2026-06-15-settings-engine-characterization-tests](active/2026-06-15-settings-engine-characterization-tests.md) | Characterize the Settings engine/model surface | **VERIFY-THEN-ARCHIVE** ✅ | P2 | Implemented in this branch: 19 characterization tests pin selection defaults/persistence, switch-confirmation state, unavailable-message copy, and injected model-cache refresh behavior for the `SettingsViewModel` engine slice. Verified with `swift build`, focused new/existing Settings filters, and full `swift test`. |
| [2026-06-15-settings-engine-viewmodel-extraction](active/2026-06-15-settings-engine-viewmodel-extraction.md) | Extract EngineSettingsViewModel (extract-and-delegate) | **VERIFY-THEN-ARCHIVE** ✅ | P2 | Implemented in this branch: `EngineSettingsViewModel` owns the engine/model state, status refresh, downloads, repair, deletion, and switch-confirmation logic; `SettingsViewModel` holds `engine` and forwards the existing public surface, including the static unavailable-message helper. Existing views remain untouched. |
| [2026-06-15-transcript-formatter-dedup](active/2026-06-15-transcript-formatter-dedup.md) | Shared TranscriptFormatter (kill the dup AI-formatter path) | **VERIFY-THEN-ARCHIVE** ✅ | P2 | Implemented in this branch: shared `TranscriptFormatter` + unified `FormatterOutcome`, Dictation/Transcription delegate to it (services −145 lines), 8 focused formatter tests added. Post-review tightening (Codex + Gemini converged): the five per-caller differences collapse into a typed `Lane` enum (4-param `format()`) so impossible states are unrepresentable. Capture-telemetry-emitter dedup remains deferred as a follow-up. |
| [2026-06-21-refinement-validator](active/2026-06-21-refinement-validator.md) | RefinementValidator — guard AI-formatter output, fall back to baseline | **EXECUTOR-READY** | P2 | Follow-on to the shared `TranscriptFormatter`. Adds a pure, deterministic validator (empty / length-runaway / repetition-loop / low-content-overlap) at the single `format()` chokepoint, per `Lane`, behind a default-on `AppFeatures` kill switch; a rejection reuses the existing fallback-to-baseline return shape. Closes a **live** gap: file/URL + meeting formatting ships **on by default** with only an empty-string guard on LLM output. Phase A (pure type + tests) ships standalone; Phase B wires it; rejection telemetry deferred (two-repo allowlist). Transforms explicitly excluded (intentional rewrites). |

> [`active/2026-06-12-advisor-index.md`](active/2026-06-12-advisor-index.md) and
> [`active/2026-06-15-advisor-index.md`](active/2026-06-15-advisor-index.md) are
> **audit narratives** (findings, refutations, deferred items) — not plans. The
> 2026-06-15 run is the architecture/maintainability pass; it spawned the five
> `2026-06-15-*` plans above and records the reviewed-but-unplanned items (LLM
> seams, STTRuntime, the other god-object services, App-layer cleanups). This
> board mirrors plan status; those files remain the reasoning record.

## Execute next (recommended order)

1. **Ship dictation-first onboarding (Part A).** Biggest activation lever, low risk, telemetry-backed. Plan is executor-grade as of 2026-06-13 — dispatchable now. (Funnel is already instrumented via `onboarding_step`; the lift is confirmed by post-ship analysis, not new telemetry — see the plan's "Verifying the lift".)
2. **Dispatch the two P1/P2 executor-ready test plans** (onboarding-stall-watchdog → june-churn regression). They close the named coverage gaps in the highest-incident area.
3. **Dispatch boundary contract docs + contract tests** before destructive meeting-retention work or broader meeting workspace automation. It makes artifact, recovery/retention, and CLI JSON boundaries explicit and test-linked.
4. **Land the telemetry-allowlist CI guard**, then add the `WEBSITE_REPO_TOKEN` secret to enforce it.

## Dependency notes

- No hard blockers between active plans. Soft sequencing: land the onboarding-stall watchdog test (#2) before/with the onboarding rework (#1) so the warm-up path has a safety net under it.
- The two engine-switch plans are a pair: `ux-revamp` (Stage A, partial) is the parent; `stage-b` is its on-hold continuation. Both gate on the A3 cold-switch telemetry before the reactive flow is greenlit.

## Recently archived → `completed/` (2026-06-21)

- **2026-06-19-boundary-contracts** → shipped as #567 (`2c4f76ebf`):
  `spec/contracts/` (README, `cli-json-v1`, `meeting-artifacts-v1`,
  `meeting-recovery-retention`) plus their contract tests are live on `main`.
  Acceptance criteria re-verified in the 2026-06-21 audit; moved out of `active/`.

## Recently archived → `completed/` (2026-06-18)

- **parakeet-unified-engine** → Phase 1 shipped as #552 (`656031f11`):
  selectable English-only Parakeet Unified model in Settings and CLI, routed
  through `ParakeetUnifiedEngine`; native Unified streaming remains a follow-up.

## Recently archived → `completed/` (2026-06-13 reconcile)

These were merged/resolved but left in `active/`; moved with a ship-evidence note in each header:

- **2026-05-meeting-neural-echo-suppression** → shipped #480/#485 (`c1f3b141f`)
- **2026-05-meeting-recording-cpu-debug** + **-HANDOFF** → shipped #396 (`80aeb9e32`)
- **2026-05-dictation-media-pause** → shipped #355/#383/#418 (spike resolved Yellow)
- **2026-05-nab-feedback-asap-bugs** → P0 raw-mic (`92c3dfdfb`) + P1s + P2 implemented; only a non-reproduced watchlist item remained
- **issue-224-screen-capturekit-recording-stop** → GitHub issue #224 closed 2026-05-11
- **2026-06-advisor-index** (prior `f8e28be91` run) → historical record; superseded by the active `2026-06-12-advisor-index.md`

## Findings considered and not re-opened

- The 2026-06-09 two-pass audit (`docs/audits/2026-06-09-codebase-audit.md`) and the 2026-06-12 advisor run cleared the correctness/security/race surface (≈70% of P0/P1 race claims refuted). Don't re-mine it — see the advisor index's "considered and rejected" section.
- God-file decomposition (`SettingsView` now 3467, `TranscriptResultView` 3112, `SettingsViewModel` now 2568) is real but high-risk with no test net. **Update (2026-06-15):** the `SettingsViewModel` **Engine slice** now has a test-first path — `2026-06-15-settings-engine-characterization-tests` (pin behavior) → `2026-06-15-settings-engine-viewmodel-extraction` (extract-and-delegate), executing the stalled `EngineSettingsViewModel` row of `2026-04-settings-ia-overhaul` §3. The remaining slices (Capture/Dictation/Transcription/Meeting/System) and the two view god-structs stay folded into the IA plan until a net exists. See `2026-06-15-advisor-index.md` for the full architecture findings (incl. the deferred LLM-layer, STTRuntime, and App-layer items).
