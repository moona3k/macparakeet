# Issue #1032: preserve silence after microphone startup

## Incident and diagnosis

[Issue #1032](https://github.com/moona3k/macparakeet/issues/1032) reports meeting microphone interruption on 0.8.0, build `20260909173236`, source commit `1cc48e726ad4`, M2 Pro, macOS 26.6.2. The [opt-in diagnostic log](https://github.com/moona3k/macparakeet/blob/d67cf93ec21ec62739aea6d4efc472e2af6a82cb/diagnostics/1789394689775-dictation-audio.log) shows successful Bluetooth startup, six zero-filled triggers with a running engine, nine recovery attempts across three episodes, then terminal microphone interruption 87.535 seconds after meeting start. System audio continues for another 28 minutes 36 seconds. Final microphone coverage is 0.008; system coverage is 1.000. There are no logged transcription failures or backpressure drops.

The shared source treats two seconds of exact-zero Bluetooth PCM as a failure, drops those buffers before consumers, and restarts the engine. Repeated readiness/probation failures exhaust recovery and invalidate subscribers. The same classifier also rejects zero-length buffers, so its log cannot establish whether this device supplied silence or empty buffers. Hardware mute, device noise suppression, and native route failure remain unverified physical triggers.

## Why a targeted correction, not a full revert

[PR #862](https://github.com/moona3k/macparakeet/pull/862) introduced this zero-filled policy alongside needed first-buffer readiness, bounded probation/recovery, route-generation checks, and safe VPIO teardown. Reverting the entire change would remove those unrelated protections. Earlier Bluetooth instability also existed on 0.7.3 ([#846](https://github.com/moona3k/macparakeet/issues/846)); a full rollback is not a proven cure.

The false inference is that valid silent PCM proves a running source is dead. The correction is scoped to established engines: startup still requires a nonzero microphone sample on Bluetooth/unresolved routes, but after startup commits, valid silent buffers must preserve delivery, source lifetime, and the recording timeline. Empty or invalid buffers remain distinguishable failures. A stopped graph or missing callbacks retains bounded recovery. Signal loss alone can support diagnostics and existing health warnings, not terminal teardown.

The existing #1010 implicit Bluetooth retry remains intact. It is absent from the reporter's release, and it helps startup; it does not by itself correct the established-capture failure.

## Scope and invariants

- Keep System Default implicit, named routing explicit, and idle Bluetooth capture suppressed.
- Preserve startup/configuration generation ownership, VPIO microphone channel-zero semantics, finite retries, probation, and Stop cancellation.
- Preserve the process-wide shared stream and concurrent meeting/dictation subscribers.
- Distinguish pre-filter callback shape and signal state with bounded metadata-only diagnostics emitted off the audio render callback. No audio/transcripts or raw device identities.
- No database/artifact mutation, meeting UI redesign, global device selection change, or new recovery owner.

## Verification

The two regression tests failed against unmodified `d67cf93e` with 11 assertions: silence was dropped, the engine restarted, and terminal death fired. With the correction, 112 focused audio tests pass, covering both named and implicit Bluetooth routes, 60 seconds of silence followed by resumed speech, two simultaneous shared subscribers with exact frame delivery, startup-generation rejection, bounded recovery exhaustion, silent recovery probation, Stop, and empty/nonfinite input.

Independent correctness and maintainability/privacy reviews found one actionable issue in the first patch: validation scanned discarded VPIO reference channels. Validation now inspects only microphone channel 0 for VPIO and every channel for raw input. Both interleaved and planar tests prove that an invalid reference cannot kill a healthy mic and a healthy reference cannot mask invalid mic input. The reviewer verified the correction. Changed Swift files pass `swift-format lint`; `git diff --check` is clean.

Final local `swift test` passed on 2026-09-14: 6,615 XCTest cases, 24 skipped, zero failures, plus 29 Swift Testing tests. The full suite ran once, after the final code correction; subsequent edits only clarify documentation. `no-mistakes` is unavailable in this environment. Local Greptile reports that it is not signed in. Direct tests, lint, and independent review passed; those do not constitute a Greptile approval or hosted CI result. Publication and exact-head hosted status belong to the PR, not a claim that this code is already released.

The hardware boundary remains explicit: synthetic tests cannot establish why this PowerConf installation produced unusable input, prove native `-10868` is resolved, or validate an actual Bluetooth meeting. Startup while continuously muted remains subject to the existing strict startup gate. A genuinely stuck driver emitting valid zeros is indistinguishable from mute using PCM alone. Full-sample validation adds bounded render-thread work; physical callback latency has not been measured.

## Related AirPods disconnect report

[#1033](https://github.com/moona3k/macparakeet/issues/1033) is on the same shipped build, but has no attached diagnostic log. It reports failure after disconnect, not the proved zero-filled recovery sequence. See the [separate comparison and hardware test plan](2026-09-14-issue-1033-airpods-disconnect.md). Do not close it as a duplicate or claim this silence correction fixes disconnect/discovery.
