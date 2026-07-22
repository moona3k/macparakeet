# ADR-025: Meeting capture reliability — mic-health watchdog + post-stop coverage repair

> Status: **PARTIAL IMPLEMENTATION** — mic-health detection, source-owned microphone callback-stall recovery, typed system-source recovery, actionable-only warning UI, and finalized writer-frame capture reporting are implemented. The separately proposed VAD transcript-gap repair in §2 remains unimplemented.
> Date: 2026-06-14
> Related: ADR-014 (meeting recording via ScreenCaptureKit system audio), ADR-015 (concurrent dictation/meeting), ADR-016 (centralized STT runtime + two-slot scheduler), ADR-019 (crash-resilient meeting recording)
> Requirements: REQ-MEET-017 Phase A and direct callback-liveness recovery implemented; REQ-MEET-018 proposed

## Context

A meeting recording captures two independent audio streams: the
microphone ("You", via `SharedMicrophoneStream` / AVAudioEngine) and
system audio ("Others", via `SystemAudioStream` / ScreenCaptureKit).
ADR-019 made the *bytes* crash-resilient — each source is a fragmented
MP4, playable up to the last 1-second fragment even after a kill-9. But
two correctness gaps remain that ADR-019 does not touch:

1. **The mic can go silently dead mid-meeting and nothing notices.** A
   real field incident: the microphone input tap delivered **zero audio
   buffers for ~18 seconds** of held capture while the rest of the
   system looked fine — the user lost their own side of the meeting and
   had no idea until they played it back. This is the same class of
   silent stall the dictation side is already hardening against (see
   `journal/2026-05-03-dictation-silent-stall.md`, PR #210's diagnostic
   package, issue #499's confirmed HAL-configuration-change root cause,
   and `plans/active/2026-05-dictation-stall-integration-tests.md`). The
   meeting path has the *same* `AVAudioEngine`/HAL exposure but **no
   watchdog** — there is currently nothing that observes "the mic has
   stopped delivering while the meeting is still live."

2. **The live-preview transcript is effectively the final transcript.**
   Meeting transcription is built from live-preview chunks
   (`SpeechBoundaryMeetingLiveAudioChunker` / the fixed 5s/1s
   `AudioChunker`, per REQ-MEET-013) assembled by
   `MeetingTranscriptAssembler`. If the live path drops a chunk — a
   chunker hiccup, a momentary engine stall, a dropped buffer window —
   that speech is **lost permanently**. There is no post-stop pass that
   asks "does the saved transcript actually cover all the speech in the
   retained audio?" The retained selected-source `.m4a` files hold the truth,
   but nothing re-reads them for completeness.

This ADR hardens both. It is framed as a **reliability/correctness
improvement that ships default-on**, not a user-facing feature toggle.
The mic watchdog's only user-visible surface is a gentle in-meeting
warning plus telemetry — never a blocking error. For staged rollout it
may sit behind an `AppFeatures` kill-switch flag, but the intended
end-state is "always on, invisible until something is wrong."

Both halves share one design principle: **the two streams cross-check
each other, and the retained audio is the ground truth.** During
capture, system audio proves the mic *should* be receiving signal.
After stop, an offline VAD pass over the retained audio proves what
speech the live transcript *should* have covered.

## Decision

### 2026-07-22 field-evidence amendment: microphone callback liveness

Issue #820's opt-in diagnostic captured the exact source failure that the
original recovery deferral was waiting for: after Bluetooth/default-input route
churn, `AVAudioEngine` continued to report itself running while the input tap's
callback counter froze after two or three buffers for the rest of capture.
Issue #846 reports a compatible v0.7.3 symptom, but has no diagnostic log, so it
is corroborating user evidence rather than proof of that session's route.

Raw callback cessation is now a direct source-lifecycle failure:

- After the tap has delivered its first real buffer, a five-second gap with no
  callbacks triggers recovery even if `AVAudioEngine.isRunning` remains true.
  This is not a signal-amplitude heuristic: a quiet source continues to deliver
  buffers and remains healthy.
- Callback stalls and physically stopped configuration-change graphs converge
  on the same bounded fresh-engine recovery. Each attempt resolves the current
  route and format, and no replacement succeeds until it delivers a real
  buffer. Explicit Stop invalidates the episode and every queued retry.
- The recovery belongs to the process-wide `SharedMicrophoneStream` platform,
  so dictation and meeting capture share one owner instead of adding a second
  meeting-consumer recovery loop.

Amplitude- or cross-source-signal-inferred restarts remain deferred. The
meeting health monitor continues to warn and instrument those signatures
without changing the capture graph.

### 2026-07-20 field-evidence amendment: final recording truth

Issues #851–#853 supplied a concrete failure that the original transcript-VAD
proposal did not cover: a 39:15 meeting finalized as `completed` even though
both selected source files contained only about 68 seconds of frames. The
writer already knew the exact frame totals, but finalization logged them and
then persisted pause-adjusted wall-clock time as the recording duration. Any
small decodable source file therefore looked like a full successful meeting.

Finalized recording coverage is now a separate, implemented correctness layer:

- Stop snapshots capture end before asynchronous shutdown, mixing, and artifact
  I/O, then compares pause-adjusted elapsed time with exact selected-source
  writer frames.
- A pure `MeetingCaptureReport` records `healthy`/`partial` quality, playable
  captured duration, elapsed duration, per-source written duration/coverage and
  terminal status. Classification uses a 90% coverage threshold so short
  meetings cannot lose most of their media under a fixed-duration grace;
  explicit interruption/failure is always partial. If two healthy source files
  cannot be combined, the report records which source became canonical playback
  and marks that playback as partial without misclassifying either source
  capture.
- Writer finalization is a correctness boundary: a source that accepted real
  frames but does not reach AVAssetWriter's completed state aborts settlement
  and leaves the lock and source artifacts available for recovery. Pre-finish
  frame counters are never promoted as healthy durable media after an encode or
  storage failure.
- `Transcription.durationMs` is playable captured duration. Elapsed session time
  remains in the optional report, persisted in the canonical DB row and
  additive meeting artifact metadata. Legacy absence means unknown, not healthy.
- Source files preserve genuine host-time recovery gaps as silence while
  removing intentional pauses from that timeline. Completed pause ranges are
  retained for the session so delayed buffers remain exactly classifiable. If
  capture begins with untimed buffers, the writer's
  effective file origin accounts for that leading audio exactly once when
  deriving cross-source alignment. Cross-source offsets require complete writer
  timeline origins; incomplete timing remains zero/unknown rather than falling
  back to raw host deltas that still contain intentional pauses.
- Capture quality is orthogonal to transcription lifecycle: successfully
  processed partial audio remains `completed` and receives a non-modal saved
  “Partial audio” explanation rather than a misleading retranscription action.

This frame-derived report answers **whether audio reached disk for the expected
recording interval**. It does not inspect speech or transcript completeness and
must not be conflated with §2's proposed offline-VAD transcript-gap repair.
Selective/full VAD-driven transcript repair remains unimplemented.

### 1. Mic-health watchdog: system audio is the liveness oracle (REQ-MEET-017)

During an active meeting, **the system-audio stream is the ground
truth that capture is alive.** ScreenCaptureKit's system-audio tap and
the mic's AVAudioEngine tap fail independently and for different
reasons; when one is healthy we can use it to judge the other. If
system audio is actively delivering non-silent buffers but the mic path
is not, the mic has stalled — and unlike pure silence detection, this
distinguishes "the room is quiet" from "the mic is dead."

A pure `MeetingMicHealthMonitor` consumes timestamped liveness signals
from both streams and detects three stall signatures:

- **(a) Mic callbacks entirely missing** while system audio is active —
  the mic tap has stopped firing altogether (the ~18s field incident).
- **(b) Mic callbacks arriving but all-zero / near-silent** while system
  audio is active — the tap fires but the graph is dead (a config-change
  victim per issue #499: `AVAudioEngine.isRunning` may read `true` over a
  dead graph).
- **(c) A stalled mic-callback gap** — more than ~1 s since the last mic
  buffer while system audio continues to deliver.

**Confirmation window before tripping.** None of these trips on its own.
The monitor requires a **confirmation window of ~3 s of continuous
system-audio activity** (non-silent buffers) proving the mic genuinely
*should* be receiving signal, before declaring a stall. This is the
guard against false alarms during legitimately one-sided audio — a
presenter on mute listening to a long monologue, a quiet stretch where
only "Others" are talking. System audio being active is the precondition
that makes "mic is silent" *meaningful*.

**On trip (v1 = detect + warn + instrument):**

- Surface a **gentle, non-blocking in-meeting warning** on the recording
  panel/pill: *"This meeting may be missing your side."* It does not
  stop the recording, does not modal-block, and does not throw — the
  meeting keeps capturing whatever it can.
- Emit a privacy-safe `mic_stall_detected` telemetry event tagged with
  the signature (a/b/c) and coarse timing. No audio, no transcript.

**Source-callback recovery is implemented; signal-inferred recovery remains
deferred.** The #820 diagnostic confirmed that raw tap callbacks can stop while
`AVAudioEngine.isRunning` stays true, so the shared microphone platform now
treats a five-second post-start callback gap as a direct source-lifecycle
failure. This decision uses callback delivery only; it does not promote
amplitude, transcript, or cross-source inference into a restart trigger.

`MicrophoneEnginePlatform` owns bounded recovery for both that callback stall
and an `AVAudioEngineConfigurationChange` that physically stops the engine.
Each attempt rebuilds against the current route and format, and recovery is not
successful until the replacement delivers a real buffer. Configuration-change
notifications received during that readiness wait remain part of the same
episode and consume its existing bounded retry budget rather than silently
starting a fresh budget. Explicit Stop still cancels the episode and prevents a
queued attempt from reviving capture. Meeting microphone Stop is itself an
awaited lifecycle boundary: callback retirement and shared-stream
unsubscription settle before a replacement meeting session can claim capture
or its event stream.

### 1a. Typed system-audio stalls recover at the source boundary

The deferred mic-health restart above applies to inferred mic stalls. A
`SystemAudioStream` first-buffer timeout or heartbeat gap is different: it is a
direct typed failure of the ScreenCaptureKit source. That source now recovers
within `MeetingAudioCaptureService`, the layer that owns both its factory and
its lifecycle:

- Emit `.sourceRecoveryStarted(source: .system, error:)` once, retire the
  stalled capture generation, and await its bounded teardown. The microphone
  remains live and is never restarted as part of system recovery.
- Retry with a **fresh** `SystemAudioStream` on every attempt. Six attempts use
  23 seconds of cumulative scheduled backoff (`0, 1, 2, 4, 8, 8` seconds);
  bounded stream lifecycle and first-buffer readiness waits are additional.
  This extends beyond the approximately 17-second route-settlement interval
  observed in the field without creating an unbounded restart loop.
- Treat an attempt as successful only when the replacement delivers its first
  valid buffer. Deliver that buffer, then emit
  `.sourceRecovered(source: .system)`. A successful `start()` without audio is
  not recovery. A failure racing immediately behind that first buffer is
  classified before promotion: recoverable failure consumes another bounded
  attempt; nonrecoverable failure terminates after teardown.
- Map an unexpected `SCStreamDelegate.didStopWithError` callback to the same
  typed recovery contract. ScreenCaptureKit's documented `userStopped` code is
  intentional and nonrecoverable, so it retains terminal semantics rather than
  entering a restart loop. A delegate failure racing the initial async start is
  retained through an atomic start-to-running handoff; it fails and tears down
  that start attempt rather than promoting a dead stream.
- Coalesce duplicate stall callbacks. Generation checks reject late buffers or
  errors from retired streams. Explicit Stop cancels and awaits the active
  recovery task; Stop always wins and no queued retry may revive capture.
- For nonrecoverable source failures, invalidate the callback generation first,
  await the failed stream's bounded Stop, and only then publish the terminal
  event. This prevents a dead stream from continuing to feed buffers while the
  meeting records microphone-only.
- Emit terminal `.sourceInterrupted(source: .system, error:)` (or `.error` for
  system-only capture) only after the bounded attempts are exhausted.

This is deliberately source-specific lifecycle repair, not a second generic
watchdog or string-matched error path. Other runtime failures keep their
existing terminal semantics unless they gain an equally concrete typed
recovery contract.

### 2. Post-stop coverage-based transcript repair (REQ-MEET-018)

After the user stops (`MeetingRecordingService.stopRecording() async
throws -> MeetingRecordingOutput`), and after the normal finalize pass
produces the saved transcript, run a **completeness repair stage**:

1. **Offline VAD pass** over the full retained selected-source `.m4a`
   files (mic, system, or both depending on source mode; reusing the
   `MeetingVADService` / Silero machinery already in the codebase, run offline
   rather than streaming), producing the set of speech regions actually present
   in the audio.
2. **Compute the speech-coverage ratio** — how much VAD-detected speech
   the live-captured transcript segments (from
   `MeetingTranscriptAssembler`) actually cover.
3. **Identify uncovered regions** — VAD speech regions ≥ ~0.8 s of
   detected speech that the live transcript covers below a threshold.
4. **Apply a decision ladder:**
   - **Accept** — coverage is high; the live transcript stands as final,
     no STT re-run. (The common case; matches today's behavior.)
   - **Selective repair** — coverage has gaps; re-transcribe *only* the
     specific uncovered regions and splice the results back into the
     saved transcript.
   - **Full re-transcription fallback** — coverage is very low or the
     pattern indicates systemic live-chunk failure (e.g. a long mid-
     meeting blackout); re-run STT over the whole retained audio.

This converts "live preview = final, lossy on drop" into "live preview +
guaranteed-complete final."

**Scheduling (ADR-016).** Every STT re-run in the repair stage MUST go
through the `STTScheduler` on the **shared background slot** — never the
reserved dictation slot. Repair is a background meeting-finalize-class
job; it must never starve or preempt live dictation (ADR-015 keeps
dictation working concurrently throughout). The repair runs
**asynchronously**: it must not block the finalization UI longer than
necessary. The meeting finalizes and lands in the library on the live
transcript as it does today; the repaired transcript is written back
when the repair completes, and the saved row updates in place.

### 3. Reconciliation with REQ-MEET-013

REQ-MEET-013 currently states that meeting live-preview chunking may use
VAD boundaries "while … **final post-stop transcription remains
unchanged**." This ADR must not be read as contradicting that. The
reconciliation:

- REQ-MEET-013's "final post-stop transcription remains unchanged" means
  **the way an individual chunk is transcribed is identical whether or
  not VAD-guided live chunking is on.** This ADR does not change that.
  It does not alter per-chunk STT, the chunker, or the assembler.
- This ADR **adds a new completeness-repair *stage*** that runs *on top
  of* the existing per-chunk transcription. It re-runs STT **only for
  speech the live path missed** — gaps, not chunks that already
  succeeded. For a healthy meeting (coverage high → Accept), the repair
  stage is a no-op and the final transcript is byte-identical to today's.
- So the precise updated framing: *the per-chunk transcription is
  unchanged; a coverage-repair stage may additionally re-transcribe
  speech regions the live path failed to cover.* The old `REQ-MEET-*`
  references are historical anchors only; current wording belongs in this
  ADR and the narrative specs.

### 4. Crash-recovery path benefits from the same repair (ADR-019)

ADR-019's recovery flow re-runs the standard post-stop pipeline on a
crash-recovered session's retained audio. Because the coverage-repair
stage attaches to that same post-stop pipeline, recovered sessions get
it for free in Phase D — and they are exactly the sessions most likely
to have lossy/partial live transcripts (the live preview may have been
cut off at the crash). Recovery + coverage repair compound cleanly.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                     MacParakeetCore (new, pure)                    │
│                                                                    │
│  MeetingMicHealthMonitor  (pure; state passed in)                  │
│    ├── ingest(micSignal, systemSignal, now) -> [HealthEvent]       │
│    ├── signatures: .micMissing / .micSilent / .micGap              │
│    ├── confirmation window (~3s system-audio activity) gate        │
│    └── HealthEvent: .stallSuspected(signature) / .recovered        │
│                                                                    │
│  MeetingTranscriptCoverageRepair  (pure planner)                   │
│    ├── plan(liveSegments, offlineVADSegments) -> RepairPlan        │
│    ├── RepairPlan: .accept                                         │
│    │              / .selective(gaps: [SpeechRegion])               │
│    │              / .fullReTranscribe                              │
│    └── coverageRatio + gap detection (≥0.8s, < threshold)          │
└──────────────────────────────────────────────────────────────────┘
                          │  (deterministic, table-tested)
                          ▼
┌──────────────────────────────────────────────────────────────────┐
│              MacParakeetCore (thin service layer)                  │
│                                                                    │
│  MeetingAudioCaptureService / SharedMicrophoneStream /             │
│  SystemAudioStream  → feed liveness signals to the monitor         │
│                                                                    │
│  MeetingRecordingService.stopRecording → after finalize, run       │
│    coverage repair: offline MeetingVADService pass →               │
│    MeetingTranscriptCoverageRepair.plan → for non-.accept plans,   │
│    enqueue selective/full STT on STTScheduler's BACKGROUND slot →  │
│    write the repaired transcript back to the saved row             │
└──────────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────────────┐
│                    MacParakeet (app layer)                         │
│                                                                    │
│  MeetingRecordingPanelViewModel / PillViewModel                    │
│    └── micHealthWarning surface (gentle, non-blocking)             │
└──────────────────────────────────────────────────────────────────┘
```

**Purity boundary.** The deterministic decision logic —
`MeetingMicHealthMonitor`'s signature/confirmation math and
`MeetingTranscriptCoverageRepair`'s coverage/gap planning — is **pure
and unit-tested with table tests**. State is passed in; no clocks, no
AVAudioEngine, no CoreAudio, no STT calls inside the pure types. The
thin service layer owns the AVAudioEngine/ScreenCaptureKit liveness taps
and the actual STT/VAD invocations.

## Rationale

### Why use system audio as the liveness oracle for signal stalls?

A bare "no usable mic signal for N seconds = stall" timeout cannot tell a dead
mic from a genuinely quiet moment, so it either false-alarms during
silence or sets N so high it misses real stalls (the field incident was
~18 s). Cross-checking against system audio resolves the ambiguity:
"others are clearly talking, the room is not silent, yet your mic is
delivering nothing" is a high-confidence signal that fixed timeouts
can't match. It also costs nothing — both buffer streams already flow
through `MeetingAudioCaptureService`.

Raw callback delivery is a separate liveness fact: quiet sources still deliver
PCM buffers. Meeting health therefore warns when a selected source delivers no
first buffer for 12 active seconds or stops delivering buffers for 5 active
seconds. Paused time does not count, interruption/recovery states take
precedence, and a fresh buffer clears the warning. That meeting-health timeout
only changes warning state; the shared microphone platform independently owns
the confirmed source-level callback recovery described above.

### Why does callback liveness recover while signal inference stays passive?

The original detection-first gate remains the right discipline: a watchdog
that acts on an unproven signal can destabilize healthy capture. Issue #820 now
meets that gate for raw callback cessation without relying on amplitude or
system-audio activity. Quiet microphones still produce callbacks, so the
source-level fact is unambiguous. Amplitude and cross-source health remain
passive until their own field evidence justifies recovery.

### Why coverage repair instead of always re-transcribing the whole file on stop?

Always re-running full-file STT on stop would be the simplest "complete"
guarantee, but it doubles STT cost for every meeting when the live
transcript is already complete (the common case), and adds stop-time
latency to a 40-minute recording for no gain. Coverage-driven selective
repair pays STT cost **only for the speech that's actually missing**,
and reserves the full re-run for the rare systemic-failure case. The VAD
pass is cheap relative to STT; the coverage ratio is what makes the
re-run *targeted*.

### Why keep the pure planner separate from the service?

The decision logic — "is this a stall?", "which regions are uncovered?",
"accept / selective / full?" — is exactly the part that's easy to get
wrong and easy to regress, and it's deterministic given its inputs.
Pulling it into pure types with table tests means the threshold tuning
(confirmation window, coverage threshold, ≥0.8s gap floor) is verifiable
without a mic, a meeting, or an STT model. The audio/STT plumbing that
*can't* be unit-tested stays thin.

## Consequences

### Positive

- The two highest-severity silent meeting-capture failures — a dead mic
  nobody noticed, and live-dropped speech lost forever — both get a net.
- Default-on reliability; no new user decision, no toggle to discover.
- Repair only **adds** coverage. The original live transcript and the
  retained source audio are never destroyed (see Invariants).
- Crash-recovered sessions (ADR-019) inherit coverage repair for free.
- Pure decision cores are table-testable; threshold tuning is auditable.
- Reuses existing machinery (`MeetingVADService`, `STTScheduler`,
  `MeetingTranscriptAssembler`) rather than inventing parallel systems.

### Negative

- **New stop-time work.** Even when async, an offline VAD pass + possible
  selective STT adds background load after stop. Mitigated by running on
  the background slot and updating the saved row in place.
- **Threshold tuning is empirical.** The confirmation window (~3 s),
  coverage threshold, and ≥0.8 s gap floor are first guesses that will
  need field telemetry to settle — same shape of risk as the
  dictation-stall watchdog timing.
- **Another floating-surface warning** to maintain on the meeting panel/
  pill alongside the existing levels/state surfaces.
- **Recovery must not confuse silence with source death.** The meeting health
  monitor's signal-level checks remain detection-only. The source-level
  callback monitor acts only after callbacks have begun and then cease for five
  seconds.

### Invariants (must hold)

- **Never lose user data.** Repair only *adds* coverage; the original
  live transcript and the retained mic/system `.m4a` files are preserved
  exactly as ADR-019 leaves them.
- **Concurrent dictation is unaffected** (ADR-015). The watchdog observes;
  the repair runs on the background slot.
- **Repair never starves dictation** (ADR-016). The reserved dictation
  slot is never used by repair; repair is background-class.
- **Signal-inferred health remains detection-first.** Callback-stall recovery is
  route-agnostic, bounded, requires a real replacement buffer, and must remain
  cancellable by Stop.
- **Crash recovery still works** (ADR-019) and ideally benefits from the
  same coverage repair on recovered audio.

## Implementation Direction

### Core types (MacParakeetCore)

- `MeetingMicHealthMonitor` — pure. `ingest(micSignal:systemSignal:now:)
  -> [HealthEvent]`; holds no clock, takes `now` in. Signatures
  `.micMissing` / `.micSilent` / `.micGap`; ~3 s system-audio
  confirmation gate; emits `.stallSuspected(signature:)` and a
  `.recovered` event when the mic resumes.
- `MeetingTranscriptCoverageRepair` — pure planner.
  `plan(liveSegments:offlineVADSegments:) -> RepairPlan` where
  `RepairPlan` is `.accept` / `.selective(gaps: [SpeechRegion])` /
  `.fullReTranscribe`. Coverage-ratio math + ≥0.8 s gap detection live
  here; no STT, no audio I/O.
- New `Sources/MacParakeetCore/Audio/MeetingMicHealthMonitor.swift` and
  `Sources/MacParakeetCore/Services/MeetingRecording/MeetingTranscriptCoverageRepair.swift`.

### Service layer (MacParakeetCore)

- `MicrophoneEnginePlatform` tracks callback liveness after the first input
  buffer and converges confirmed stalls on its bounded fresh-engine recovery.
  It owns the clock/timer, route re-resolution, replacement-buffer gate, and
  Stop cancellation once for every shared-stream consumer.
- `MeetingAudioCaptureService` (`Sources/MacParakeetCore/Audio/`) feeds
  per-buffer liveness signals (arrival timestamp + non-silent flag for
  mic, activity flag for system) into `MeetingMicHealthMonitor`. The
  existing `MeetingAudioCaptureEvent` stream (`.microphoneBuffer` /
  system) is the natural source; `SystemAudioStream` activity is the
  oracle.
- `MeetingRecordingService.stopRecording()` — after the existing
  finalize produces the saved transcript, kick off the coverage-repair
  stage: offline `MeetingVADService` pass over the retained `.m4a`
  files → `MeetingTranscriptCoverageRepair.plan(...)` → for non-`.accept`
  plans enqueue selective/full STT on `STTScheduler`'s background slot →
  write the repaired transcript back to the `Transcription` row.
- Repair attaches to the same post-stop pipeline ADR-019's recovery
  flow re-runs (`MeetingRecordingRecoveryService` /
  `MeetingTranscriptFinalizer`), so recovered sessions get it in Phase D.

### App / ViewModels

- `MeetingRecordingPanelViewModel` / `MeetingRecordingPillViewModel`
  (`Sources/MacParakeetViewModels/`) — add a non-blocking
  `micHealthWarning` surface next to the existing `micLevel` /
  `systemLevel`. Gentle copy, dismissible, never modal.

### Feature gate (staged rollout)

- Add a single `AppFeatures.meetingCaptureReliabilityEnabled` kill-switch
  (default-on intent) in `Sources/MacParakeetCore/AppFeatures.swift`,
  following the existing flag-doc style. When off, the watchdog does not
  observe and the repair stage is skipped (the meeting finalizes exactly
  as today). The pure types and tests stay intact either way.

## Telemetry

Propose privacy-safe events — **no audio, no transcript content**:

- `mic_stall_detected` — props: `signature` (`mic_missing` /
  `mic_silent` / `mic_gap`), coarse `elapsed_ms` since meeting start.
  Fired once per confirmed stall trip.
- `meeting_transcript_repair` — props: `decision` (`accept` /
  `selective` / `full`), `gap_count`. Fired once per finalized meeting
  after the repair stage resolves.

Add the new `TelemetryEventName` cases in
`Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift`.

> **Two-repo reminder.** Each new `TelemetryEventName` case MUST also be
> added to `ALLOWED_EVENTS` in
> `macparakeet-website/functions/api/telemetry.ts` **before** a
> flag-on build ships. The telemetry Worker rejects the *entire batch*
> if any event name is unknown, silently dropping valid co-batched
> events. Deploy the allowlist change first.

## Phased Rollout

Each phase is independently shippable and additive. Earlier phases
deliver value without later ones.

1. **Phase A — Mic-health detection core (implemented 2026-06-14).** Pure
   `MeetingMicHealthMonitor` with the three signatures + ~3 s
   confirmation gate, table tests, and the `MeetingAudioCaptureService`
   wiring that feeds liveness signals. Emits `mic_stall_detected`
   telemetry. Amplitude- and cross-source-signal-inferred mic restart remains
   deliberately absent until field evidence can distinguish a dead graph from
   legitimate silence.
2. **Phase B — Direct lifecycle recovery + actionable warnings (implemented
   2026-07-20; extended 2026-07-22).** AVAudioEngine configuration-change
   notifications and confirmed post-start callback stalls rebuild the mic on a
   fresh route/format with bounded retries; typed ScreenCaptureKit stalls and
   unexpected stops replace the system stream similarly. Recovery succeeds
   only after a real replacement buffer. Recovering and terminal source states
   surface gentle, non-blocking warnings even while routine health decoration
   remains flag-hidden. Amplitude-inferred health remains detection-only.
3. **Phase C — Coverage-based selective repair.** Pure
   `MeetingTranscriptCoverageRepair` planner + table tests; offline
   `MeetingVADService` wiring in the post-stop path; selective re-
   transcription of uncovered gaps on the `STTScheduler` background slot;
   write-back to the saved row; `meeting_transcript_repair` telemetry.
   Reconcile the old REQ-MEET-013 framing in this ADR and the narrative
   specs; the legacy requirements index is archived and no longer updated.
4. **Phase D — Full-fallback tier + crash-recovery integration.** Add the
   `.fullReTranscribe` tier for systemic-failure coverage, and apply the
   coverage-repair stage to crash-recovered sessions (ADR-019). Optional:
   gate amplitude- or cross-source-signal-inferred mic recovery behind a
   confirmed-signature flag once `mic_stall_detected` data justifies it.

## Open Questions

- **Confirmation window length.** Is ~3 s of system-audio activity the
  right gate, or should it scale with how silent the mic is (a totally
  dead mic could trip faster than a near-silent one)? Settle from
  `mic_stall_detected` field timing before tuning.
- **Coverage threshold + gap floor.** The ~0.8 s gap floor and the
  per-region coverage threshold need a labeled corpus or replayed field
  audio to tune. Start conservative (favor Accept) to avoid spurious
  re-transcription, loosen on data.
- **Where does the warning live?** Panel only, pill only, or both?
  Both keep the existing `micLevel`/`systemLevel` surfaces in sync; the
  warning should follow whichever surface the user is looking at.
- **Signal-inferred recovery scope.** Raw callback cessation already uses the
  shared source's bounded fresh-engine recovery. If amplitude-only evidence
  later justifies recovery, should it use that same path or require additional
  meeting-stream re-alignment? Defer until telemetry confirms the signature.
- **Full-file re-transcription budget.** Should `.fullReTranscribe` be
  unconditional on very-low coverage, or capped by meeting length to
  bound background-slot time? Lean capped, with telemetry on how often
  the cap binds.
