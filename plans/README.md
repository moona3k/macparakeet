# Implementation Plans — Status Board

> Single source of truth for what's actually in flight. Reconciled
> **2026-06-13** against `main` HEAD `eb123cc35` by cross-referencing every
> plan in `active/` with git history, merged PRs, and the live codebase.
>
> Layout: `active/` = open or partially-open work · `completed/` = shipped
> (kept as the record, never deleted) · `deferred/` = parked.
> Per-subsystem rules live in `Sources/MacParakeetCore/<subsystem>/README.md`.

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
| [2026-05-dictation-first-onboarding](active/2026-05-dictation-first-onboarding.md) | Dictation-first onboarding | **EXECUTOR-READY** ⭐ | **P1** | Confirmed *not* shipped — onboarding is still 8 steps on `main` (`OnboardingViewModel.Step`), with Meeting Recording + Calendar in the critical path before hotkey/engine setup. Your own funnel analysis records a **−21pt completion cliff** at that screen-recording step. **Highest activation leverage in the backlog.** Plan refreshed to executor-grade 2026-06-13 (drift check, per-step verify gates, done criteria, post-ship funnel recipe). Part A (8→6 steps) is pure subtraction, ship-on-its-own; Part B (download head-start) soft-depends on the warm-up watchdog test. |
| [2026-06-onboarding-stall-watchdog-test](active/2026-06-onboarding-stall-watchdog-test.md) | Make the warm-up stall watchdog testable + test it | **EXECUTOR-READY** | **P1** | Closes a trust-critical coverage gap on the onboarding model warm-up (incident history: silent stalls). Dispatchable now. |
| [2026-06-12-telemetry-allowlist-ci-guard](active/2026-06-12-telemetry-allowlist-ci-guard.md) | Cross-repo telemetry allowlist CI guard | **EXECUTOR-READY** ✅ | P2 | Re-verified 2026-06-13: assumptions hold, repos in sync (97 events, 0 missing). Closes a 3×-recurring silent data-loss class. **One follow-up only a maintainer can do:** add the `WEBSITE_REPO_TOKEN` CI secret to flip it from skip→enforce. |
| [2026-06-12-june-churn-regression-tests](active/2026-06-12-june-churn-regression-tests.md) | Regression tests: mic self-heal + Nemotron live dictation | **EXECUTOR-READY** | P2 | Adds the missing assertions on the June audio/STT hardening (#496, #507). Dispatchable now. |
| [2026-04-settings-ia-overhaul](active/2026-04-settings-ia-overhaul.md) | Settings IA Overhaul | **PARTIAL** | P2 | Tabbed `Modes/Engine/AI/System` shell, search index, tab persistence, card moves all shipped. Remaining: follow-up polish + the `SettingsView`/`SettingsViewModel` god-file decomposition (3278 / 2246 LOC). |
| [2026-05-ai-setup-ux](active/2026-05-ai-setup-ux.md) | AI Setup UX | **VERIFY-THEN-ARCHIVE** | P2 | Most shipped (#419/#428/#484: discovery, fallback, save-above-formatter, app-aware profiles). Confirm Phase 5 (LM Studio/Ollama one-click) + Phase 6 test coverage landed, then archive. |
| [2026-05-engine-switch-ux-revamp](active/2026-05-engine-switch-ux-revamp.md) | Engine Switch UX Revamp | **PARTIAL** | P2 | Stage A shipped (PR #335: cold/warm tile copy, optimized-variant persistence). A3 + the full reactive flow are **on hold pending telemetry**. |
| [2026-05-engine-switch-stage-b-background-optimize](active/2026-05-engine-switch-stage-b-background-optimize.md) | Engine Switch Stage B (background optimize + real cancel) | **ON HOLD** | P3 | A3 (`was_cold`/`mode` telemetry) ready to build; full reactive Stage B **not greenlit** — cold-compile contention was unmeasurable on-device (§0). Instrument first, then decide. |
| [2026-05-dictation-stall-integration-tests](active/2026-05-dictation-stall-integration-tests.md) | Dictation stall — real-audio integration tests | **PARTIAL** | P2 | Tier 1 expanded/shipped; Tier 2 (broader real-platform matrix) deferred. |
| [2026-06-13-live-dictation-streaming-parakeet-and-preview-ui](active/2026-06-13-live-dictation-streaming-parakeet-and-preview-ui.md) | Live dictation preview — pill UI revamp + all-engine streaming | **TODO** | P2 | New (2026-06-13); hardened by an adversarial code review. **Part A** lifts the preview out of the capsule so the pill keeps its shape (view-only, LOW risk, ship-alone). **Part B** extends the preview from Nemotron-only to Parakeet (+ Whisper if a latency probe clears), behind `AppFeatures.liveDictationStreamingEnabled`. Durable decision: **preview is display-only, never the paste** (final/paste path unchanged). Mechanism settled by study: **Parakeet → FluidAudio `SlidingWindowAsrManager`** (ships windowing/timings/confirmed-volatile; reuses loaded model); Nemotron keeps native streaming. Review found real blockers — **build the vertical slice first** (decoupled sample sink for Parakeet/Whisper + scheduler-safe preview job + cancel/drain-on-stop), since Parakeet/Whisper have **no live frames today** and the scheduler rejects an interactive final while a live session is held. Amends REQ-STT-002. Design+review: `docs/research/live-dictation-streaming.md` §0. |
| [2026-06-issue-474-instant-dictation-media-pause-bleed](active/2026-06-issue-474-instant-dictation-media-pause-bleed.md) | Issue #474 — media bleeds into transcript head | **PARTIAL** | P2 | Tiers 0+1 shipped (#474/#482). Tier 2 owner-deferred pending instrumentation + a 2nd report. Plan's own rule: don't archive until Tier 2 is built or formally rejected. |
| [2026-05-speaker-diarization-quality](active/2026-05-speaker-diarization-quality.md) | Speaker Diarization Quality | **TODO** | P3 | Planning complete (FluidAudio config, hint plumbing); implementation largely unshipped. Large plan with a `Deferred Work` tail. |
| [2026-05-dictation-paste-targeting-ux](active/2026-05-dictation-paste-targeting-ux.md) | Dictation Paste Targeting UX | **DECISION** | P3 | Finish-target model is the settled product rule. Follow-up hardening (editable-target detection, insertion verification, diagnostics) open. |
| [cli-as-canonical-parakeet-surface](active/cli-as-canonical-parakeet-surface.md) | CLI as canonical Parakeet-on-Apple-Silicon surface | **PARTIAL** | P3 | CLI completeness shipped (PR #138). Remaining is positioning/distribution (semver-public surface, brew path) for the agent-operator audience — a packaging push, not a build. |
| [2026-05-voice-command-agent-mode](active/2026-05-voice-command-agent-mode.md) | Voice Command & Agent Mode | **PROPOSED** | — | Exploration/direction. Candidate to relocate to `deferred/` if it stays parked. |

> [`active/2026-06-12-advisor-index.md`](active/2026-06-12-advisor-index.md) is
> the **audit narrative** for the 2026-06-12 advisor run (findings, refutations,
> opportunistic items) — not a plan. This board mirrors the status of the three
> plans it spawned; that file remains the reasoning record.

## Execute next (recommended order)

1. **Ship dictation-first onboarding (Part A).** Biggest activation lever, low risk, telemetry-backed. Plan is executor-grade as of 2026-06-13 — dispatchable now. (Funnel is already instrumented via `onboarding_step`; the lift is confirmed by post-ship analysis, not new telemetry — see the plan's "Verifying the lift".)
2. **Dispatch the two P1/P2 executor-ready test plans** (onboarding-stall-watchdog → june-churn regression). They close the named coverage gaps in the highest-incident area.
3. **Land the telemetry-allowlist CI guard**, then add the `WEBSITE_REPO_TOKEN` secret to enforce it.

## Dependency notes

- No hard blockers between active plans. Soft sequencing: land the onboarding-stall watchdog test (#2) before/with the onboarding rework (#1) so the warm-up path has a safety net under it.
- The two engine-switch plans are a pair: `ux-revamp` (Stage A, partial) is the parent; `stage-b` is its on-hold continuation. Both gate on the A3 cold-switch telemetry before the reactive flow is greenlit.

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
- God-file decomposition (`SettingsView` 3278, `TranscriptResultView` 3077) is real but high-risk with no test net; folded into `2026-04-settings-ia-overhaul`, not a standalone plan.
