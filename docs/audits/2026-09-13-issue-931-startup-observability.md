# Issue 931: capture never started, and how to observe the next occurrence

Date: 2026-09-13. Status: failure mechanism reproduced; the affected machine's
native USB/Core Audio cause is not established. This change improves diagnosis,
not native-call cancellation or guaranteed recovery.

## Verdict

[Issue 931](https://github.com/moona3k/macparakeet/issues/931) reports a meeting
that appeared to record for about seven minutes but produced no audio. Its
health summary shows **no completed capture startup and zero frames on either
source**. It does not show transcription deleting or overwriting a recording.

The application has two contributing behaviors:

1. Combined capture awaits microphone startup before starting system audio.
   A blocked microphone therefore prevents both sources from capturing.
2. Version 0.7.3 displayed the recording presentation before that await
   completed. The elapsed session time could look like recorded audio time.
   [PR 953](https://github.com/moona3k/macparakeet/pull/953) corrected this with a
   distinct starting state; that mitigation is in the released 0.8.0.

Synchronous native setup is still capable of blocking. The one-second
first-buffer gate starts **after** native engine setup/start returns. Neither
that gate nor the running-stream callback watchdog bounds an `AVAudioEngine`
call that has not returned. The old log excerpt cannot identify which such
call, driver interaction, or device transition blocked in issue 931.

## Evidence and limits

| Evidence | What it establishes | What it does not establish |
| --- | --- | --- |
| Issue 931: `meeting_mic_capture_starting`, USB default input, then `source_mode=unknown`, `mic_started=false`, both first-buffer flags false | The microphone start was entered; no successful capture-start report reached the recording service | The exact blocked native function, USB driver, or physical fault |
| All microphone/system/mixed byte and frame counts are zero | There is no captured media in the reported session metrics | That unrelated files elsewhere should be deleted or cannot exist |
| `duration_s=428.049` | Time elapsed since session/start intent in that release | Seven minutes of successfully captured audio |
| Prepared engine discarded after a configuration change | Prewarm invalidation occurred | That the discard itself caused this hang |
| Related [issue 933](https://github.com/moona3k/macparakeet/issues/933#issuecomment-5549686745): engine start 08:01:44–08:22:55, capture until 08:23:47 | A roughly 21-minute native start delay was observed in another 0.7.3 report | That issue 931 blocked in the identical native call |

Examined versions: 0.7.3 tag `d6321f87dccecf29bd4792113f522bb0c98d1f35`,
0.8.0 tag `76c126b1b2dbc541d7d389005557cbe73d7f5c24`, and current development
base `978238cb864009b36f36d1cbfb9f63c96236b74b`. The latest release inspected
was the notarized 0.8.0 DMG published September 9. Development source presence,
merged fixes, released binaries, and hardware evidence are separate claims.

In 0.7.3, `MeetingRecordingService` creates a session folder and writer before
awaiting capture. It fills `captureHealthMetrics.sourceMode`,
`microphoneStarted`, and `captureStartedAt` only after capture startup returns,
then begins consuming capture events. Thus `unknown` here is missing startup
completion, not proof of an invalid user source selection. Stopping a session
with no audio source URLs follows the old no-audio cleanup path: log health,
remove the empty folder/lock, and throw `noAudioCaptured`. That explains the
reported missing folder without invoking audio overwrite.

Current `MeetingAudioCaptureService` still starts the microphone before the
system source. `SharedMicrophoneStream` dispatches lifecycle work onto its
engine queue; `AVAudioEngineMicrophonePlatform` synchronizes native setup on
its own serial queue. Native device selection, input-node access, voice
processing, format/tap setup, engine start, or teardown may delay completion.
Stopping cannot safely preempt arbitrary native code on those queues.

Related mitigations must not be conflated:

- [PR 862](https://github.com/moona3k/macparakeet/pull/862): first-buffer
  readiness checks after native start returns; absent from 0.7.3.
- [PR 950](https://github.com/moona3k/macparakeet/pull/950): equivalent route
  snapshot handling for the [issue 928](https://github.com/moona3k/macparakeet/issues/928)
  prewarm/discard loop. This does not establish a native-hang fix for 931.
- PR 953: honest starting presentation and pending-start ownership. It does
  not make a synchronous driver operation cancellable.

## Reproduction without recording user audio

A deterministic Swift 6 probe compiled the unchanged current production
`MeetingAudioCaptureService` with a gated fake microphone and fake system
source. Six checks passed:

- Pending microphone start leaves system start count at zero.
- Cancelling the task leaves the native-like start pending; another start is
  rejected while the original owns capture.
- Stop reaches source teardown but settlement still waits for that start.
- Releasing the late microphone settles cancellation without starting system audio.
- A system-only replacement succeeds after the old operation settles.
- An immediate microphone error also aborts combined startup before system start.

This isolates application control flow, not USB hardware or AVAudioEngine
internals. The existing capture-service ownership tests and new blocked-engine
integration tests cover this distinction in the package test suite.

## Implementation plan and decisions

The bounded implementation is deliberately diagnostic:

1. Record lifecycle phase transitions around native calls, never inside the
   realtime tap callback. Create start/prepare/stop observation before waiting
   on the platform queue so queue contention is distinguishable from setup.
2. Use an independent utility timer to emit at most one slow checkpoint after
   five seconds. The timer reads only locked, content-free state: no HAL,
   engine access, file I/O, or network calls on the blocked audio queue.
3. Emit a terminal wide event when start/recovery returns. Slow prepare/stop
   also emit; fast prepare/stop are suppressed. Keep the checkpoint and terminal
   on one random attempt ID. Preserve the originating error phase across cleanup.
4. Send the same safe snapshot asynchronously to existing local diagnostics
   and consent-gated telemetry. No new upload of logs or captured content.
5. Validate the new event at the Cloudflare boundary and query it separately
   from product success/failure denominators. A slow checkpoint is not a failed
   meeting; slow followed by success is a slow successful engine operation.
6. Make the health summary explicit with `capture_start_completed`; include
   elapsed time on failed-start product events; hedge compact error recovery
   copy so it does not promise that audio exists.

The wide-event approach follows [Logging Sucks](https://loggingsucks.com/):
accumulate useful context instead of adding a log line for every step.
Native hangs need one additional bounded in-progress checkpoint because a
completion-only event never arrives while the operation is stuck. Customer
identity/business data examples from generic logging guidance are not
appropriate for this local-first application.

## Broader observability review

Existing foundations are retained: canonical product operation events, local
process-session/monotonic context, consent checks, bounded queues and delivery
diagnostics, retry classification, error-message redaction, offline diagnosis,
and monitoring freshness/denominator handling. Adding more unstructured error
strings or reimplementing these mechanisms would not resolve the evidence gap.

| Gap | Decision in this change |
| --- | --- |
| Native setup can hang before timing/terminal logs | Independent phase checkpoint plus per-phase timing summary |
| Failed meeting startup omits elapsed duration | Populate existing `meeting_operation.duration_seconds` on that path |
| `unknown` source mode ambiguously suggests bad selection | Add local `capture_start_completed` without inventing a successful start report |
| Generic reviewer output misses unfinished engine operations | Separate `currentAudioEngineDiagnostics` and watch signals on the server |
| Exact build provenance absent from generic event envelope | Document follow-up; do not widen every event/envelope for this incident |
| GCD boundary loses parent task-local operation context | Dedicated engine attempt ID now; explicit cross-layer correlation remains follow-up |
| Force quit can lose queued telemetry | Best-effort delivery remains explicit; no guaranteed crash-safe network receipt |

`phase_*_ms` totals include all visited fallback attempts. Route/prepared
fields describe the latest attempt, not the whole fallback history. Recovery
observations cover one executed recovery attempt, excluding scheduled backoff.
Stop has no input request: its route/VPIO/buffer fields are unset/default
metadata, not a description of the engine being stopped.

## Deployment and verification gates

Deploy the companion website receiver **before releasing an emitting app**.
The previous receiver rejects unknown events with a permanent HTTP 400 for
the entire mixed batch. The additive receiver remains compatible with older
apps; no database migration or public stats change is needed. If rolling
back the receiver after app rollout, retain the event allowlist/validator.

App tests exercise deterministic phase clocks, concurrency, one-shot behavior,
cancellation, privacy sanitization, teardown attribution, and blocked cold and
prepared starts through the platform injection seam. Website tests exercise
strict validation, real handler batch ingestion, unknown-prop removal, and
slow-to-success exclusion from product failure denominators. The PR records
actual build/test and independent-review results; this document describes the
coverage, not an assertion that checks have run at every future revision.

No affected USB microphone, browser meeting, physical Fn workflow, or native
hang has been reproduced on hardware in this investigation. No production
deployment, user audio inspection, database mutation, or release is part of
these PRs.

## Evidence to collect on recurrence

Keep the app running long enough for the five-second checkpoint, then preserve
the local diagnostics around `audio_engine_lifecycle` and matching attempt ID.
Record the exact app version/build, macOS version, selected source mode,
transport, and whether a USB dock or route changed. Compare checkpoint phase
with any terminal record and the meeting health summary. No terminal record
means completion was not observed, not proof that the process is still hung.

While it is still blocked, use Activity Monitor's **Sample Process** for
MacParakeet to identify the native stack; review it locally for private paths
before sharing. Logs can identify a pending call boundary; a native stack is
needed to distinguish driver/HAL waits from an application lock cycle.
Do not reset Core Audio, delete meeting artifacts, or orphan a replacement
engine as an automatic diagnostic action. An out-of-process capture boundary
or a partial-start product policy would require separate design and hardware
validation, not a timeout wrapper around uninterruptible native work.
