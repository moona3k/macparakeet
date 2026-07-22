# Meeting capture reliability — mic-health watchdog + post-stop coverage repair

**Status:** IN PROGRESS — Phase A detection/telemetry shipped in #523. Phase B
direct source-lifecycle recovery, actionable-only warning UI, and frame-derived
capture reporting shipped in #857/#860 on 2026-07-22; the earlier health and
artifact surface is recorded in
`plans/completed/2026-07-04-meeting-health-artifacts-speaker-rename.md`.
Post-stop VAD transcript-gap repair remains unimplemented.
**Date:** 2026-06-14
**ADRs:** ADR-025 (meeting capture reliability), ADR-014 (meeting recording), ADR-015 (concurrent dictation/meeting), ADR-016 (centralized STT runtime + two-slot scheduler), ADR-019 (crash-resilient meeting recording)
**Requirements:** REQ-MEET-017 (mic-health watchdog and direct callback-liveness recovery) — implemented; REQ-MEET-018 (post-stop coverage-based transcript repair) — proposed
**Sibling work:** `plans/active/2026-05-dictation-stall-integration-tests.md`, `plans/completed/2026-06-onboarding-stall-watchdog-test.md` — this is the meeting-side counterpart to the dictation silent-stall hardening; stay consistent, don't duplicate.

## What this plan closes out

ADR-019 made the meeting *bytes* crash-resilient (fragmented MP4 + lock-file recovery). ADR-025 originally identified two silent correctness gaps:

1. **A dead mic mid-meeting goes unnoticed.** This is now partially closed:
   callback cessation is a source-lifecycle failure with bounded fresh-engine
   recovery and actionable warnings. Amplitude-only/cross-source inference
   remains passive because legitimate silence is ambiguous.
2. **Live preview = final, lossy on drop.** The saved meeting transcript is assembled from live-preview chunks; any chunk the live path drops is lost permanently. Nothing re-reads the retained audio to ask "is the transcript actually complete?"

This plan now tracks the remaining ADR-025 work: post-stop coverage-based
transcript repair (REQ-MEET-018), plus any evidence-gated follow-up to passive
signal inference. The shipped callback-liveness recovery remains independent of
the presentation kill switch.

## Scope boundaries

### In scope
- Pure `MeetingMicHealthMonitor` (three stall signatures + ~3s system-audio confirmation gate) + table tests
- Wiring liveness signals from `MeetingAudioCaptureService` / `SharedMicrophoneStream` / `SystemAudioStream` into the monitor
- Source-owned bounded recovery for unambiguous callback/stream lifecycle failures
- Gentle, non-blocking actionable warnings while a source recovers or becomes unavailable
- Finalized writer-frame capture reports that distinguish captured audio from timeline padding
- Pure `MeetingTranscriptCoverageRepair` planner (coverage ratio + gap detection → accept / selective / full) + table tests
- Offline `MeetingVADService` pass over retained mic + system `.m4a` in the post-stop path
- Selective re-transcription of uncovered gaps on the **`STTScheduler` background slot**, write-back to the saved `Transcription` row
- Full re-transcription fallback tier for systemic live-chunk failure
- Applying the coverage-repair stage to crash-recovered sessions (ADR-019)
- `mic_stall_detected` + `meeting_transcript_repair` telemetry + website allowlist mirror
- `AppFeatures.meetingCaptureReliabilityEnabled` kill-switch (default-on intent)

### Out of scope
- **Amplitude- or cross-source-signal-inferred mic restart.** Raw callback
  cessation already recovers; acoustic silence remains valid input and stays
  detection-only until field evidence justifies a stronger action.
- Changing per-chunk transcription, the chunker (`SpeechBoundaryMeetingLiveAudioChunker` / `AudioChunker`), or `MeetingTranscriptAssembler` — repair is an additive stage on top (see REQ-MEET-013 reconciliation below).
- Diarization changes; speaker attribution of repaired gaps reuses the existing assembler path.
- Any cross-process / CI hardware-test infrastructure beyond what the dictation-stall plan already establishes.
- Re-tuning the dictation-side watchdog (separate plan).

### Invariants
- **Never lose user data** — repair only *adds* coverage; the original live transcript and the retained mic/system `.m4a` files are preserved exactly as ADR-019 leaves them.
- Dictation continues to work unchanged, concurrently (ADR-015).
- Repair never uses the reserved dictation slot; it is background-class and never starves dictation (ADR-016).
- Acoustic-signal monitoring remains passive. Direct callback/stream lifecycle
  recovery is source-owned, bounded, generation-fenced, and must never let a
  late retry revive capture after Stop.
- Crash recovery (ADR-019) still works and benefits from the same coverage repair.
- The deterministic decision cores (`MeetingMicHealthMonitor`, `MeetingTranscriptCoverageRepair`) stay **pure** — `now`/state passed in, no clocks, no AVAudioEngine, no STT inside the pure types.

## REQ-MEET-013 reconciliation (read before Phase C)

REQ-MEET-013 says VAD-guided live chunking leaves "final post-stop transcription … unchanged." That refers to **how an individual chunk is transcribed** — unchanged whether VAD live chunking is on or off. This plan does **not** touch per-chunk STT, the chunker, or the assembler. It **adds a completeness-repair stage** that re-runs STT **only for speech the live path missed**. For a healthy meeting (coverage high → Accept) the repair stage is a no-op and the final transcript is byte-identical to today's. When Phase C lands, narrow that old REQ framing in ADR-025 and the narrative specs; the legacy requirements index is archived and no longer updated.

## Phased rollout

### Phase A — Mic-health detection core (detection-only) — implemented 2026-06-14

Pure monitor + signals wiring + telemetry. **No UI, no recovery.** Instrumentation-only, to confirm the stall signature in the field before acting on it — mirroring PR #210's passive-instrumentation-first discipline on the dictation side.

| File | Change |
|------|--------|
| `Sources/MacParakeetCore/Audio/MeetingMicHealthMonitor.swift` *(new, pure)* | `ingest(micSignal:systemSignal:now:) -> [HealthEvent]`. Signatures `.micMissing` (no mic buffers while system active), `.micSilent` (mic buffers all-zero/near-silent while system active), `.micGap` (>~1s since last mic buffer while system active). ~3s continuous-system-audio confirmation gate before any trip. Emits `.stallSuspected(signature:)` and `.recovered`. Holds no clock — `now` passed in. |
| `Sources/MacParakeetCore/Audio/MeetingAudioCaptureService.swift` | Feed per-buffer liveness signals into the monitor: mic arrival timestamp + non-silent flag from `.microphoneBuffer` events; system activity flag from the system-audio path. Monitor instance owned/driven here; the existing `MeetingAudioCaptureEvent` stream is the source. |
| `Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift` | Add `mic_stall_detected` (props: `signature` = `mic_missing`/`mic_silent`/`mic_gap`, coarse `elapsed_ms`). No audio/transcript content. |
| `../macparakeet-website/functions/api/telemetry.ts` | Mirror `mic_stall_detected` into `ALLOWED_EVENTS`. **Deploy before any flag-on build** — the Worker rejects the whole batch on an unknown event. |
| `Sources/MacParakeetCore/AppFeatures.swift` | Add `meetingCaptureReliabilityEnabled` kill-switch (default-on intent), documented in the existing flag-doc style. When off: monitor does not observe, repair stage skipped. |

**Tests**
- `Tests/MacParakeetTests/Audio/MeetingMicHealthMonitorTests.swift` *(new)* — table tests: each signature fires only after the ~3s confirmation window; none fires while system audio is silent (genuine quiet, no false alarm); `.micGap` boundary at ~1s; `.recovered` after the mic resumes; mixed sequences (system active → mic dies → mic resumes). All deterministic via injected `now`.

**Ship criteria:** With the flag on, a stalled mic during a meeting (system audio active) emits exactly one `mic_stall_detected` with the right signature, after the confirmation window — and a genuinely quiet stretch emits nothing. No UI, no behavior change to the recording.

### Phase B — Direct lifecycle recovery + actionable warnings — implemented 2026-07-22

PRs #857/#860 made unambiguous source failures recoverable without promoting
ordinary silence to a restart signal. `MicrophoneEnginePlatform` rebuilds a
fresh engine after stopped configuration-change episodes or a five-second
post-start callback gap; typed ScreenCaptureKit first-buffer, heartbeat, and
unexpected-stop failures replace only the system source. Recovery requires a
real replacement buffer, duplicate failures coalesce, and Stop invalidates all
retry generations. Recovering, interrupted, stalled, and unavailable states
surface non-blocking actionable warnings even though routine health decoration
remains hidden. Finalization records writer-derived per-source coverage so
legacy missing reports mean unknown rather than healthy.

Focused platform, capture-service, view-model, storage-writer, report,
recovery, and meeting-service tests pin those boundaries. Actual Bluetooth
route-change behavior remains a physical signed-candidate QA gate.

### Phase C — Coverage-based selective repair

The completeness-repair stage. Pure planner + offline VAD + selective re-transcription on the background slot. This is the larger phase.

| File | Change |
|------|--------|
| `Sources/MacParakeetCore/Services/MeetingRecording/MeetingTranscriptCoverageRepair.swift` *(new, pure)* | `plan(liveSegments:offlineVADSegments:) -> RepairPlan`. `RepairPlan` = `.accept` / `.selective(gaps: [SpeechRegion])` / `.fullReTranscribe`. Coverage-ratio math + ≥~0.8s gap detection below a per-region coverage threshold. No STT, no audio I/O. |
| `Sources/MacParakeetCore/Services/MeetingRecording/MeetingVADService.swift` | Add/confirm an offline (non-streaming) pass over a retained `.m4a` returning the speech regions present in the audio. (Reuse the existing Silero machinery; this is offline analysis, not live chunking.) |
| `Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingService.swift` | After the existing finalize produces the saved transcript in `stopRecording()`, run the repair stage **async**: offline VAD pass over retained mic + system `.m4a` → `MeetingTranscriptCoverageRepair.plan(...)` → for `.selective`, enqueue gap re-transcription on `STTScheduler`'s **background slot** → splice results → write the repaired transcript back to the `Transcription` row. Must not block finalization UI; the meeting lands in the library on the live transcript and updates in place when repair completes. |
| `Sources/MacParakeetCore/Services/MeetingRecording/MeetingTranscriptFinalizer.swift` / `MeetingTranscriptAssembler.swift` | Splice helper to merge re-transcribed gap segments into the assembled transcript by timestamp; reuse the assembler's word/segment normalization. Per-chunk transcription itself is unchanged. |
| `Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift` | Add `meeting_transcript_repair` (props: `decision` = `accept`/`selective`/`full`, `gap_count`). No content. |
| `../macparakeet-website/functions/api/telemetry.ts` | Mirror `meeting_transcript_repair`. Deploy before flag-on. |

**Tests**
- `Tests/MacParakeetTests/MeetingRecording/MeetingTranscriptCoverageRepairTests.swift` *(new)* — table tests: full coverage → `.accept`; one gap ≥0.8s → `.selective` with the right region; sub-0.8s gaps ignored; very-low coverage → `.fullReTranscribe`; boundary cases on the coverage threshold; live segments that fully overlap VAD → no gaps.
- `Tests/MacParakeetTests/MeetingRecording/MeetingTranscriptRepairIntegrationTests.swift` *(new)* — with a mock STT scheduler, assert selective repair enqueues on the **background** slot (never the reserved dictation slot), the original transcript is preserved if repair fails, and the saved row updates on success.

**Ship criteria:** A meeting with a known live-dropped region produces a saved transcript that, after repair, covers the dropped speech; a healthy meeting takes the `.accept` path and finalizes byte-identical to today; repair runs on the background slot and never blocks finalization. REQ-MEET-013 wording narrowed by the coordinator.

### Phase D — Full-fallback tier + crash-recovery integration

| File | Change |
|------|--------|
| `Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingService.swift` | Wire the `.fullReTranscribe` tier: when the planner reports systemic failure / very-low coverage, re-run STT over the whole retained audio on the background slot (optionally length-capped — see open questions). |
| `Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingRecoveryService.swift` | Run the coverage-repair stage on crash-recovered sessions (ADR-019) — they re-enter the same post-stop pipeline, so the repair attaches for free; recovered sessions are the most likely to have lossy live transcripts. |
| `Sources/MacParakeetCore/AppFeatures.swift` *(optional)* | Add a separate confirmed-signature gate for the v2 live mic-recovery restart (REQ-MEET-017 v2) once `mic_stall_detected` field data justifies it. Not implemented in this plan beyond the flag. |

**Tests**
- `Tests/MacParakeetTests/MeetingRecording/MeetingTranscriptCoverageRepairTests.swift` *(extend)* — systemic-failure pattern → `.fullReTranscribe`.
- `Tests/MacParakeetTests/MeetingRecording/MeetingRecordingRecoveryServiceTests.swift` *(extend)* — a recovered session runs the coverage-repair stage and the repaired transcript is saved with the existing `recoveredFromCrash` provenance intact.

**Ship criteria:** Systemic live-chunk failure triggers a full background re-transcription rather than leaving a near-empty transcript; crash-recovered sessions get coverage repair without extra UX.

## Testing matrix

- Iterate with focused tests for the phase. Run the full suite at most once as
  the final gate, per the repository test policy.
- Pure cores (`MeetingMicHealthMonitorTests`, `MeetingTranscriptCoverageRepairTests`) are deterministic, no hardware — these are the bulk of the coverage and must run in normal CI.
- The mic-stall *capture* path (real AVAudioEngine) is hardware-gated and forensic, consistent with `2026-05-dictation-stall-integration-tests.md`'s `MACPARAKEET_HARDWARE_TESTS=1` convention — do not put real-mic tests in the default suite.
- No-LLM / no-VAD-model smoke: with VAD model uncached, the repair stage degrades to `.accept` (no offline pass available) and the meeting still finalizes — verify no regression.
- Mutation check (per the onboarding-watchdog-test plan's habit): break the confirmation gate / break the gap detector and confirm the relevant table test fails.

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Watchdog false-alarms on legitimately one-sided audio | Medium | Low | ~3s system-audio confirmation gate; tune from `mic_stall_detected` field timing before adding recovery |
| Source recovery revives capture after Stop | Low | High | Source ownership, generation fencing, bounded awaited teardown, and Stop-wins tests |
| Repair starves dictation | Low | High | Background slot only (ADR-016); never the reserved dictation slot — asserted in integration test |
| Selective repair corrupts a good transcript | Low | High | Repair only *adds* coverage; original preserved; write-back is in-place and atomic; failure leaves the live transcript untouched |
| Threshold tuning wrong (over/under-repair) | Medium | Medium | Start conservative (favor `.accept`); `meeting_transcript_repair` telemetry on decision mix drives tuning |
| Full re-transcription too slow on long meetings | Low | Medium | Length-cap `.fullReTranscribe` (open question); background slot bounds user impact |
| Future repair telemetry rejected by the website | Low | Medium | Mirror `meeting_transcript_repair` before enabling the repair path; the existing mic-health event is already registered |

## Done criteria

- [x] `MeetingMicHealthMonitor` is pure, table-tested, and passes in the normal suite
- [ ] `MeetingTranscriptCoverageRepair` is pure, table-tested, and passes in the normal suite
- [x] Mic stall (system active) emits one correctly-tagged `mic_stall_detected`; genuine quiet emits nothing
- [x] Recovering or terminal source failures show non-blocking actionable warnings; recording continues when the other source remains viable
- [ ] Selective repair re-transcribes only uncovered gaps on the background slot; healthy meetings stay `.accept` and byte-identical
- [ ] Full-fallback tier handles systemic failure; crash-recovered sessions get coverage repair
- [ ] Original live transcript + retained `.m4a` never destroyed by repair
- [x] Existing mic-health telemetry is mirrored in the website allowlist
- [ ] Future `meeting_transcript_repair` telemetry is mirrored/deployed before that repair path is enabled
- [x] ADR/spec status updated for Phase A; coverage-repair wording remains for
  Phase C
- [x] `swift test` exits 0; docs/spec progress updated (`spec/README.md`, `spec/02-features.md`)
- [ ] Plan archived to `plans/completed/` on completion

## Open questions

- **Confirmation window length** — fixed ~3s, or scaled by how silent the mic is (a totally dead mic could trip faster than a near-silent one)? Settle from Phase A field timing.
- **Coverage threshold + ≥0.8s gap floor** — need replayed field audio / a labeled corpus to tune. Start conservative, loosen on data.
- **Full-file re-transcription budget** — is `.fullReTranscribe` unconditional on very-low coverage, or capped by meeting length to bound background-slot time? Lean capped, telemeter how often the cap binds.
- **Signal-inferred recovery scope** — callback cessation now uses the shared
  source's bounded fresh-engine recovery. Keep amplitude-only inference passive
  unless telemetry and reproducible evidence establish a safe trigger.
- **Physical route matrix** — signed-candidate Bluetooth/AirPods and USB route
  changes remain the release proof for the source-lifecycle implementation.
