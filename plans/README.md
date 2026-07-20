# Implementation Plans — Status Board

> Single source of truth for what's actually in flight. Reconciled
> **2026-07-16** against `main` after the stable v0.7.3 release and the
> reliability wave through #822. Completed implementation records and obsolete
> CLI 2.3.1 campaign snapshots were archived during this reconciliation; rows
> below represent work with a real open remainder.
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
| **PR OPEN** | Implemented and locally verified; hosted checks/review remain. |
| **PARTIAL** | Some phases shipped; a defined remainder is open. |
| **ON HOLD** | Deliberately parked (usually pending telemetry/decision). |
| **DECISION** | A settled product rule, not buildable work; follow-up hardening only. |
| **PROPOSED** | Exploration/direction; not committed work. |
| **VERIFY-THEN-ARCHIVE** | Appears shipped; confirm acceptance criteria before moving to `completed/`. |

## Active plans

| Plan | Title | Status | Priority | What's left |
|------|-------|--------|----------|-------------|
| [2026-07-20-dapt-export](active/2026-07-20-dapt-export.md) | DAPT original-transcript export (#850) | **PR OPEN** | P1 | Implementation, external W3C/BBC validation, full-suite gate, and fresh-eye remediation are complete on PR #854. Exact-head merge-readiness evidence is tracked on the PR; archive after merge. |
| [2026-07-03-speaker-voiceprints](active/2026-07-03-speaker-voiceprints.md) | Persistent speaker profiles (voiceprints) | **PROPOSED** | P2 | Research-backed plan for issue #662: enroll a speaker once (via the existing rename flow), auto-suggest their name in future diarized recordings by matching FluidAudio's per-speaker 256-d embeddings (already free in every offline diarization) against a local GRDB profile store. Opt-in, on-device, suggestions-require-confirmation; embeddings stored only for explicitly enrolled speakers (ambient "appeared in N recordings" detection deferred to Phase 3 as its own privacy decision). 5 research reports in `docs/research/2026-07-03-speaker-voiceprints/`. Next: Daniel's 4 open-question calls, then **Phase 0 calibration spike** (intra/inter-speaker distance separation on the retained meeting corpus → τ + margin + GO/NO-GO) before any product code. Concretizes the speaker-memory layer of `docs/plans/2026-06-14-002`. |
| [2026-07-03-parakeet-custom-vocabulary](active/2026-07-03-parakeet-custom-vocabulary.md) | Parakeet custom vocabulary (names/jargon boosting) | **TODO** | P2 | ADR-026 roadmap #1, sequenced after registry Phase A. FluidAudio 0.15.4 (pinned) already ships the API (`CustomVocabularyContext` via `SlidingWindowAsrManager`). Phase 0: choose the integration seam for our TDT paths + term-recall eval with WER-regression bound. MUST reuse existing `CustomWord`/Vocabulary feature (no second store). Daniel decision gate after Phase 0. |
| [2026-07-03-cjk-local-engines](active/2026-07-03-cjk-local-engines.md) | CJK local coverage — Parakeet-JA + SenseVoiceSmall | **TODO** | P2 | ADR-026 roadmap #2, sequenced after registry Phase A. Both models already in pinned FluidAudio 0.15.4. Slice 0: harness enablement (FLEURS runner + CLI can't name these models today). Then benchmark gate (FLEURS ko/ja/zh CER vs Whisper, paired-bootstrap): ship what wins, kill what doesn't. Product slice requires registry Phase A + a short variant-axis design (SpeechEngineSelection nils Parakeet language today); UI-placement decision for Daniel. |
| [2026-07-03-apple-speechtranscriber-spike](active/2026-07-03-apple-speechtranscriber-spike.md) | Apple SpeechTranscriber spike — evaluate, don't integrate | **TODO** | P2 | ADR-026 §6. ~2-day timebox: asset/locale reality, first-known WER numbers via benchmarks/asr adapter, streaming-fit + constraints inventory, pre-committed go/no-go rubric (onboarding bridge; long-tail fallback). Output = docs PR, no product wiring. |
| [2026-06-27-on-device-local-llm](active/2026-06-27-on-device-local-llm.md) | On-device local LLM (self-optimized MLX model) | **PROPOSED** | P2 | First-principles plan for a first-party on-device LLM powering transcript cleanup + summary + QA + (later) tool-calling, one click (not bundled). Strategy: hyper-focus on **one engine (MLX)** + one self-optimized model (Apache base → convert/quantize/fine-tune, Qwen3-4B start; our own model as endgame). BYO = MLX models; Apple Foundation Models = optional no-download fallback. Addresses #439/#265/#550; relates #460/#563/#408. Needs Daniel decisions (§11) + a Phase 0 spike/eval gate. |
| [2026-06-27-on-device-local-llm-phase0-eval](active/2026-06-27-on-device-local-llm-phase0-eval.md) | On-device local LLM — Phase 0 eval design | **PROPOSED** | P2 | Companion to the plan above: defines **what to measure and how** before any inference code. Reframes cleanup as a near-subtractive edit (dominant risk = over-editing) → asymmetric eval: deterministic fidelity **gates** (entity/number diff, bidirectional NLI) + graded quality (SARI, ERRANT-F0.5) + calibrated cloud LLM-judge. Long transcripts → map-reduce/RAG (architecture > model size). Includes gold-set recipe, MLX perf benchmarks to run, model bake-off, and go/no-go. Research-backed (5-agent synthesis). |
| [2026-05-dictation-first-onboarding](active/2026-05-dictation-first-onboarding.md) | Dictation-first onboarding | **VERIFY-THEN-ARCHIVE** (A+B shipped) | **P1** | **Part A shipped** as #515 (`4e2303d4b`): onboarding is now 6 steps (Meeting Recording + Calendar removed), recovering the **−21pt completion cliff**. **Part B shipped** as #519 (`76073c79a`): the ~465 MB speech-model download now starts at onboarding open and overlaps the permission/hotkey steps (timing only). Guards §5.1–5.4 implemented (engineBusy decoupling, CJK-fork preserved, failure suppressed before the engine step, telemetry shift documented); 4 tests incl. a mutation-verified suppression test. Remaining: verify the funnel lift by app version, then archive. |
| [2026-06-12-telemetry-allowlist-ci-guard](active/2026-06-12-telemetry-allowlist-ci-guard.md) | Cross-repo telemetry allowlist CI guard | **EXECUTOR-READY** ✅ | P2 | Re-verified 2026-06-13: assumptions hold, repos in sync (97 events, 0 missing). Closes a 3×-recurring silent data-loss class. **One follow-up only a maintainer can do:** add the `WEBSITE_REPO_TOKEN` CI secret to flip it from skip→enforce. |
| [2026-06-12-june-churn-regression-tests](active/2026-06-12-june-churn-regression-tests.md) | Regression tests: mic self-heal + Nemotron live dictation | **EXECUTOR-READY** | P2 | Adds the missing assertions on the June audio/STT hardening (#496, #507). Dispatchable now. |
| [2026-06-19-meetings-workspace-productization](active/2026-06-19-meetings-workspace-productization.md) | Meetings workspace productization | **PROPOSED** | P2 | Product research-backed staged plan: make Meetings a compact daily workspace, expose artifact folders/paths, add DB-backed folders/projects, add local indexing before cross-meeting Ask, and create a full-app meeting smoke harness. |
| [2026-07-10-meeting-knowledge-layer](active/2026-07-10-meeting-knowledge-layer.md) | Meeting knowledge layer — segments, FTS, cards, agent search | **PARTIAL** | P1 | Phase 1 (segments, FTS5, agent-search CLI) shipped as #781 and Phase 2 (derived cards/backfill/CLI) as #784. Phase 3 agent retrieval guidance and Phase 4 optional semantic retrieval remain open; re-validate their value against the shipped CLI before execution. |
| [2026-06-18-meeting-auto-title-followups](active/2026-06-18-meeting-auto-title-followups.md) | Manual and bulk meeting title generation | **PARTIAL** | P2 | Automatic post-meeting titles shipped as #553 and issue #546 is closed. The explicit single-item and bounded bulk actions for older timestamp-named meetings remain unimplemented; execute only if backlog cleanup is still a product priority. |
| [2026-07-04-meeting-health-artifacts-speaker-rename](active/2026-07-04-meeting-health-artifacts-speaker-rename.md) | Meeting health, artifact promotion, and speaker rename | **PROPOSED** | **P1/P2** | Executor-ready plan for visible mic/system health, cleaned mic + Markdown artifact promotion, agent-friendly CLI meeting command/spec polish, and per-meeting speaker rename UX. Explicitly excludes AEC/source-trust closure and live diarization. |
| [2026-07-04-context-engine-agent-tools](active/2026-07-04-context-engine-agent-tools.md) | Context Engine for Library and agent tools | **PROPOSED (experimental)** | P3 | Parking lot for the Context Engine direction and naming discussion; not an approved architecture. First valid slice is read-only context retrieval with JSON output and citations. Reconcile with the meetings-workspace plan before building. |
| [2026-07-04-issue-647-local-transcription-title-rename](active/2026-07-04-issue-647-local-transcription-title-rename.md) | Local transcription title rename | **IMPLEMENTED in branch** | P1 | Covers the rename portion of issue #647 only: persisted `titleOverride`, Library/detail rename UX for Local file transcriptions, effective-title search/sort/display/export suggestions, and docs/tests. Explicitly excludes copy-on-import/media retention and public CLI title-contract changes. |
| [2026-06-14-meeting-auto-stop](active/2026-06-14-meeting-auto-stop.md) | Activity-based meeting auto-stop | **PARTIAL** | P2 | Phases A+B shipped as #522 (silence + app-quit signals, veto countdown) behind `AppFeatures.meetingAutoStopEnabled` (flag on `main`; per-user setting default off). Phase C (attribution-aware stop) deferred to ADR-024 — see the orchestration plan. ADR-023, REQ-MEET-015. |
| [2026-06-14-meeting-auto-stop-orchestration](active/2026-06-14-meeting-auto-stop-orchestration.md) | Meeting auto-stop — execution/orchestration guide | **VERIFY-THEN-ARCHIVE** | P3 | Execution aid for the now-shipped #522; remaining value is the Phase C handoff context. Fold into the auto-stop plan or archive once Phase C scope is settled. |
| [2026-06-14-meeting-mic-reliability](active/2026-06-14-meeting-mic-reliability.md) | Meeting capture reliability — mic-health watchdog | **PARTIAL** | P2 | Phase A shipped as #523 (metadata-only mic-health telemetry watchdog) behind default-on `AppFeatures.meetingCaptureReliabilityEnabled`. Phase B (warning UI) + Phase C (post-stop coverage repair) remain. ADR-025, REQ-MEET-017/018. |
| [2026-06-14-meeting-activity-detection](active/2026-06-14-meeting-activity-detection.md) | Activity-based meeting detection foundation | **PARTIAL** | P2 | Phases A+B shipped as #524/#525 (per-process audio attribution + camera activity + pure detector) behind default-off `AppFeatures.meetingActivityDetectionEnabled`; no runtime coordinator/UI yet. Coordinator/prompt phases tracked in `docs/plans/2026-06-14-001-feat-rich-meeting-detection-plan.md`. ADR-024, REQ-MEET-016. |
| [2026-07-04-long-meeting-aec-policy](active/2026-07-04-long-meeting-aec-policy.md) | Long-meeting AEC + diarization policy (guard, benchmark, enrichment) | **PARTIAL** (Phase 1 shipped) | **P1** | Post-#688, the full AEC + dual-STT + diarization load is the DEFAULT dual-track path; meetings >~2 h deterministically waste a 10-min render (timeout cancels + discards, `MeetingCleanedMicrophoneReadiness.swift:145-153`). Phase 1 COMPLETE incl. what its first real run caught: harness validity fix #703 + adaptive-delay estimator perf fix #704 (render 0.5x -> 11.7x, was blocking cleaned mic for >5 min meetings). Decision gate CLOSED (see `docs/audits/2026-07-04-long-meeting-full-pipeline-findings.md`): guard stays 12.59/~2.1 h; 42.7-min meeting fully enriches 4m12s after stop. Remaining: Phase 2 enrichment lane (GO in principle, P2 — watch `predictedRenderTimeout` frequency); Phase 3 chunked render PROPOSED (RAM, ~2.5 GB at 3 h). Governing brief: `docs/audits/2026-07-04-long-meeting-aec-diarization-queue-followup.md`. |
| [2026-06-27-meeting-aec-measurement-harness](active/2026-06-27-meeting-aec-measurement-harness.md) | Meeting AEC measurement harness | **PARTIAL** | **P1** | Gates the #605 echo/bleed cluster (next meeting P0). Test-only harness shipped: ground-truth fixtures (far-end-only / near-end-only / double-talk) + ERLE/near-end metrics + NLMS & oracle baselines, run through the real `StreamingMeetingEchoSuppressor`. First numbers: aligned oracle 56 dB vs 2.5 ms-misaligned −2.7 dB (alignment is the dominant risk); NLMS 36 dB single-talk but a slight regression under double-talk. Remaining: adaptive delay estimation, LocalVQE + WebRTC AEC3 adapters scored on the same fixtures, nonlinear/real-recording fixtures. |
| [2026-06-28-meeting-aec-full-close](active/2026-06-28-meeting-aec-full-close.md) | Meeting AEC full close for #605 | **PARTIAL** | P1 | The adaptive-delay path, cleaned-mic artifact/final-STT routing, release assets, diagnostics, and model gate shipped across #646/#650/#651/#654/#681 and follow-ups. Issue #605 remains open; the honest remainder is real speaker-mode QA and deciding whether any WebRTC/feedback-surface follow-up is still warranted, not a v0.7.3 release blocker. |
| [2026-04-settings-ia-overhaul](active/2026-04-settings-ia-overhaul.md) | Settings IA Overhaul | **PARTIAL** | P2 | Tabbed `Modes/Engine/AI/System` shell, search index, tab persistence, card moves all shipped. Remaining: follow-up polish + the `SettingsView`/`SettingsViewModel` god-file decomposition (3278 / 2246 LOC). |
| [2026-05-ai-setup-ux](active/2026-05-ai-setup-ux.md) | AI Setup UX | **VERIFY-THEN-ARCHIVE** | P2 | Most shipped (#419/#428/#484: discovery, fallback, save-above-formatter, app-aware profiles). Confirm Phase 5 (LM Studio/Ollama one-click) + Phase 6 test coverage landed, then archive. |
| [2026-05-engine-switch-ux-revamp](active/2026-05-engine-switch-ux-revamp.md) | Engine Switch UX Revamp | **PARTIAL** | P2 | Stage A shipped (PR #335: cold/warm tile copy, optimized-variant persistence). A3 + the full reactive flow are **on hold pending telemetry**. |
| [2026-05-engine-switch-stage-b-background-optimize](active/2026-05-engine-switch-stage-b-background-optimize.md) | Engine Switch Stage B (background optimize + real cancel) | **ON HOLD** | P3 | A3 (`was_cold`/`mode` telemetry) ready to build; full reactive Stage B **not greenlit** — cold-compile contention was unmeasurable on-device (§0). Instrument first, then decide. |
| [2026-05-dictation-stall-integration-tests](active/2026-05-dictation-stall-integration-tests.md) | Dictation stall — real-audio integration tests | **PARTIAL** | P2 | Tier 1 expanded/shipped; Tier 2 (broader real-platform matrix) deferred. |
| [2026-06-13-live-dictation-streaming-parakeet-and-preview-ui](active/2026-06-13-live-dictation-streaming-parakeet-and-preview-ui.md) | Live dictation preview — pill UI revamp + single-flight tail-window preview | **PARTIAL** | P2 | Preview pipeline shipped as #517 and `AppFeatures.liveDictationStreamingEnabled = true` on `main`; the Nemotron English build also streams live partials now (this branch). Settled after two adversarial reviews. **Part A** lifts the preview out of the capsule so the pill keeps its shape (view-only, LOW risk, ship-alone). **Part B** extends the preview from Nemotron-only to Parakeet (+ Whisper if a latency probe clears), behind `AppFeatures.liveDictationStreamingEnabled`. Durable decision: **preview is display-only ephemeral tail text, never the paste**. Mechanism = simplest that works: **single-flight tail-window batch re-transcribe** reusing the existing manager (NOT SlidingWindow/LocalAgreement/confirmed-volatile/trimming — cut as owned, unneeded complexity). The real work is the well-defined plumbing: a decoupled sample sink + an explicit sample-preview scheduler API + single-flight + cancel/drain-on-stop — **build that vertical slice first** (Parakeet/Whisper have no live frames today; the scheduler rejects an interactive final while a live session is held). Amends REQ-STT-002. Design+reviews: `docs/research/live-dictation-streaming.md` §0. |
| [2026-06-issue-474-instant-dictation-media-pause-bleed](active/2026-06-issue-474-instant-dictation-media-pause-bleed.md) | Issue #474 — media bleeds into transcript head | **PARTIAL** | P2 | Tiers 0+1 shipped (#474/#482). Tier 2 owner-deferred pending instrumentation + a 2nd report. Plan's own rule: don't archive until Tier 2 is built or formally rejected. |
| [2026-05-speaker-diarization-quality](active/2026-05-speaker-diarization-quality.md) | Speaker Diarization Quality | **PARTIAL** | P3 | The headline deliverable — speaker-count hint plumbing (`SpeakerDiarizationConstraint.exact/.range` into `OfflineDiarizerConfig.withSpeakers`) — is shipped in `DiarizationService`. Quality-tuning follow-ups and the `Deferred Work` tail remain. See also the newer `docs/plans/2026-06-14-002-speaker-diarization-world-class-architecture.md` (speaker-identity/memory layer, PROPOSED) and `docs/research/speaker-diarization-frontier-2026-06.md`. |
| [2026-05-dictation-paste-targeting-ux](active/2026-05-dictation-paste-targeting-ux.md) | Dictation Paste Targeting UX | **DECISION** | P3 | Finish-target model is the settled product rule. Follow-up hardening (editable-target detection, insertion verification, diagnostics) open. |
| [2026-05-voice-command-agent-mode](active/2026-05-voice-command-agent-mode.md) | Voice Command & Agent Mode | **PROPOSED** | — | Exploration/direction. The selected-text-rewrite slice is carved out into the buildable [2026-06-21-spoken-transforms](active/2026-06-21-spoken-transforms.md); only the broader app-action / agent-handoff / macro scope stays parked here. Candidate to relocate to `deferred/` if the rest stays parked. |
| [2026-06-21-spoken-transforms](active/2026-06-21-spoken-transforms.md) | Spoken Transforms — voice instruction over a selection | **PROPOSED** | — | Revives the removed F10a "Command Mode" (select text → speak an instruction → LLM rewrites it in place) by composing the shipped Transforms pipeline (ADR-022) with the dictation hold-to-talk/Parakeet path — the original local-LLM blocker is gone. Text-in/text-out on a selection only; no app actions or agent loop (those stay in the agent-mode plan). New code = one `SpokenTransformCoordinator` + a dedicated hold hotkey; the LLM/CLI path is already proven (`llm transform --prompt`). Behind `AppFeatures.spokenTransformsEnabled` (default off). Resolves ADR-022's reserved voice-trigger non-decision. |
| [2026-06-21-refinement-validator](active/2026-06-21-refinement-validator.md) | RefinementValidator — guard AI-formatter output, fall back to baseline | **EXECUTOR-READY** | P2 | Follow-on to the shared `TranscriptFormatter`. Adds a pure, deterministic validator (empty / length-runaway / repetition-loop / low-content-overlap) at the single `format()` chokepoint, per `Lane`, behind a default-on `AppFeatures` kill switch; a rejection reuses the existing fallback-to-baseline return shape. Closes a **live** gap: file/URL + meeting formatting ships **on by default** with only an empty-string guard on LLM output. Phase A (pure type + tests) ships standalone; Phase B wires it; rejection telemetry deferred (two-repo allowlist). Transforms explicitly excluded (intentional rewrites). |
| [2026-06-28-transcript-detail-refresh](active/2026-06-28-transcript-detail-refresh.md) | Transcript Detail Refresh (media-document reading) | **PARTIAL** (Phase 1 + U2 in branch) | P2 | The audit's "Move 1" (highest daily-use value). Mapping found much already ships — persistent `AudioScrubberBar`, auto-scroll-to-active, tap-to-seek, active-line highlight, selection — so scope narrows to the real gaps. **Implemented on `feat/transcript-detail-refresh`:** U1 per-segment hover actions (play-from-here / copy / copy-with-timestamp via shared `TranscriptSegmentRow`) + U4 reading font-size control (persisted `transcriptFontScale`, applied to Text + Timed); **U2 in-transcript find** (`⌘F` / `⌘G` / `⇧⌘G`, pinned `TranscriptFindBar`, testable `TranscriptFindModel` with 17 unit tests, `AttributedString` highlight + scroll-to-match in both Text and Timed modes). Remaining: U3 unify one quiet playback rail across video mode, U5 finish `TranscriptResultView` decomposition. Hard constraint: `TranscriptSegment` has no `endMs` (start-only). Grounded in Descript/IINA/iOS-Podcasts references. |
| [asr-benchmark-and-model-expansion](active/asr-benchmark-and-model-expansion.md) | Gold-standard ASR benchmark and model expansion | **PARTIAL / OWNER GATE** | P2 | Benchmark harness and Cohere evaluation shipped as #568; Cohere later shipped as an opt-in engine. The MLX-only Qwen3-ASR/Moonshine expansion remains deferred pending owner steer. Reconcile or close this record before starting another model-integration track. |

> [`active/2026-06-12-advisor-index.md`](active/2026-06-12-advisor-index.md) and
> [`active/2026-06-15-advisor-index.md`](active/2026-06-15-advisor-index.md) are
> **audit narratives** (findings, refutations, deferred items) — not plans. The
> 2026-06-15 run is the architecture/maintainability pass; it spawned five
> `2026-06-15-*` plans that are now archived under `completed/`, and records
> the reviewed-but-unplanned items (LLM
> seams, STTRuntime, the other god-object services, App-layer cleanups). This
> board mirrors plan status; those files remain the reasoning record.

## Execute next (recommended order)

1. **Close the real-world meeting AEC evidence gap.** The implementation has shipped; run the speaker-mode QA in `2026-06-28-meeting-aec-full-close` and use the result to close or narrow #605.
2. **Dispatch the remaining P2 test-hardening plans** (`june-churn-regression-tests`, then `refinement-validator`). They close named coverage gaps in high-churn audio/STT and formatter paths.
3. **Land the telemetry-allowlist CI guard**, then add the `WEBSITE_REPO_TOKEN` secret to enforce it.
4. **Reconcile partial product plans before new implementation.** In particular, decide whether manual/bulk meeting titles and Meeting Knowledge Layer Phases 3–4 still earn their scope now that their core slices ship.

## Dependency notes

- No hard blockers between active plans. Soft sequencing: keep meeting-audio changes behind the measurement harness, and prefer the remaining audio/STT regression tests before another broad capture/STT change.
- The two engine-switch plans are a pair: `ux-revamp` (Stage A, partial) is the parent; `stage-b` is its on-hold continuation. Both gate on the A3 cold-switch telemetry before the reactive flow is greenlit.

## Recently archived → `completed/` (2026-07-18)

- **2026-07-17-issue-767-audio-track-selection** → implemented in #839:
  conditional app picker for multi-track local files, explicit FFmpeg mapping,
  persistence/retranscription reuse, batch semantics, CLI `--audio-track`, and
  matching feature and boundary-contract documentation.

## Recently archived → `completed/` (2026-07-16)

- **Release/reliability implementation records:** `engine-settings-layout`
  (#819/#822), `2026-07-15-live-final-speech-routing` (#813),
  `2026-07-15-bounded-capture-lifecycle` (#814),
  `2026-07-05-meeting-artifact-naming-v2` (#744), and
  `2026-07-aec-artifact-provenance` (#676/#681).
- **Previously shipped feature records:** `2026-06-18-library-bulk-delete`
  (#572), `2026-06-18-meeting-back-to-back-recording` (commit `2667cd83`),
  `2026-06-onboarding-stall-watchdog-test` (#518),
  `nemotron-english-streaming-variant` (#503), and
  `live-dictation-preview-readout` (#534).
- **Architecture and developer-experience records:** STT capability-registry
  Phase A (#720), the five `2026-06-15-*` implementation plans (#544 and
  their merged follow-ups), and the shipped CLI strategy record.
- **Historical campaign snapshots:** the CLI 2.3.1 `community-posts/` and
  `registry-submissions/` drafts. They remain available as provenance, but are
  not current release copy or an active distribution checklist.

## Recently archived → `completed/` (2026-07-04)

- **2026-07-03-meeting-corpus-capture** → all five slices shipped in one day:
  #684 durable transcript segments (`6d255fd84`), #686 start context
  (`679bea9ae`), #687 calendar context snapshot + ADR-017 §6 amendment
  (`8f7fd7dfb`), #688 diarization default ON where supported (`cfbcccb30`),
  #689 raw-audio deletion warning copy (`358f2c460`). First ADR-027
  follow-through; capture-side only. Deferred remainders (provenance
  sidecar, speaker embeddings) are recorded in the plan.

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
