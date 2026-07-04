# Long-Meeting AEC + Diarization Queue Follow-Up - 2026-07-04

> Status: reviewed brief with verification addendum. This note documents the
> current queueing and resource-risk shape for long meetings when LocalVQE AEC
> and speaker diarization are both in play. Originally drafted against
> `origin/main` at `e2a6e5a57098`; claims re-verified and updated against
> `cfbcccb30e23` (post PR #688) on 2026-07-04. The resulting work plan is
> `plans/active/2026-07-04-long-meeting-aec-policy.md`.

## Question

If a user records a 2-3 hour meeting and also enables speaker separation, can
the combined AEC + STT + diarization work block dictation or other meetings?
What should we mitigate before treating long meetings as a first-class path?

## Short Answer

- Normal dictation is not in the same logical STT queue as meeting finalization.
  Dictation routes to the `interactive` STT slot; meeting finalization routes
  to the `background` slot.
- Meeting finalization itself is serial. One long meeting can delay the next
  stopped meeting's final transcript.
- File transcription and meeting finalization share the background STT path, so
  heavy meeting finalization can delay file/media transcription.
- As of PR #688, speaker diarization defaults ON where supported (meetings with
  a system-audio track). It runs outside the STT scheduler, so it adds real
  machine-level compute pressure even though it does not sit in the same STT
  queue as dictation. On macOS 14 it additionally serializes with other ANE
  inference behind `ANEInferenceGate`; on macOS 15+ the gate is a no-op and the
  cost is concurrent ANE pressure instead.
- The long-meeting risk is not the LocalVQE model size. It is duration-scaled
  full-track decode/render memory, plus cumulative post-stop work: cleaned mic
  wait/render, mic STT, system STT, and (now default) system-track diarization.
- Today, when the cleaned-mic readiness timeout fires, the in-flight AEC render
  is cancelled and its candidate outputs are discarded
  (`MeetingCleanedMicrophoneReadiness.swift:150`), and the renderer honors
  cancellation cooperatively (`MeetingCleanedMicRenderer.swift`, repeated
  `Task.checkCancellation()`). At the measured ~12x realtime factor against the
  600-second cap, any meeting longer than roughly 2 hours deterministically
  times out: the machine spends up to 10 minutes of AEC compute, throws all of
  it away, and transcribes raw mic anyway.

## Current Pipeline

At meeting stop, final transcription is enqueued through
`MeetingTranscriptionQueue`. The queue holds one active item and an array of
pending items, starts only when there is no active task, and removes pending
items FIFO-style (`Sources/MacParakeet/App/MeetingTranscriptionQueue.swift:34`,
`:54`, `:67`, `:69`, `:79`).

The active queue item calls `finalizeMeetingTranscription(...)`, then marks the
meeting transcription complete or failed (`MeetingTranscriptionQueue.swift:81`,
`:88`, `:94`).

Inside finalization:

1. `transcribeMeetingSources(...)` resolves the microphone source. If cleaned
   mic is ready before the bounded deadline, it uses `microphone-cleaned.m4a`;
   otherwise it falls back to raw mic (`TranscriptionService.swift:1240`,
   `:1342`, `:1367`).
2. Mic and system tracks are converted to WAV and transcribed as
   `.meetingFinalize` jobs (`TranscriptionService.swift:1244`, `:1252`,
   `:1258`, `:1260`).
3. If speaker diarization is enabled and a system track exists,
   `diarizeMeetingSystemIfNeeded(...)` runs on the system WAV
   (`TranscriptionService.swift:1083`, `:1102`, `:1281`, `:1297`).
4. `MeetingTranscriptFinalizer.finalize(...)` merges mic words, system words,
   and optional system diarization into the final transcript
   (`MeetingTranscriptFinalizer.swift:23`, `:45`, `:52`, `:61`, `:70`).

Important detail: diarization splits the system/remote side. The local mic side
remains "Me"; AEC is what prevents remote speaker bleed from becoming false
"Me" words.

## Queue And Blocking Semantics

### Dictation

Dictation is protected at the STT scheduler layer. `STTScheduler` explicitly
documents independent slots so dictation can remain responsive while meeting
and file work share a prioritized background path
(`Sources/MacParakeetCore/STT/STTScheduler.swift:20`).

Slot routing is:

| Job | STT slot |
|---|---|
| `.dictation` | `interactive` |
| `.meetingFinalize` | `background` |
| `.meetingLiveChunk` | `background` |
| `.fileTranscription` | `background` |

See `STTScheduler.swift:843` and the same runtime-lane split in
`STTRuntime.swift:1775` and `ParakeetUnifiedEngine.swift:427`.

So a long meeting should not queue-block normal dictation. However, this is a
logical scheduling statement, not a full resource guarantee. AEC, STT, and
diarization still consume CPU/CoreML/ANE and memory. On a saturated machine,
dictation can still feel slower even if it is not waiting in the same FIFO.

### Other meetings

`MeetingTranscriptionQueue` is single-active. A 2-3 hour meeting finalization
can delay later stopped meetings. This is probably the right default: running
two multi-hour AEC/STT/diarization jobs in parallel would amplify RAM and ANE
pressure.

### File/media transcription

File transcription shares the `background` STT slot. Meeting finalization has
higher background priority than meeting-live chunks and file transcription
(`STTScheduler.swift:857`). There is no preemption of an already running
background job, but once the scheduler selects the next job, meeting finalization
outranks file work.

### Diarization

Meeting diarization is not a `STTScheduler` job. `DiarizationService` prepares
offline models and calls FluidAudio's offline diarizer inside
`ANEInferenceGate.shared.withExclusiveAccess(...)`
(`Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift:112`).
The gate serializes ANE inference only on macOS 14, where concurrent ANE use
intermittently SIGBUSes; on macOS 15+ it is a no-op. So the failure mode
differs by OS: on macOS 14, diarization extends total post-stop wall-clock by
serializing with other ANE inference; on macOS 15+, it overlaps and adds
concurrent ANE/CPU pressure instead.

As of PR #688 (`cfbcccb30e23`), speaker diarization defaults ON where supported:
a fresh preference store resolves to enabled, the user setting remains the
override, and the meeting pipeline still requires a system-audio track before
diarization runs. This means the full post-stop load (AEC render + mic STT +
system STT + diarization) is now the DEFAULT path for dual-track meetings, not
an opt-in.

## Measured AEC Baseline

The prior LocalVQE runtime audit measured AEC-only render cost on real retained
meeting artifacts (`docs/audits/2026-07-04-localvqe-aec-runtime-findings.md`):

| Fixture | Duration | AEC elapsed | Realtime factor | Peak RSS |
|---|---:|---:|---:|---:|
| Short real meeting | 183.4 s | 14.57 s | 12.59x | 111.6 MB |
| Long real meeting | 1549.5 s | 124.01 s | 12.50x | 421.6 MB |
| 43-min real meeting | 2563.8 s | 219.66 s | 11.67x | 663.7 MB |

The model load itself added only about 9-10 MB. The duration-scaled memory was
already present before LocalVQE load, which points to decoded full-track buffers
as the dominant source. A linear fit of the three points gives roughly 230 KB
of peak RSS per second of meeting on top of a ~70 MB base, which is consistent
with full-track Float32 decode buffers.

The current readiness policy waits for cleaned mic with:

- floor: 60 seconds
- multiplier: 0.25x recording duration
- cap: 600 seconds

See `MeetingCleanedMicrophoneReadiness.swift:13`, `:19`, and `:39`. If cleaned
mic does not resolve before the timeout, final STT falls back to raw mic and
records the reason (`MeetingCleanedMicrophoneReadiness.swift:603`, `:612`,
`:616`, `:655`). The timeout also cancels the render task and discards its
candidate outputs (`MeetingCleanedMicrophoneReadiness.swift:145-153`); the
renderer checks `Task.checkCancellation()` throughout, so the compute genuinely
stops but nothing is kept.

## Long-Meeting Risk Model

This is an extrapolation from the 42.7-minute AEC measurement, not a measured
2-3 hour run.

| Meeting length | AEC-only estimate | Risk |
|---:|---:|---|
| 2 hours | about 10 minutes, about 1.7-2.0 GB RSS | at/over the 10-minute readiness cap |
| 3 hours | about 14-15 minutes, about 2.5-3.0 GB RSS | deterministic raw fallback for final STT, high RAM pressure |

Two cautions on the extrapolation itself:

- The measured realtime factor degraded slightly with duration (12.59x at 3
  minutes down to 11.67x at 43 minutes), so straight-line time estimates for
  2-3 hours are mildly optimistic.
- Linear RSS extrapolation cannot see a swap-pressure cliff. 2.5-3.0 GB of
  transient background RSS on a 16 GB machine alongside dual STT and
  diarization may behave much worse than the number suggests.

Because timeout cancels and discards the render, the practical shape today is:
meetings above roughly 2 hours (600 s cap x ~12x realtime factor = ~7,200 s of
audio) spend the full render budget, keep nothing, and fall back to raw mic.
The compute is bounded but pure waste, and it is predictable from the recording
duration before the render starts.

If speaker separation is enabled (now the supported-hardware default), add:

- mic STT
- system STT
- system-track diarization
- ANE serialization with other CoreML work on macOS 14, or concurrent ANE
  pressure on macOS 15+

We have not yet benchmarked this full path. Therefore, the current data supports
"normal 30-45 minute meetings are resource-safe on the tested machine", but it
does not prove "2-3 hour meetings with diarization enabled are safe and fast."

## Recommended Mitigation Shape

### Near term

1. Add an upfront duration guard: when the recording duration makes the
   cleaned-mic render provably unable to finish inside the readiness cap even
   at the best measured realtime factor, skip scheduling the render entirely,
   record the routing reason, and go raw-first. This removes the deterministic
   10-minute wasted render for 2+ hour meetings with a few lines of policy.
   (Diarization default-off is no longer available as a mitigation: PR #688
   deliberately made it default-on per ADR-027; the policy gate has to carry
   the load instead.)
2. Keep meeting finalization serial.
3. Add a full-pipeline benchmark for a 60-120 minute recording with:
   - AEC enabled
   - mic STT
   - system STT
   - speaker diarization enabled
   - peak RSS and wall-clock timing recorded per stage
4. Use the benchmark to set real duration/memory thresholds before enabling
   stronger long-meeting claims. The shape to validate:
   - under ~90 minutes: current path
   - ~90-120 minutes: current path if the benchmark confirms headroom,
     otherwise raw-first
   - above the provable-timeout threshold (~120 minutes today): raw-first,
     enhancements deferred to background enrichment once it exists

### Medium term

Build a background enrichment path:

1. Finalize a usable raw or cleaned-if-ready transcript within the existing
   bounded wait.
2. Continue AEC and/or diarization as lower-priority background enrichment for
   long meetings.
3. Update the meeting record when enrichment completes, including provenance:
   raw first, cleaned later, diarized later.
4. Make cancellation/retry visible and safe.

This avoids making the user wait 10-20 minutes for a long-meeting final
transcript while preserving a route to higher-quality artifacts.

### Long term

Implement chunked/streaming AEC rendering. That is the real RAM fix. The current
full-track decode shape makes peak memory scale with meeting duration; chunked
decode/render should make peak memory scale with chunk size. It also opens the
door to checkpointing partial renders instead of discarding them on timeout.

If diarization benchmarks show similar duration-scaled pressure, apply the same
bounded/chunked thinking there or keep it as explicit background enrichment.

## Verification Addendum (2026-07-04, Fable review)

Every load-bearing claim above was re-verified against `origin/main` at
`cfbcccb30e23`:

- Slot routing confirmed at `Sources/MacParakeetCore/STT/STTScheduler.swift:843`
  (`.dictation` -> interactive; meeting/file jobs -> background) with
  within-slot priority `meetingFinalize` (0) > `meetingLiveChunk` (1) >
  `fileTranscription` (2).
- `MeetingTranscriptionQueue` single-active FIFO confirmed.
- Diarization outside the STT scheduler behind `ANEInferenceGate` confirmed,
  with the macOS-14-only serialization nuance noted above.
- Timeout cancel-and-discard behavior confirmed at
  `MeetingCleanedMicrophoneReadiness.swift:145-153` with cooperative
  cancellation throughout `MeetingCleanedMicRenderer`.
- The RAM/time extrapolations are arithmetically consistent with the measured
  data (linear fit ~230 KB/s + ~70 MB base; ~12x realtime factor), with the
  two cautions listed in the risk model.
- The original draft's "diarization is off by default" claim was true at its
  baseline commit and is now stale: PR #688 flipped the default on.

Decisions taken on the expert-review questions (rationale in
`plans/active/2026-07-04-long-meeting-aec-policy.md`):

1. Serial `MeetingTranscriptionQueue` stays. When enrichment exists it gets its
   own serial, cancellable lane; finalization and enrichment do not share a
   queue.
2. Long meetings go raw-first when the render is provably unable to finish
   inside the cap (upfront duration guard, Phase 1a). Broader raw-first
   thresholds wait for benchmark data.
3. Thresholds are set from the Phase 1b full-pipeline benchmark, not guessed.
   Duration gating first; free-memory gating only if the benchmark shows a
   cliff.
4. Cancel-and-discard remains correct until a provenance-updating enrichment
   path exists. "Continue after timeout" IS background enrichment (Phase 2);
   the near-term fix is to not start provably doomed renders.
5. Diarization stays tied to finalization for normal-length meetings and moves
   to enrichment above the same duration threshold as AEC. One policy, two
   consumers.
6. Minimal user-facing "transcript ready, still enhancing" status is required
   before shipping enrichment broadly, building on the provenance fields from
   PR #676. Not required for Phase 1.

## Bottom Line

The queue architecture protects normal dictation from being FIFO-blocked by a
long meeting. It does not make long-meeting processing free. The product risk is
delayed meeting/file processing and high background RAM/compute when users
combine multi-hour recordings, AEC, and (now default-on) speaker separation —
plus, today, a deterministic wasted render for meetings above ~2 hours.

The best next step is not more UI. It is the upfront duration guard plus a
full-pipeline benchmark with diarization enabled, followed by a long-meeting
policy that finalizes a fast transcript and moves heavy cleanup into background
enrichment.
