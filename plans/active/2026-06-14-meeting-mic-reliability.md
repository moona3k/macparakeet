# Meeting capture reliability — mic-health watchdog + post-stop coverage repair

**Status:** IN PROGRESS — Phase A implemented 2026-06-14 (detection-only mic-health telemetry); warning UI and coverage repair remain unimplemented.
**Date:** 2026-06-14
**ADRs:** ADR-025 (meeting capture reliability), ADR-014 (meeting recording), ADR-015 (concurrent dictation/meeting), ADR-016 (centralized STT runtime + two-slot scheduler), ADR-019 (crash-resilient meeting recording)
**Requirements:** REQ-MEET-017 (mic-health watchdog) — Phase A implemented; REQ-MEET-018 (post-stop coverage-based transcript repair) — proposed
**Sibling work:** `plans/active/2026-05-dictation-stall-integration-tests.md`, `plans/active/2026-06-onboarding-stall-watchdog-test.md` — this is the meeting-side counterpart to the dictation silent-stall hardening; stay consistent, don't duplicate.

## What this plan closes out

ADR-019 made the meeting *bytes* crash-resilient (fragmented MP4 + lock-file recovery), but two silent correctness gaps remain that ADR-025 specs:

1. **A dead mic mid-meeting goes unnoticed.** The microphone tap can deliver zero/near-silent buffers for many seconds (a real ~18s field incident) while system audio is fine — the user loses their own side and finds out only on playback. The dictation side is already hardening this exact failure (PR #210 instrumentation, issue #499 root cause, `2026-05-dictation-stall-integration-tests.md`); the meeting side has the same HAL exposure but **no watchdog**.
2. **Live preview = final, lossy on drop.** The saved meeting transcript is assembled from live-preview chunks; any chunk the live path drops is lost permanently. Nothing re-reads the retained audio to ask "is the transcript actually complete?"

This plan implements ADR-025's two halves — a mic-health watchdog (REQ-MEET-017) and a post-stop coverage-based transcript repair (REQ-MEET-018) — as a **default-on reliability improvement** (optionally behind an `AppFeatures` kill-switch for staged rollout), sequenced so each phase is independently shippable.

## Scope boundaries

### In scope
- Pure `MeetingMicHealthMonitor` (three stall signatures + ~3s system-audio confirmation gate) + table tests
- Wiring liveness signals from `MeetingAudioCaptureService` / `SharedMicrophoneStream` / `SystemAudioStream` into the monitor
- Gentle, non-blocking in-meeting warning on the panel/pill ("This meeting may be missing your side")
- Pure `MeetingTranscriptCoverageRepair` planner (coverage ratio + gap detection → accept / selective / full) + table tests
- Offline `MeetingVADService` pass over retained mic + system `.m4a` in the post-stop path
- Selective re-transcription of uncovered gaps on the **`STTScheduler` background slot**, write-back to the saved `Transcription` row
- Full re-transcription fallback tier for systemic live-chunk failure
- Applying the coverage-repair stage to crash-recovered sessions (ADR-019)
- `mic_stall_detected` + `meeting_transcript_repair` telemetry + website allowlist mirror
- `AppFeatures.meetingCaptureReliabilityEnabled` kill-switch (default-on intent)

### Out of scope
- **Live mic auto-recovery** (HAL probe + engine restart mid-meeting) — REQ-MEET-017 v2, deferred behind a confirmed-in-the-wild signature, exactly as the dictation-stall plan gates its restart. v1 here is detect + warn + instrument.
- Changing per-chunk transcription, the chunker (`SpeechBoundaryMeetingLiveAudioChunker` / `AudioChunker`), or `MeetingTranscriptAssembler` — repair is an additive stage on top (see REQ-MEET-013 reconciliation below).
- Diarization changes; speaker attribution of repaired gaps reuses the existing assembler path.
- Any cross-process / CI hardware-test infrastructure beyond what the dictation-stall plan already establishes.
- Re-tuning the dictation-side watchdog (separate plan).

### Invariants
- **Never lose user data** — repair only *adds* coverage; the original live transcript and the retained mic/system `.m4a` files are preserved exactly as ADR-019 leaves them.
- Dictation continues to work unchanged, concurrently (ADR-015).
- Repair never uses the reserved dictation slot; it is background-class and never starves dictation (ADR-016).
- The watchdog is **detection-only in v1** and must not destabilize the capture graph — its liveness taps are passive observers.
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

### Phase B — In-meeting warning UI

Surface the confirmed `.stallSuspected` event as a gentle, non-blocking warning. Still no recovery.

| File | Change |
|------|--------|
| `Sources/MacParakeetViewModels/MeetingRecordingPanelViewModel.swift` | Add a non-blocking `micHealthWarning` state next to `micLevel`/`systemLevel`, set from the monitor's `.stallSuspected`, cleared on `.recovered`. Never modal, never stops recording. |
| `Sources/MacParakeetViewModels/MeetingRecordingPillViewModel.swift` | Mirror the warning state so the floating pill and the Transcribe tile stay in sync (shared VM pattern). |
| `Sources/MacParakeet/Views/MeetingRecording/` | Render the warning: gentle copy "This meeting may be missing your side", dismissible, non-blocking. Reuse existing panel/pill styling; no new floating surface if an inline banner suffices. |

**Tests**
- `Tests/MacParakeetTests/ViewModels/MeetingRecordingPanelViewModelTests.swift` *(extend)* — `.stallSuspected` sets `micHealthWarning`; `.recovered` clears it; warning never changes recording state.

**Ship criteria:** A confirmed mid-meeting mic stall shows the gentle warning on the panel and pill; recording continues uninterrupted; the warning clears if the mic recovers.

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

- `swift test` baseline before each phase; all green after. Full suite usually ~1–2 min.
- Pure cores (`MeetingMicHealthMonitorTests`, `MeetingTranscriptCoverageRepairTests`) are deterministic, no hardware — these are the bulk of the coverage and must run in normal CI.
- The mic-stall *capture* path (real AVAudioEngine) is hardware-gated and forensic, consistent with `2026-05-dictation-stall-integration-tests.md`'s `MACPARAKEET_HARDWARE_TESTS=1` convention — do not put real-mic tests in the default suite.
- No-LLM / no-VAD-model smoke: with VAD model uncached, the repair stage degrades to `.accept` (no offline pass available) and the meeting still finalizes — verify no regression.
- Mutation check (per the onboarding-watchdog-test plan's habit): break the confirmation gate / break the gap detector and confirm the relevant table test fails.

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Watchdog false-alarms on legitimately one-sided audio | Medium | Low | ~3s system-audio confirmation gate; tune from `mic_stall_detected` field timing before adding recovery |
| Watchdog destabilizes the capture graph | Low | High | Detection-only in v1; liveness taps are passive observers, never touch the engine |
| Repair starves dictation | Low | High | Background slot only (ADR-016); never the reserved dictation slot — asserted in integration test |
| Selective repair corrupts a good transcript | Low | High | Repair only *adds* coverage; original preserved; write-back is in-place and atomic; failure leaves the live transcript untouched |
| Threshold tuning wrong (over/under-repair) | Medium | Medium | Start conservative (favor `.accept`); `meeting_transcript_repair` telemetry on decision mix drives tuning |
| Full re-transcription too slow on long meetings | Low | Medium | Length-cap `.fullReTranscribe` (open question); background slot bounds user impact |
| Website allowlist not deployed before flag-on | Low | Medium | Deploy `telemetry.ts` mirror first; both events; verify before tagging |

## Done criteria

- [ ] `MeetingMicHealthMonitor` + `MeetingTranscriptCoverageRepair` are pure, table-tested, and pass in the normal suite
- [x] Mic stall (system active) emits one correctly-tagged `mic_stall_detected`; genuine quiet emits nothing
- [ ] Confirmed stall shows the gentle non-blocking warning on panel + pill; recording continues
- [ ] Selective repair re-transcribes only uncovered gaps on the background slot; healthy meetings stay `.accept` and byte-identical
- [ ] Full-fallback tier handles systemic failure; crash-recovered sessions get coverage repair
- [ ] Original live transcript + retained `.m4a` never destroyed by repair
- [ ] Both telemetry events mirrored in `macparakeet-website/functions/api/telemetry.ts` and deployed before flag-on
- [x] ADR/spec status updated for Phase A; coverage-repair wording remains for
  Phase C
- [x] `swift test` exits 0; docs/spec progress updated (`spec/README.md`, `spec/02-features.md`)
- [ ] Plan archived to `plans/completed/` on completion

## Open questions

- **Confirmation window length** — fixed ~3s, or scaled by how silent the mic is (a totally dead mic could trip faster than a near-silent one)? Settle from Phase A field timing.
- **Coverage threshold + ≥0.8s gap floor** — need replayed field audio / a labeled corpus to tune. Start conservative, loosen on data.
- **Full-file re-transcription budget** — is `.fullReTranscribe` unconditional on very-low coverage, or capped by meeting length to bound background-slot time? Lean capped, telemeter how often the cap binds.
- **Live mic auto-recovery (v2)** — when the confirmed signature lands, is a single HAL-probe + engine-restart enough (matching the dictation-side self-heal for issue #499), or do meetings need a stream re-alignment step after a mic restart? Defer until Phase A telemetry confirms the signature.
- **Warning placement** — panel only, pill only, or both? Both keep the existing levels surfaces in sync; follow whichever surface the user is on.
