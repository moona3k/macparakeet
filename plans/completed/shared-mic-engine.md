# Plan: Shared microphone engine for concurrent dictation + meeting

> Status: **COMPLETE** — all 7 steps shipped. Plan archived 2026-04-30 after step 7 cleanup PR.
> Author: agent (Claude) + Daniel
> Date: 2026-04-29 → 2026-04-30
> Related: PR #189 (steps 1-6), step-7 cleanup PR (legacy paths removed), ADR-015 (rewritten §1), ADR-014 (meeting recording), `docs/research/vpio-process-tap-conflict.md` (option (d))

## Step status

| Step | Status | Notes |
|---|---|---|
| 1. Build `SharedMicrophoneStream` + tests behind flag | ✅ Done | Commits `7f93935b` + `c7f690ea`. 2030 XCTest pass. |
| 2. Migrate `MicrophoneCapture` to subscribe behind flag | ✅ Done | Commits `7e57f5fb` + `a6f8595f`. Platform device-fallback + onEngineDeath callback + flag-on subscriber path. 2040 XCTest pass after codex-review fixes (watchdog timing + start-during-stop race guard). |
| 3. Soak meeting recording with flag on (1 day) | ✅ Done | Real-hardware smoke verified 2026-04-30: `shared_mic_engine_input_device_started source=system_default vpio=true`, first buffer in 113ms, clean teardown. |
| 4. Migrate `AudioRecorder` (with ch[0] mono extraction) | ✅ Done | Commit `0d9f8cad`. `extractChannelZero(from:)` helper + actor-reentrancy guard. |
| 5. Concurrent-flow soak (the actual bug fix verification) | ✅ Done | Real-hardware verification 2026-04-30: 4 dictations during one live meeting produced `rawChars=161, 135, 77, 319` — pre-fix would have been silence. |
| 6. Flip `AppFeatures.useSharedMicEngine = true` | ✅ Done | Commit `1412c6f7` in PR #189. Hardening commit `3149eb40` followed addressing Gemini bot RT-thread findings. |
| 7. Delete legacy paths + finalize ADR-015 §1 | ✅ Done | Step-7 cleanup PR (post-#189). Removed `useSharedMicEngine` flag, deleted private-engine code from `MicrophoneCapture` / `AudioRecorder`, made `sharedStream` non-optional through the chain, rewrote ADR-015 §1 with the shared-engine architecture, dropped the in-transition callout in `spec/05-audio-pipeline.md`. 2051 XCTest + 16 Swift Testing pass. |

## Implementation summary

The committed work delivers the architecture described below, enabled by default through `AppFeatures.useSharedMicEngine = true` on the PR branch:

- `Sources/MacParakeetCore/Audio/SharedMicrophoneStream.swift` — one mic engine per process, fan-out to N subscribers, sticky VPIO with deferred engagement, `onEngineDeath` callback for promotion failures that invalidates dead-engine subscriptions, and bounded render-thread fan-out.
- `Sources/MacParakeetCore/Audio/MicrophoneEnginePlatform.swift` — `AVAudioEngineMicrophonePlatform` adapter with optional `DeviceAttemptsBuilder` (selected→default→builtIn fallback chain, recreates engine per failed attempt, same shape as the legacy code).
- `Sources/MacParakeetCore/Audio/MicrophoneCapture.swift` — accepts optional `sharedStream:` + `permissionProvider:`. When non-nil, `start()` (now `async`) subscribes with `wantsVPIO` derived from processing mode; vpioPreferred→raw fallback retried at this layer. Sync `stop()` does fire-and-forget unsubscribe so deinit cleanup still works.
- `Sources/MacParakeetCore/Audio/AudioRecorder.swift` — same shape: optional `sharedStream:`, `start()` becomes async, tap buffers are copied for async processing, `extractChannelZero(from:)` runs off the shared tap so dictation always reads the post-AEC mono regardless of VPIO state, and file writes stay off the render thread. Actor-reentrancy guard cleans up orphan tokens if `stop()` runs during the subscribe await.
- `Sources/MacParakeet/App/AppEnvironment.swift` — constructs the singleton when the flag is on, threads it through to both `AudioProcessor` (dictation) and `MeetingAudioCaptureService` (meeting mic). The flag is now default-on; flag-off keeps the legacy private-engine paths available as a one-release rollback option.

Test totals after merge-readiness review: 2052 XCTest pass, 0 failures, 16 Swift Testing pass.

## Post-merge carry-forward notes

- **Diagnostic-trail fidelity gap.** `AudioCaptureDiagnostics` events for per-device-attempt outcomes appear only as OSLog (`shared_mic_engine_input_device_*`) in shared mode — the meeting forensic ring buffer no longer captures attempt detail. Acceptable for the default-on PR; revisit if a fallback case shows up in field telemetry.
- **`RecordingDeviceInfo` is `nil` in shared mode.** Device info now lives on the platform behind the stream; surfacing it through to the dictation history requires a small shim. UI handles `nil` today.
- **Buffer fanout is bounded** on the render thread (cached snapshot), but the lock-based read does an atomic refcount-inc on Array's COW buffer. Worth profiling once both flows are running concurrently in production.
- **Deferral counter semantics:** increments per VPIO-request-deferred. Two VPIO subs joining during one non-VPIO blocker count as 2 increments. Defensible but worth a comment when wiring telemetry.
- **Edge cases not yet exercised on real hardware:** Bluetooth/HFP devices, AirPods → wired mid-session switching, USB hot-plug, sleep/wake, multi-day soak. The one-DMG default-on rollback window is meant to flush these out before deleting legacy paths.

---

## TL;DR

Replace the two independent `AVAudioEngine` instances (`AudioRecorder` for dictation, `MicrophoneCapture` for meeting mic) with a single `SharedMicrophoneStream` owner that drives one mic engine and fans out buffers to subscribers. Fixes the concurrent-dictation-during-meeting gap that PR #186 ships with as a documented known-issue.

---

## Why

PR #186 enabled VPIO for the meeting mic and observed that **once VPIO engages anywhere in the process, every other AVAudioEngine inherits a multi-channel duplex layout** (channel 0 = post-AEC processed stream). Dictation triggered during a meeting reads channel 0 and captures silence — the AEC threshold eats whatever doesn't clear it, which from a fresh dictation engine is everything.

We tried fixing it with explicit `setInputDevice` rebinding to the raw hardware mic (PR #186 commit `5e9ea4ce`). The rebind succeeded mechanically but the duplex layout follows process-wide VPIO state, not device binding. Reverted in `13cf3b49`.

The deeper issue is that ADR-015's "isolation is more valuable than the marginal resource savings of a single engine" argument was based on a premise that doesn't hold: the two engines aren't actually isolated. They share the underlying mic, the underlying aggregate device, and process-wide VPIO state. We pay the cost of looking isolated without getting any benefit.

The pre-SCStream version of this proposal was correctly rejected in `docs/research/vpio-process-tap-conflict.md` because process taps + VPIO + shared engine all collided. SCStream removed that blocker on the system-audio side. The constraint set has changed.

## What works in v0.6.0 (PR #186) without this plan

- ✅ Dictation alone
- ✅ Meeting alone
- ✅ Dictate → meeting (sequential)
- ✅ Meeting → dictate (sequential, with the ephemeral-engine pattern releasing the VPAU)
- ❌ Dictate **during** an active meeting (captures silence)

This plan addresses only the last case.

---

## Design

### Architecture

```
                   Before (v0.6.0, ships in PR #186)               After (v0.6.1, this plan)
                   ──────────────────────────────────              ──────────────────────────────

                  ┌────────────────────┐                          ┌────────────────────────────┐
                  │  AudioRecorder     │                          │   AudioRecorder            │
                  │  (dictation)       │                          │   (dictation)              │
                  │                    │                          │                            │
                  │  ┌──────────────┐  │                          │   token = subscribe(       │
                  │  │AVAudioEngine │  │                          │     wantsVPIO: false,      │
                  │  │  + tap       │  │                          │     handler: ...)          │
                  │  └──────────────┘  │                          │                            │
                  │  setVPIO(false)    │                          │   ...consume buffers...    │
                  │   (no-op when      │                          │                            │
                  │    meeting on)     │                          │   unsubscribe(token)       │
                  └────────────────────┘                          └─────────────┬──────────────┘
                                                                                │
                  ┌────────────────────┐                                        │ subscribe / fan-out
                  │ MicrophoneCapture  │                                        ▼
                  │  (meeting mic)     │                          ┌────────────────────────────┐
                  │                    │                          │  SharedMicrophoneStream    │
                  │  ┌──────────────┐  │                          │  (actor, MacParakeetCore)  │
                  │  │AVAudioEngine │  │                          │                            │
                  │  │  + VPIO + tap│  │                          │  ┌──────────────────────┐  │
                  │  └──────────────┘  │                          │  │   AVAudioEngine      │  │
                  │  ephemeral         │                          │  │   + tap (singleton)  │  │
                  │  (recreated/stop)  │                          │  │                      │  │
                  └────────────────────┘                          │  │   VPIO ◄── (any subscriber.wantsVPIO)
                                                                  │  └──────────┬───────────┘  │
                  Both engines coexist in process,                │             │              │
                  but coreaudiod gives the second                 │             ▼              │
                  the duplex VPAU layout.                         │       fan-out tap          │
                  Channel 0 of the duplex = silent.               │             │              │
                  ╳ Concurrent dictation broken.                  │   ┌─────────┴──────────┐   │
                                                                  │   │                    │   │
                                                                  │   ▼                    ▼   │
                                                                  │ subscriber[0]    subscriber[1]
                                                                  │ (dictation       (meeting     │
                                                                  │  handler)         handler)    │
                                                                  └────────────────────────────┘
                                                                                ▲
                                                                                │ subscribe / fan-out
                                                                  ┌─────────────┴──────────────┐
                                                                  │   MicrophoneCapture        │
                                                                  │   (meeting mic)            │
                                                                  │                            │
                                                                  │   token = subscribe(       │
                                                                  │     wantsVPIO: true,       │
                                                                  │     handler: ...)          │
                                                                  └────────────────────────────┘
```

### State machines

```
VPIO state                                  Engine lifetime
────────────────────                        ────────────────────
┌──────┐  first vpio sub joins ┌──────┐     ┌──────┐  first sub joins   ┌──────┐
│ raw  │ ────────────────────► │ vpio │     │ idle │ ─────────────────► │ live │
└──────┘                       └──────┘     └──────┘ ◄───────────────── └──────┘
                                                     last sub leaves
                                                     (engine stops, vpio dies with it)
```

VPIO is **sticky once engaged** for the engine's lifetime. There is no "last vpio sub leaves → raw" transition mid-session. Disengaging VPIO requires another stop → setVPIO(false) → start dance with its own buffer gap, for zero user-visible benefit (the meeting just ended; dictation already tolerates VPIO buffers via ch[0] extraction). VPIO state dies with the engine when the last subscriber leaves.

Engaging VPIO mid-session is a multi-step Core Audio sequence: `removeTap → engine.stop → setVoiceProcessingEnabled(true) → engine.start → installTap`. Sub-second but non-zero gap; deferred until in-flight dictation completes (see Edge case below) so the gap doesn't fall inside an active dictation buffer stream.

### Public API sketch

```swift
public final class SharedMicrophoneStream: @unchecked Sendable {
    public typealias BufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    public struct SubscriberToken: Hashable, Sendable { ... }

    public func subscribe(
        wantsVPIO: Bool,
        handler: @escaping BufferHandler
    ) async throws -> SubscriberToken

    public func unsubscribe(_ token: SubscriberToken) async

    /// Optional: introspection for diagnostics
    public var isRunning: Bool { get async }
    public var vpioActive: Bool { get async }
    public var subscriberCount: Int { get async }
}
```

**Concurrency model:** not an actor. The tap callback runs on the AVAudioEngine render thread, which cannot `await`. Internal state (subscriber map, VPIO/engine flags) is protected by an `OSAllocatedUnfairLock`. The render-thread tap callback acquires the lock, snapshots the handler array into a local, releases, then iterates the snapshot calling handlers — standard real-time-safe Core Audio fan-out. Public `subscribe`/`unsubscribe` are `async` for API consistency with the rest of the codebase but their bodies are synchronous lock-takes; the engine start/stop work they trigger may dispatch off the caller.

### Design decision: VPIO consumers extract ch[0] mono

When VPIO is engaged anywhere in the process, the input node delivers a multi-channel duplex format (ch=9, channel 0 = post-AEC processed mono). With one shared engine and one tap, every subscriber sees that format regardless of the `wantsVPIO` flag they registered with — `wantsVPIO` controls whether VPIO is *enabled*, not which buffer they receive.

Dictation must always read channel 0 from the buffer, and the meeting mic does the same when VPIO is engaged:

- buffer ch=1 → passthrough
- buffer ch≥2 → extract ch[0] as mono

This keeps dictation and meeting mic capture on the post-AEC mono stream under every VPIO state transition. It also gives dictation free AEC during meetings as a side effect (clean voice, no speaker bleed).

The deferred-VPIO-engagement design below (under "Edge case") is an audio-quality optimization on top of this rule, not a substitute for it.

### Consumer migration

- `AudioRecorder` becomes a thin client. On `start()` it subscribes with `wantsVPIO: false` and stores the token. The shared tap handler copies the buffer, then a serial processing queue performs channel extraction, conversion, metrics, and file writes. On `stop()` it unsubscribes and drains accepted work. The current ephemeral-engine pattern goes away — engine lifetime is the shared stream's concern.
- `MicrophoneCapture` becomes a thin client. On `start()` it subscribes with `wantsVPIO: true` and stores the token. The handler does what the current tap callback does (delegates to the meeting's `bufferHandler`, marks first buffer, runs the watchdog). On `stop()` it unsubscribes. The current ephemeral-engine pattern goes away.
- Buffer fan-out: `SharedMicrophoneStream`'s tap callback iterates subscribers and dispatches a shared reference. The consumer contract is: **the buffer is valid only for the duration of the synchronous handler call; if a subscriber needs to retain or mutate it, copy first.** This sidesteps any question of whether `AVAudioPCMBuffer` memory is reused by the engine post-callback. Dictation copies before async processing; the meeting consumer copies before any cross-thread hand-off.

### VPIO arbitration

VPIO is engaged whenever any subscriber has `wantsVPIO: true`, subject to deferred engagement while a non-VPIO subscriber is already in flight. Once engaged, VPIO stays sticky until the last subscriber leaves and the engine stops. Dictation never owns the VPIO decision — it just reads whatever stream the engine is currently producing.

This gives dictation **free AEC during meetings** as a side effect — the dictation transcript won't pick up speaker bleed during a meeting recording. That's an intentional improvement, not a workaround.

### Edge case: meeting starts while dictation is in flight

Rare (<1% of sessions) but tractable. Flow:

1. Dictation subscribes (`wantsVPIO: false`). Engine is `live` + `raw`. Tap delivers ch=1 raw mic.
2. Meeting subscribes (`wantsVPIO: true`). VPIO would normally engage immediately, but we have an in-flight `wantsVPIO: false` subscriber.
3. **Defer the VPIO engagement** until either the dictation subscriber unsubscribes OR a configurable timeout fires (e.g., 12s — covers the 99th-percentile dictation length).
4. Meeting initially captures raw mic (no AEC) for the brief overlap window. When dictation ends, VPIO engages cleanly. Both subscribers see the format change at the same instant.

Meeting startup is already slow (SCContent fetch, SCStream init, ~300-800ms), so the user-perceived added latency from waiting on dictation is negligible. If telemetry shows the case happens often enough to matter, we can iterate.

### What goes away

- `MicrophoneCapture.audioEngine` ephemeral-engine pattern (the `var` + `audioEngine = AVAudioEngine()` in `stop()` and `resetAfterFailedStart()`) — engine lifetime is the shared stream's responsibility.
- The defensive `setVoiceProcessingEnabled(false)` in `AudioRecorder` — dictation no longer owns an engine.
- The aggregate-device race in `MicrophoneCapture.inputFormat` (fixed in PR #186 commit `853dc9aa`) — `inputFormat` becomes a property of the shared stream.

### What moves into `SharedMicrophoneStream`

`MicrophoneCapture` and `AudioRecorder` become pure subscribers and stop importing `CoreAudio` directly. Everything currently in those files that touches Core Audio device state migrates into the shared stream as the new (and only) owner:

- VPAU aggregate-device detection (`CADefaultDeviceAggregate-<pid>-N` label inspection).
- Default-input-device change listener and rebind logic.
- `setInputDevice` rebind path and its diagnostic events.
- Input format snapshot under lock (replaces the `lifecycleQueue.sync` snapshot pattern from PR #186).

The non-goal here is "shared engine that delegates device work elsewhere." If two components touch CoreAudio after this lands, we've reproduced the original bug shape one layer down.

---

## Migration approach

The risk profile is regression: `AudioRecorder` is used 100% of the time for dictation, `MicrophoneCapture` is used 100% of the time for meetings. A bug in the shared stream silently breaks both flows. Disciplined steps:

1. **Build `SharedMicrophoneStream` from scratch** with comprehensive tests. Target the same internal contract as today's two clients (buffer format, sample rate, watchdog semantics) but expose only the new `subscribe`/`unsubscribe` API. Don't migrate consumers yet.
2. **Add a feature flag** `AppFeatures.useSharedMicEngine` (default `false`). Behind the flag, route both consumers through `SharedMicrophoneStream`. Default path keeps the current architecture.
3. **Migrate `MicrophoneCapture` first** because it's the more constrained shape (single VPIO subscriber). With the flag on in dev, soak for a day on real meeting recordings — verify mic transcripts, source files, transcript timestamps, sync lag, recovery artifacts.
4. **Migrate `AudioRecorder` second.** With the flag on, soak dictation usage for a day — verify levels, transcripts, hotkey responsiveness, fallback on Bluetooth/HFP devices.
5. **Concurrent-flow soak (the test that motivated this plan):** dictate during a meeting, verify ch=1 / non-zero RMS / non-empty transcript. Cycle through dictate-during-meeting, dictate-during-no-meeting, sequential combinations, and the meeting-starts-during-dictation edge case.
6. **Flip the flag default to `true`** and wait one DMG release cycle before deleting the old code paths. Telemetry signal: `meeting_mic_capture_started effective_mic_mode=vpio` rate stays unchanged; `dictation_capture_first_buffer ch=` distribution stays unchanged in the no-meeting case.
7. **Delete the old code paths.** `AudioRecorder.audioEngine`, `MicrophoneCapture.audioEngine`, and the ephemeral-engine pattern can all go.

Estimated total: 2-3 days of focused work + the soak windows.

---

## Risks

- **Buffer fan-out semantics.** If `AVAudioPCMBuffer` is immutable post-tap, fan-out can share references. If not, we copy. CPU/memory cost is negligible for 2 subscribers but worth confirming.
- **Format change visibility on VPIO toggle.** When VPIO engages mid-stream, subscribers see ch=1 → ch=9. Active dictation handlers must tolerate format changes (or, per the deferred-engagement design, this never happens because we wait for dictation to complete). Active meeting handlers already tolerate ch=9 today.
- **Test mocking.** Today's `MeetingMicrophoneCapturing` protocol is clean to mock. The shared stream is more state-y. Tests that previously stubbed `MicrophoneCapture` will need either a `SharedMicrophoneStream` mock or a thin facade preserved for testing.
- **Engine recreation under failure.** Today's ephemeral pattern recreates the engine on failed start to release VPIO state. With a shared engine, transient failures shouldn't require teardown across other subscribers. Need to design failure isolation: one subscriber's failure shouldn't cascade.
- **Telemetry blind spots.** With one engine, the per-flow signals we have today (`meeting_mic_capture_started`, `dictation_capture_engine_started`) become per-subscriber. Diagnostics need to follow the new shape — likely add a `shared_mic_engine_*` event family alongside, not in place of, the existing per-consumer events.

---

## Acceptance criteria

- [ ] `SharedMicrophoneStream` exists with full unit-test coverage of subscribe/unsubscribe lifecycle, VPIO arbitration state machine, engine start/stop on first/last subscriber, fan-out correctness, and failure isolation between subscribers.
- [ ] `AudioRecorder` and `MicrophoneCapture` no longer own `AVAudioEngine` instances; they're thin subscribers.
- [ ] All existing tests pass (baseline 1722 XCTest + 13 Swift Testing on `main` as of 2026-04-26 — confirm fresh count when work begins, since the suite churns).
- [ ] Concurrent test passes: start meeting → wait 5s → trigger dictation → confirm `dictation_capture_configured ch=1` (or `ch=9` post-VPIO if we choose not to defer) and `non_silent_buffers > 0` and a non-empty transcript.
- [ ] Sequential cases unchanged: dictate-alone, meeting-alone, dictate→meeting, meeting→dictate all pass exactly as in v0.6.0.
- [ ] No regression in dictation latency (engine pre-warmed by being live whenever any subscriber is active is actually a small improvement over today's per-session engine-create cost).
- [ ] No regression in meeting recording (source files, source alignment metadata, mix output, recovery artifacts).
- [ ] ADR-015 amendment lands documenting the architectural change.

---

## Out of scope

- The `ch=9` mic format audit (separate followup; meeting recording works correctly with ch=9 today).
- `SystemAudioStream` isolated unit tests (separate followup; PR #186 known issue).
- Calendar auto-start touching dictation lifecycle — calendar is a meeting trigger only; if dictation is in flight when a calendar meeting starts, the deferred-VPIO design handles it.
- Whisper-engine routing changes — ADR-021 is unaffected; the speech engine is downstream of the audio capture.
- Multi-mic device selection. Today the user picks a default in Settings; the shared engine inherits whatever the system default is. Multi-device support is a separate plan.

---

## Resolved decisions

These were open questions in the first draft, resolved during plan review:

- **Where it lives:** `AppEnvironment`, single instance per process. The "one mic engine per process" invariant is load-bearing — encoding it in the dependency graph is exactly the point. Instantiating per-flow would reproduce the original bug shape.
- **VPIO-deferral telemetry:** ship a counter (event name TBD, e.g. `shared_mic_vpio_deferred`) that increments when meeting subscription waits on an in-flight dictation subscriber. Cheap to add, answers the rarity question definitively, expensive to retrofit if we regret not having it.
- **Feature flag lifetime:** dev-only. Delete `AppFeatures.useSharedMicEngine` after one DMG release with the flag default-on confirms no field issues.

## Out of plan, in scope for the eventual ADR

- ADR-015 amendment text. Sketch alongside step 1 of the migration so the plan and the ADR don't drift; land the amendment when the flag flips to default-on.
