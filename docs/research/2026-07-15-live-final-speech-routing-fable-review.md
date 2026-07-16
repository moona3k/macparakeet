# Fable Review: Live Speech and Final Transcription Routing

> **Date:** 2026-07-15
> **Baseline:** `origin/main` at `9bf4ac5c78023831091187ddd1bd301fb6493988`
> **Review mode:** Claude Fable, read-only adversarial architecture review
> **Implementation plan:**
> [`plans/active/2026-07-15-live-final-speech-routing.md`](../../plans/active/2026-07-15-live-final-speech-routing.md)

## Review Brief

You are the senior architecture reviewer for MacParakeet. Work read-only: do not
edit files, commit, or change repository state. Read `AGENTS.md`, the linked
implementation plan, governing ADRs/specs/contracts, and the actual current
source and tests necessary to verify the proposal. Do not assume the plan's
claims are correct.

The product question is whether speech-engine routing should be modeled as:

1. one engine for dictation and a second for meetings/files/media; or
2. one **live speech** engine for dictation plus meeting live preview, with an
   optional **final transcription** engine for authoritative meeting final STT,
   files, drag/drop, media URLs, podcasts, and retranscription.

The proposed plan chooses option 2, defaults final transcription to the live
engine, exposes the override only in Advanced settings, adds an explicit
meeting-preview capability, captures an immutable per-meeting preview/final
plan, preserves one scheduler/runtime, and does not silently fall back to
Parakeet.

Review it adversarially and answer all of these questions:

1. What is the strongest technical and product argument **for** and **against**
   the live/final seam?
2. Is meeting preview actually semantically closer to dictation, or should a
   meeting intentionally retain one engine across preview and final for
   consistency? Inspect whether preview text feeds the final artifact.
3. Is `MeetingSpeechPlan { preview?, final }` the right core policy interface?
   Which layer should own resolution, capability checks, and lifecycle?
4. Should `supportsMeetingLivePreview` be explicit, and are the proposed
   initial values for Parakeet, Nemotron, Whisper, and Cohere accurate in this
   implementation?
5. Is schema-v3 additive persistence (`speechEngine` remains final plus an
   optional preview engine) preferable to a nested plan? Identify compatibility
   and recovery traps in schema v1/v2/v3.
6. Does pinning engine plus language, but not exact model variant, create a
   correctness/provenance violation that must be fixed in this PR?
7. Is persist-only lazy loading for the optional final engine sound? Identify
   races with engine switching, the session lease, scheduler admission, model
   deletion, meeting stop, file-job snapshots, or recovery.
8. Is the proposed Settings information architecture clear and honest about
   download, loaded/ready state, timestamps, speaker labels, language, and
   Cohere limitations?
9. Which proposed tests are essential, missing, coupled to implementation, or
   testing the wrong seam?
10. Which ADR/spec/contract documents truly govern this change?
11. Identify any unnecessary scope, hidden architectural debt, or smaller
    design that preserves the desired product behavior.
12. Give a decisive verdict: approve, approve with changes, or reject. Then
    list concrete required plan changes in priority order.

Important invariants:

- Meeting final text is authoritative and must be derived from durable audio,
  never promoted from preview text.
- Existing user artifacts and crash recovery remain safe and readable.
- Model downloads stay explicit; a settings selection cannot silently download
  a large model.
- `STTRuntime` remains the sole engine lifecycle owner and `STTScheduler`
  remains the sole admission policy.
- Avoid a broad Settings refactor or exact-variant routing expansion unless
  correctness requires it.

Be specific. Cite file paths and symbols from the current checkout. Separate
confirmed facts from recommendations and call out uncertainty rather than
inventing behavior.

## Fable Recommendation

### Verdict: approve with changes

Fable approved the live-speech/final-transcription seam. It found no
rejection-level issue, but required two proposed components to be removed, one
ordering bug to be corrected, and several failure/test surfaces to be made
explicit before implementation.

The review used the exact `origin/main` baseline above. Fable performed direct
source verification, two focused repository explorations, and two adversarial
design critiques before returning the verdict.

### Confirmed facts

| Claim | Source-backed result |
|---|---|
| Meeting preview feeds final text | False. Authoritative final STT rereads durable mixed audio in `TranscriptionService.swift`; preview remains display-only. |
| Preview eligibility has one policy seam | False. `MeetingRecordingService.Session.supportsLiveChunkTranscription` infers from `providesWordTimestamps`, while `MeetingRecordingFlowCoordinator` separately hard-codes Cohere as unsupported. |
| Proposed initial preview capability values preserve current behavior | Yes. Parakeet, Nemotron, and Whisper currently have word timings and participate in the chunked preview path; Cohere does neither. |
| File/URL jobs snapshot after downloading | False. The engine is already resolved at job entry before URL/podcast download in `TranscriptionService`. |
| A final-engine Settings click should remain lazy | Yes. The current transcription picker already validates download/memory requirements and persists without warming the engine in `EngineSettingsViewModel`. |
| Lock schema v3 is an additive, downgrade-safe change | False. `MeetingRecordingLockFileStore.read()` rejects future schema versions, so the notarized stable build would ignore a v3 development lock in recovery, CLI active-session protection, and retention protection. |
| Existing v1/v2 recovery matches the desired final-route semantics | Yes. Captured v2 `speechEngine` is used for recovery; uncaptured v1 follows the current transcription preference. |
| Exact model variant must be pinned for truthful provenance | No. `STTResult.engineVariant` records the engine's actual result variant. Engine/language pinning can remain the routing contract for this PR. |
| A meeting lease protects a lazily selected final model from deletion | No. The lease blocks engine/variant switching, but does not itself pin a downloaded model cache. |

### Answers to the review questions

1. **Strongest case for live/final:** the roles match the actual latency,
   residency, accuracy, and language contracts; the seam fixes a batch-only
   final engine suppressing an otherwise available preview. **Strongest case
   against:** users may see preview/final divergence. Fable judged attribution
   copy the right mitigation because chunked preview can already differ from
   final text even with one engine.
2. Preview is semantically live speech. It is ephemeral, latency-bound, and is
   never promoted into the saved artifact. Preferring the final engine for
   preview would worsen memory, cold-start behavior, and determinism.
3. Keep `MeetingSpeechPlan { preview?, final }` as a small Core value and static
   resolver. Resolve it in `MeetingRecordingService` at meeting start. The flow
   coordinator should only consume the resolved plan; it must not repeat engine
   policy.
4. Name preview support explicitly, but make
   `supportsMeetingLivePreview` a derived computed property of
   `providesWordTimestamps` in this PR. Preview rendering currently requires
   word timings, so a second stored field would duplicate the same invariant
   without enforcement. Promote it to independent registry data only when a
   real engine makes the two capabilities diverge.
5. Keep `recording.lock` schema v2 and its existing `speechEngine` field, which
   means the engine for authoritative finalization/recovery. Persist optional
   preview provenance only in post-stop `MeetingRecordingMetadata`. A recovered
   crashed meeting having final-only provenance is acceptable because preview
   itself is never recovered.
6. Engine plus language is sufficient for this PR. The actual result variant
   remains honestly recorded by `STTResult`; recovery-time build drift is a
   quality issue rather than a false-provenance issue.
7. Lazy final loading is sound with three qualifications: keep the meeting
   lease even when preview is unavailable; acquire the lease before resolving
   capabilities; and surface a deleted-model/cold-load failure as failed
   finalization that can be retried or retranscribed.
8. The proposed Settings hierarchy is clear. It must distinguish downloaded
   from loaded/ready, retain Cohere's timing/speaker limitations, and document
   that key presence enables the override even when its value currently equals
   the live engine.
9. Preference, plan-resolution, meeting-capture, and final-route tests are
   essential. Persistence tests should cover additive metadata plus unchanged
   v1/v2 behavior, not schema v3. Add missing-model recovery and cold-load
   failure coverage. Warm-up assertions belong at the meeting-session/scheduler
   fake seam, not runtime internals.
10. Governing material is ADR-014 section 9, ADR-016,
    `spec/06-stt-engine.md`, `spec/02-features.md`, the STT README, the meeting
    recovery/retention contract, and the meeting-artifacts contract if metadata
    gains preview provenance. ADR-020 does not change because the lock does not.
11. Remove schema v3, nested lock-plan persistence, a stored duplicate
    capability, exact-variant expansion, and any prepare-now action. Require
    concise meeting attribution when the two routes differ.
12. **Approve with changes.** The corrected design is smaller than the initial
    proposal while preserving its product behavior.

### Required changes, in priority order

1. Keep lock schema v2 unchanged; add preview provenance only to archived
   metadata.
2. Use a derived preview-support property and replace the coordinator's Cohere
   special case with the resolved plan.
3. Acquire and retain the live meeting lease before resolving the plan,
   including when `preview == nil`.
4. Define and test deleted/cold final-model failure and retry behavior.
5. Require route attribution when preview and final engine/language differ.
6. Correct the test list and add forward-compatible metadata, missing-model,
   and cold-load-failure coverage.
7. Amend ADR-014 and the recovery/artifact contracts without implying a lock
   schema change.
8. Keep warm-up tests at the service/scheduler boundary.

## Reconciliation

All required changes were accepted:

- The lock-file schema bump and preview field were removed. This avoids making
  in-progress meetings invisible to the current stable build after a downgrade.
- Preview provenance is additive archived metadata only; `speechEngine` remains
  the captured final/recovery route everywhere it already exists.
- `supportsMeetingLivePreview` is initially a semantic computed alias for the
  real current rendering prerequisite, word timestamps. The resolver is still
  the only workflow-policy seam.
- Meeting start now acquires an unconditional live-engine lease before plan
  resolution and warming. The plan uses the lease-captured selection and
  capabilities, preventing a switch race.
- Missing/cold final-model failure, equal-valued explicit overrides, required
  route attribution, and the corrected focused tests/contracts were added to
  the executor-ready plan.
- Exact-variant routing, prepare-now UI, nested persistence, and broad Settings
  decomposition remain explicit non-goals.

## Implementation Outcome

The reconciled recommendation is implemented on
`codex/live-final-speech-routing` without adding a runtime, scheduler lane,
fallback framework, or persistence version.

- `SpeechEnginePreference` now exposes Live Speech and resolved Final
  Transcription semantics while preserving the existing defaults keys. Key
  presence is the explicit-override signal, including when both values match.
- `MeetingSpeechPlan.resolve` is the single policy seam. Preview follows the
  leased live selection only when the capability registry reports word timings;
  final is independently captured and never falls back.
- `MeetingRecordingService` leases Live Speech before reading the final route,
  routes/warm-ups only the optional preview selection, stores final in the
  unchanged schema-v2 lock, and archives optional preview provenance after stop.
- `TranscriptionService` continues to derive the authoritative meeting text
  from durable source audio and the captured final route. A missing captured
  model fails without fallback, persists an error row, and leaves meeting audio
  intact for the existing retry/retranscription path.
- Settings presents one primary Live Speech choice. The second picker appears
  only after enabling `Advanced > Use a different engine for final transcripts`
  and remains persist-only/lazy. Model deletion rechecks scheduler availability
  so an active meeting or transcription cannot lose a captured model.
- The live meeting panel names preview and final routes when they differ and
  uses generic final-transcription copy when preview is unsupported, avoiding a
  false claim that the live engine will also produce the final transcript.

The governing ADRs, STT/audio/UI specs, error handling, and recovery/artifact
contracts were amended in the same change. ADR-020 and the lock schema were not
changed.

## Committed-Diff Review

Fable performed a second read-only review of the committed implementation
against current `origin/main`. Its verdict was **changes required** for one
migration issue; it also identified one cheap dead API and two contained
lower-priority risks.

### Findings and disposition

1. **Required — repair equal keys materialized by PR #783.** Accepted. That
   contribution wrote the inherited transcription value merely by opening
   Settings, but this design makes key presence intentional. Startup now runs a
   one-shot, flag-guarded migration that removes only an equal-valued legacy
   key, preserves a different route, and never removes a deliberate
   equal-valued override created after migration. Focused tests cover all three
   outcomes.
2. **Dead routed-session lease API.** Accepted. Meeting capture now always
   leases Live Speech, leaving `SpeechEngineRoutedSessionManaging` and the
   scheduler overload without a production caller. They were removed rather
   than retained as speculative surface; the standard session-lease tests keep
   the switch-race invariant covered.
3. **Model deletion can race meeting start after the availability await.**
   Accepted as a contained residual risk. Closing it atomically would require a
   scheduler-owned destructive model-operation admission API. The current
   change is safer than `main`, UI deletion rechecks availability, and the
   remaining race fails finalization durably without fallback or artifact loss.
   Adding a new scheduler transaction solely for this edge case would exceed
   the requested essential scope.
4. **Optional protocol default could hide a missing meeting plan.** Accepted.
   The default implementation was removed, so every conformer must make plan
   availability explicit. The real service still returns `nil` only outside an
   active recording.
5. **Minor UI error placement and unreachable nil-provider state.** Deferred.
   A deletion refusal currently uses the existing speech-engine error surface,
   and production always wires the live-selection provider. Neither justifies
   another state channel or fallback framework in this change.

After these dispositions, the required migration, lease lifecycle, immutable
plan, schema-v2 downgrade safety, durable no-fallback failure behavior, and
live/final UI attribution are all covered by focused tests.

## Final Verification

After resolving the committed-diff findings, the final combined preference,
scheduler, and meeting-service gate passed 174 tests with zero failures. The
transcription-view-model suite passed 122 tests, the broader focused routing
matrix passed 356 tests with one skip and zero failures, and the
single final full `swift test` run exited successfully. `git diff --check` also
passed.

The local `no-mistakes` and Greptile CLIs were unavailable, so hosted CI and
review on the exact PR head are the remaining independent merge-readiness
checks.
