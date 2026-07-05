# Meeting Stop + Back-To-Back Readiness Audit - 2026-07-05

> Status: release-readiness audit note. The behavioral audit was verified
> against clean `origin/main` checkout
> `/Users/dmoon/code/macparakeet-worktrees/latest-main-run` at `681e3610e`
> (`main...origin/main`). The `meeting_stop_stage` diagnostics described below
> were then added in the active working checkout so release QA can diagnose the
> stop-to-check gate before shipment. The active checkout had unrelated dirty
> files before this note was created.

## Questions

- What do the post-stop meeting pill animations mean?
- Can the user start a new meeting while the previous meeting is saving,
  transcribing, running AEC, or running diarization?
- What happens when file/media/YouTube transcription overlaps with meeting
  recording?
- Is the post-stop Metatron animation expected to stay short for long meetings?
- Are AEC concurrency or foreground `meeting.m4a` mixing release concerns?

## Short Answer

The current design is broadly release-acceptable. The back-to-back meeting
contract is sound and covered by focused tests: once the stopped meeting is
durably saved and queued, the recorder returns to idle and a new meeting can
start while the prior meeting's final transcript work continues in the
background.

The main UX/performance nuance is that the Metatron/check sequence means
**saved + queued**, not **fully transcribed**. It should usually be short, but
it is not a fixed-duration animation: it waits for foreground stop work to
finish. The largest foreground item is creation of `meeting.m4a`, the
playback/export artifact. AEC, STT, and diarization are background finalization
work and should not gate the green check.

Recommendation for this release: keep the current architecture, QA the
stop-to-check timing explicitly, and do not move `meeting.m4a` mixing or add an
AEC queue unless QA reproduces real user-facing stalls on latest main. Use
foreground stop-stage diagnostics for that QA gate; without stage timing, a
slow Metatron report is not actionable enough to justify architecture changes.

## Animation Semantics

Relevant code:

- `Sources/MacParakeetCore/MeetingRecordingFlow/MeetingRecordingFlowStateMachine.swift`
- `Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift`
- `Sources/MacParakeet/Views/MeetingRecording/MeetingRecordingPillController.swift`
- `Sources/MacParakeet/Views/MeetingRecording/MerkabaPillIcon.swift`

The state machine documents the successful-stop effect as:

- recording is durably saved and queued;
- flow is idle, so back-to-back recording can start;
- the floating pill plays a self-contained "meeting saved" celebration:
  Metatron bloom then checkmark.

The coordinator timing is:

- flower collapse begins immediately on stop;
- after the collapse callback, the pill enters the Metatron bloom;
- Metatron has a minimum display of 1.5 seconds;
- the green check appears only after both:
  - the meeting has been durably queued, and
  - the Metatron minimum display has elapsed;
- the check holds for 1.7 seconds before the pill dismisses, unless a new
  recording interrupts it.

Important: the green check is **not** a final transcript completion signal. It
means the meeting has reached the durable queued state.

## Foreground Stop Work

Relevant code:

- `Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingService.swift`
- `Sources/MacParakeetCore/Audio/AudioFileConverter.swift`
- `Sources/MacParakeetCore/Utilities/ChildProcessWaiter.swift`

The foreground stop path starts at `meetingRecordingService.stopRecording()`.
It performs:

1. Append `meeting_recording_stopping` diagnostics.
2. Stop mic/system capture.
3. Drain the capture processing task. This has a 2-second drain timeout.
4. Finalize the source audio writer so raw `microphone.m4a` and `system.m4a`
   are closed and decodable.
5. Collect source URLs and source alignment metrics.
6. Persist `meeting-recording-metadata.json`.
7. Create `meeting.m4a` through `AudioFileConverter.mixToM4A(...)`.
8. Write meeting notes.
9. Rewrite `recording.lock` to `awaitingTranscription`.
10. Schedule cleaned-mic render readiness for AEC.
11. Build `MeetingRecordingOutput`.
12. Finish the live chunk session.
13. Release the speech-engine lease.
14. Append `meeting_recording_stopped` diagnostics.

The coordinator then calls `prepareMeetingTranscription(recording:)`, which
creates the Library processing row without running STT, and enqueues the item
in `MeetingTranscriptionQueue`. Only after that does it send
`recordingQueued`, which returns the flow to idle and allows the green-check
path to finish.

### The Expensive Foreground Item

The potentially expensive foreground item is `meeting.m4a` creation.

For dual-source meetings, `AudioFileConverter.ffmpegMixArguments(...)` creates
a stereo AAC playback artifact:

- left channel: microphone;
- right channel: system audio;
- source offsets are represented through `adelay`;
- the result is encoded with AAC at 48 kHz stereo.

This scales with meeting length and depends on FFmpeg/process/disk health. The
FFmpeg mix subprocess has a 600-second timeout. That timeout is **not** a UI
timer. If FFmpeg hangs, after 600 seconds the process is terminated, a timeout
error is thrown, and `stopRecording()` treats the mix failure as nonfatal:
it attempts to copy one raw source as the playable fallback and continues
toward queue/check. If a later critical write fails, the flow can still error
instead of reaching the checkmark.

This means a pathological FFmpeg mix can keep Metatron visible for a long time
before the app reaches `recordingQueued`.

## Artifact Layout And Naming

Current dual-source meetings use source-separated audio as the durable truth,
plus derived artifacts:

| File | Role |
|---|---|
| `microphone.m4a` | Raw microphone capture; source of truth for the local/"Me" side. |
| `system.m4a` | Raw system-audio capture; source of truth for the remote/system side. |
| `meeting.m4a` | Mixed playback/export artifact; not the authoritative final-STT input. |
| `microphone-cleaned.m4a` | Optional derived AEC-cleaned microphone input for final mic-side STT. |

`microphone-cleaned.m4a` does not overwrite `meeting.m4a` or
`microphone.m4a`. If AEC succeeds, final meeting STT uses
`microphone-cleaned.m4a` for the mic side and `system.m4a` for the system
side. `meeting.m4a` remains the playback/export artifact.

The name `microphone-cleaned.m4a` is accurate because AEC cleans only the mic
side. A name like `meeting-cleaned.m4a` would be misleading: the full mixed
meeting artifact is not rewritten by AEC.

Future naming cleanup: `microphone-raw.m4a` plus
`microphone-cleaned.m4a` would be clearer than today's
`microphone.m4a` plus `microphone-cleaned.m4a`. This should be treated as a
future artifact-contract change, not a release hotfix. The plan is tracked in
`plans/active/2026-07-05-meeting-artifact-naming-v2.md`. Existing meeting
folders should remain valid as-is.

## AEC Trigger And Fail-Soft Routing

AEC is a post-stop derived-artifact path. It is not required for the meeting to
complete.

The pipeline is:

1. Stop recording and finalize raw source files.
2. Check basic eligibility:
   - microphone source exists;
   - system source exists;
   - captured media duration is under the predicted render-time guard;
   - an echo suppressor/conditioner can load.
3. Decode sampled raw mic/system audio for the echo-path probe.
4. Run the cheap echo-path probe before loading/running the full AEC model.
5. If the probe finds no system-reference echo path in the mic, skip AEC.
6. If the probe finds enough correlated evidence, run offline AEC and write
   `microphone-cleaned.m4a`.
7. During final STT, resolve the mic source:
   - use `microphone-cleaned.m4a` if it finished before the bounded deadline
     and is viable;
   - otherwise fall back to raw `microphone.m4a`.
8. System-side STT continues to use `system.m4a`.
9. The finalizer merges mic STT, system STT, and optional diarization.

The echo-path probe is not checking for any temporal overlap between mic and
system audio. It looks for correlation-style evidence that the microphone
contains a delayed/related version of the system reference. This is what
distinguishes actual speaker bleed from two independent people talking at the
same time.

AEC is explicitly fail-soft. These outcomes should fall back to raw mic and
still allow final meeting transcription:

- no system reference;
- no microphone source;
- missing/unloaded AEC assets;
- no detected echo path;
- render failure;
- readiness timeout;
- invalid/empty cleaned artifact;
- predicted render timeout for very long captured media.

The user-visible cost of fallback is quality, not completion: remote speaker
bleed can appear in the "Me" side when final STT uses raw mic.

## Background Finalization Work

Relevant code:

- `Sources/MacParakeet/App/MeetingTranscriptionQueue.swift`
- `Sources/MacParakeetCore/Services/TranscriptionService.swift`
- `Sources/MacParakeetCore/Services/MeetingRecording/MeetingCleanedMicrophoneReadiness.swift`
- `Sources/MacParakeetCore/Services/MeetingRecording/MeetingCleanedMicRenderer.swift`
- `Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift`

After the recording is queued, `MeetingTranscriptionQueue` owns finalization.
It is single-active FIFO:

1. Update the existing processing row to processing.
2. Resolve the microphone transcription source:
   - cleaned mic if ready before the bounded deadline;
   - raw mic if AEC timed out, skipped, failed, or was unavailable.
3. Convert each captured source M4A to 16 kHz mono WAV.
4. Transcribe source WAVs as `.meetingFinalize`.
5. Optionally run diarization on the system/remote side.
6. Merge mic transcript, system transcript, and diarization.
7. Update the Library row.
8. Settle the meeting lock.
9. Navigate to the result only if no newer meeting recording is active.

AEC, STT, diarization, and final transcript merge are all after the durable
queue point. They should not block starting the next meeting.

## Back-To-Back Meeting Behavior

Relevant code:

- `Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift`
- `Tests/MacParakeetTests/MeetingRecordingFlow/MeetingRecordingFlowCoordinatorTests.swift`

New meeting starts are not queued. `startRecording(...)` only succeeds when
the state machine is already `.idle`. If the user tries too early, the start
request is ignored/refused rather than queued for later.

Once `recordingQueued` is emitted, the flow returns to `.idle`, even if the
old meeting is still doing AEC/STT/diarization in the background. Starting a
new meeting cancels the leftover completion animation and gives the pill to the
new recording.

The focused test
`testCanStartNextRecordingWhilePreviousFinalizeIsQueued` verifies this exact
case: finalization is deliberately held, the coordinator returns to idle, the
next recording starts, and the prior meeting's later completion does not
select/navigate over the active newer meeting.

UX caveat: if the user tries to start a new meeting while the prior meeting is
still in foreground stop work, the flow is not idle yet and the start is not
queued. In the worst case, a long Metatron/saving window can make a start tap
look like a no-op. QA should explicitly test "tap start while Metatron is still
visible" and record whether the affordance is understandable. A delayed
"Still saving..." state after roughly 10 seconds is a reasonable follow-up if
QA finds this confusing, but it is not an architecture blocker.

## File, Media, And YouTube Interaction

Relevant code:

- `Sources/MacParakeetCore/STT/STTScheduler.swift`
- `Sources/MacParakeetCore/STT/README.md`
- `Sources/MacParakeetCore/Services/TranscriptionService.swift`
- `Sources/MacParakeetCore/Services/Capture/LiveChunkTranscriber.swift`
- `Tests/MacParakeetTests/STT/STTSchedulerTests.swift`

`STTScheduler` has two logical slots:

| Job | Slot |
|---|---|
| `dictation` | `interactive` |
| `meetingFinalize` | `background` |
| `meetingLiveChunk` | `background` |
| `fileTranscription` | `background` |

Within the background slot:

1. `meetingFinalize`
2. `meetingLiveChunk`
3. `fileTranscription`

Already-running background work is not preempted. So if YouTube/file STT is
already running, a stopped meeting finalization waits behind it. Once the
background slot is free, `meetingFinalize` outranks queued file transcription
and queued meeting live chunks.

Starting and recording a meeting does not require the background STT slot. The
meeting can still capture audio while a file/media transcription is running.
However, meeting live-preview chunks also use the background slot, so live
preview can lag or drop under backpressure. Final transcription still uses the
durable source files after stop.

Focused tests verify:

- `meetingFinalize` waits behind an already-running file transcription;
- `meetingFinalize` beats queued meeting-live chunks;
- `meetingFinalize` beats queued file transcription.

## AEC And Diarization Performance

Relevant docs:

- `docs/audits/2026-07-04-long-meeting-full-pipeline-findings.md`
- `docs/audits/2026-07-04-long-meeting-aec-diarization-queue-followup.md`

Current measured production-config behavior:

| Meeting | AEC | Mic STT | System STT | Diarization | Total post-stop |
|---|---:|---:|---:|---:|---:|
| 25.8 min | 132.40s | 6.87s | 6.75s | 7.92s | ~154.1s |
| 42.7 min | 217.90s | 11.14s | 10.69s | 12.14s | 251.9s |

The post-stop cost is AEC-render-dominated. STT and diarization are much
faster than AEC in the measured full pipeline.

Current policy:

- readiness timeout floor: 60 seconds;
- duration multiplier: 0.25x;
- timeout cap: 600 seconds;
- derived render-attempt threshold: about 7,554 seconds, or about 2.1 hours,
  of captured media;
- longer meetings skip cleaned-mic render up front with
  `predictedRenderTimeout` and finalize on raw mic.

That policy is a deliberate bounded-cost tradeoff: very long meetings avoid a
deterministic long AEC wait, but lose cleaned-mic quality unless we later build
background enrichment.

## AEC Concurrency Risk

AEC render is currently scheduled as a detached utility task:

```swift
Task.detached(priority: .utility) { ... }
```

It is not serialized by `MeetingTranscriptionQueue`. This gives AEC a useful
head start while the next meeting may already be recording. It also means
multiple back-to-back stopped meetings can theoretically overlap AEC renders.

The overlap scenario requires all of the following:

- Meeting A has mic + system audio.
- Meeting A has an echo path, so the cheap probe does not skip AEC.
- Meeting A is under the about-2.1-hour render-attempt guard.
- Meeting B is stopped before Meeting A's AEC render finishes.
- Meeting B also has mic + system audio and an echo path.

Approximate AEC windows from the measured 11.70-11.77x realtime render speed:

| Meeting duration | Approximate AEC render |
|---:|---:|
| 10 min | ~50s |
| 30 min | ~2.5 min |
| 60 min | ~5 min |
| 90 min | ~7.7 min |

This is plausible for a long meeting followed by a short meeting, but less
likely for normal 30/60-minute back-to-back meetings because the prior AEC
should usually finish while the next meeting is still recording.

Recommendation: do not add an AEC queue as a release-blocker. A naive queue or
global concurrency limiter is straightforward mechanically, but product-subtle:
the cleaned-mic readiness timeout currently races the render task. If a queued
render waits behind another render, the timeout includes queue wait time and
later meetings may fall back to raw mic more often. That protects resources but
silently reduces transcript quality.

If this becomes a real issue, prefer:

1. Add diagnostics for AEC render started/finished and active render count.
2. Consider a global render limiter only after observing resource contention.
3. If adding a limiter, revisit timeout semantics so queue wait does not
   accidentally erase cleaned-mic quality for ordinary meetings.

Do not move AEC into `MeetingTranscriptionQueue` casually. That would give up
the current head start and lengthen final transcript latency.

## `meeting.m4a` Foreground Mix Risk

The foreground `meeting.m4a` mix is the more release-relevant UX risk than AEC
concurrency.

Current behavior is conservative:

- green check means the playback/export artifact exists or a fallback was
  attempted;
- the Library processing row can point at a durable `meeting.m4a` path;
- recovery/playback/export semantics are simpler.

The cost is that recorder availability waits for this playback artifact. If
FFmpeg mix is slow or stuck, Metatron can remain visible before the green check.

Moving `meeting.m4a` mixing to background is a valid future architecture, but
it is not a small release polish change. It would require:

- representing an audio-artifact-pending state;
- disabling or redirecting playback/export until the artifact exists;
- ensuring recovery can finish or retry the mix;
- changing cleanup semantics;
- updating Library UI expectations;
- adding tests for missing/pending `meeting.m4a`.

Recommendation: do not move `meeting.m4a` mixing out of the foreground path
for this release unless QA reproduces real stop stalls on latest main. If QA
does reproduce stalls, add foreground stop-stage timing first so we know
whether the culprit is capture stop, drain, writer finalize, FFmpeg mix,
metadata/lock writes, DB row creation, or queue enqueue.

## Diagnostics Evidence

Local diagnostics reviewed:

- `$HOME/Library/Logs/MacParakeet/dictation-audio.log`

The log currently brackets stop with:

- `meeting_recording_stopping`
- `meeting_recording_stopped`
- `meeting_cleaned_mic ... outcome=scheduled/rendered/skipped`
- `meeting_cleaned_mic_source ... selected=... reason=...`

Those historical lines can identify long total stop windows but not the exact
foreground substage. They cannot separate capture stop, writer finalize, FFmpeg
mix, lock write, DB row creation, or queue enqueue.

This audit resulted in foreground stop-stage diagnostics so release QA can
diagnose slow Metatron/check behavior before considering architecture changes.
The new diagnostics use `meeting_stop_stage` lines with `stage=...`,
`duration_ms=...`, and `outcome=...` fields for:

- coordinator `notes_commit`;
- service `capture_stop`;
- service `processing_drain`;
- service `writer_finalize`;
- service `source_urls`;
- service `metadata_save`;
- service `mix`;
- service `notes_write`;
- service `lock_write`;
- service `cleaned_mic_schedule`;
- service `cleanup`;
- service `service_total`;
- coordinator `service_stop`;
- coordinator `prepare_row`;
- coordinator `queue_enqueue`;
- coordinator `queued_total`.

Observed examples:

- Older 2026-06-30 UTC session had a pathological stop window from
  `meeting_recording_stopping` to `meeting_recording_stopped` of about 87
  minutes. The AEC render was only scheduled at the end of that window, so that
  case supports the diagnosis that long Metatron can be foreground stop work,
  not background AEC/STT/diarization. This is older-state evidence, not proof
  of a current-main bug.
- Recent 2026-07-05 UTC sessions showed healthier stop windows around 0.9s,
  1.4s, and 6.9s.

Release QA should inspect these lines for any stop-to-check run that feels
slow. That turns future Metatron-stuck reports into a measurable diagnosis
instead of a guess between capture stop, drain, writer finalize, FFmpeg mix,
metadata/lock writes, processing-row creation, or queue enqueue.

## Verification Performed

Source/code surfaces inspected on clean `681e3610e`:

- `MeetingRecordingFlowStateMachine`
- `MeetingRecordingFlowCoordinator`
- `MeetingRecordingService`
- `MeetingTranscriptionQueue`
- `MeetingCleanedMicrophoneReadiness`
- `MeetingCleanedMicRenderer`
- `TranscriptionService`
- `STTScheduler`
- `LiveChunkTranscriber`
- `AudioFileConverter`
- `ChildProcessWaiter`
- `ANEInferenceGate`
- `spec/05-audio-pipeline.md`
- existing long-meeting audit docs

Focused tests run:

```bash
swift test --filter 'MeetingRecordingFlowCoordinatorTests/testCanStartNextRecordingWhilePreviousFinalizeIsQueued|STTSchedulerTests/testMeetingFinalize|MeetingRecordingServiceTests/testStopRecordingReturnsBeforeSlowCleanedMicRendererCompletes'
```

Result:

- 5 tests executed.
- 0 failures.

Covered:

- back-to-back start while prior finalization is held;
- stop returning before slow cleaned-mic renderer completes;
- meeting finalization priority relative to queued file and live-preview jobs;
- meeting finalization waiting behind an already-running file transcription.

Follow-up implementation in the active checkout:

- added `meeting_stop_stage` diagnostics in `MeetingRecordingService` for
  foreground service stages;
- added `meeting_stop_stage` diagnostics in `MeetingRecordingFlowCoordinator`
  for notes commit, service stop, Library row preparation, queue enqueue, and
  total queued timing;
- reran the same 5 focused tests with 0 failures after the diagnostic changes;
- ran `git diff --check` on the touched files with no whitespace findings.

Full `swift test` was not run for this note.

## Release Recommendation

Ship current behavior if targeted QA passes.

Do before release:

- Run stop-to-check QA with `meeting_stop_stage` diagnostics available, and
  inspect the stage timings for any run that feels slow.
- QA stop-to-check timing for short, medium, and longer meetings.
- QA back-to-back meetings while prior meeting is processing.
- QA tapping start while Metatron/saving is still visible; confirm the user
  does not interpret an ignored too-early start as a broken app.
- QA meeting start/stop while YouTube or file transcription is already running.
- QA Library row state: green check should not be interpreted as final
  transcript completion.
- QA a long dual-track meeting under the about-2.1-hour threshold to verify
  cleaned-mic path.
- QA or simulate above-threshold behavior to confirm `predictedRenderTimeout`
  raw fallback.

Do not do before release unless QA finds a current-main problem:

- Do not move `meeting.m4a` mixing to background.
- Do not add an AEC queue/concurrency limiter.
- Do not change green-check semantics to mean transcript completion.

Good post-release improvements:

- Add AEC active-render diagnostics.
- Plan artifact-contract v2 naming so future recordings can use
  `microphone-raw.m4a` while old `microphone.m4a` folders continue to load.
- Consider a delayed "Still saving..." affordance if QA finds long Metatron
  windows confusing.
- Consider background `meeting.m4a` artifact generation with explicit pending
  playback/export UI.
- Consider AEC concurrency limiting only after observing overlap/resource
  contention in diagnostics.
- Consider background enrichment for >2.1-hour meetings if
  `predictedRenderTimeout` appears often in field diagnostics.
