# ADR-015: Concurrent Dictation and Meeting Recording

> Status: ACCEPTED
> Date: 2026-04-06
> Related: ADR-014 (meeting recording), ADR-009 (custom hotkeys), ADR-016 (centralized STT runtime and scheduler), [GitHub #57](https://github.com/moona3k/macparakeet/issues/57), [PR #189](https://github.com/moona3k/macparakeet/pull/189)
> Amended by: ADR-016 for STT runtime ownership, scheduling, and backpressure policy
> Amendment note (2026-04-10): meeting mic capture remains raw at device tap time; echo mitigation is applied in meeting-only joined software-AEC processing while dictation remains raw. Concurrency isolation remains unchanged.
> Amendment note (2026-04-29, superseded 2026-04-30): meeting system audio moved from Core Audio process taps to ScreenCaptureKit audio, and meeting mic capture now prefers VPIO. Dictation remained raw on its independent `AVAudioEngine` until the shared-engine amendment below replaced that topology.
> Amendment note (2026-04-30): the original "independent AVAudioEngine instances" decision was incompatible with VPIO. coreaudiod attaches the VPAU aggregate device to the **process**, not the engine, so once meeting recording engaged VPIO, every other `AVAudioEngine` in the process inherited the multi-channel duplex layout — and dictation read silence on channel 0 of the wrong layout. Section 1 is rewritten below to describe the shared-engine architecture that ships in v0.6 (PR #189). The rest of the ADR (STT scheduler, menu bar priority, UI layers, hotkey, audio semantics) is unchanged.
> Amendment note (2026-05-14): shipped meeting mic capture returns to raw by default after live-call testing showed VPIO can muffle the user's outgoing mic for other participants. The shared-engine architecture and VPIO arbitration remain for explicit VPIO experiments.
> Amendment note (2026-06-02): optional Instant Dictation keeps a passive warm subscriber on `SharedMicrophoneStream` while dictation is idle and stores only a bounded in-memory pre-roll. Passive subscribers do not block VPIO promotion; active dictation and raw meeting capture still do.

## Context

ADR-014 introduced meeting recording as a third co-equal mode. The initial implementation mutually excludes dictation and meeting recording — starting one blocks the other. This was a simplifying constraint for MVP, but it conflicts with the product vision: a user in a 45-minute meeting recording should still be able to press their dictation hotkey to quickly dictate a Slack message.

Both flows need microphone access, both use the Parakeet STT engine, both display UI elements (pills/overlays), and both own menu bar icon state. The question is whether they can run concurrently in a reliable, architecturally clean way.

## Decision

### Dictation and meeting recording run concurrently as fully independent pipelines

There is no mutual exclusion. A user can start a meeting recording, then use dictation as many times as they want during the meeting. Both flows operate independently with no shared mutable state between them.

### 1. Shared microphone engine, independent system audio

Microphone capture is owned by a process-wide `SharedMicrophoneStream`. Both flows subscribe and receive every buffer; system audio remains a separate ScreenCaptureKit pipeline owned by the meeting flow.

| Flow | Audio Source | Subscription |
|------|--------------|--------------|
| Dictation | `SharedMicrophoneStream` | `subscribe(wantsVPIO: false)` |
| Instant Dictation warm lease | `SharedMicrophoneStream` | `subscribe(wantsVPIO: false, blocksVPIOPromotion: false)` while enabled and idle |
| Meeting (mic) | `SharedMicrophoneStream` | `subscribe(wantsVPIO: false)` by default; explicit VPIO requests still use shared arbitration |
| Meeting (system) | `SystemAudioStream` (ScreenCaptureKit `SCStream`) | independent of mic engine |

The shared stream owns one `AVAudioEngine`, manages VPIO engagement, fans buffers out to all subscribers, and tears down only when the last subscriber leaves. Subscribers receive the same buffer; both flows' downstream copies are isolated.

**Why a shared engine is required (not optional):**

macOS Voice Processing I/O (VPIO) provides built-in echo cancellation, noise suppression, and AGC, and remains useful for explicit experiments. VPIO is engaged by enabling voice processing on an `AVAudioEngine`'s input node, which causes `coreaudiod` to attach a VPAU aggregate device (`CADefaultDeviceAggregate-<pid>-N`) to the **process**. The aggregate then routes audio for every `AVAudioEngine` in the process — including a separately-allocated dictation engine, whose `inputNode.outputFormat(forBus: 0)` queries return the VPAU's multi-channel duplex layout (typically `ch=9`) instead of the raw mic format. Channel 0 carries the post-AEC processed mono; the rest are reference / loopback channels. A dictation engine that doesn't know about the duplex layout reads channel 0 of *something else* (or applies default channel reduction and dilutes the AEC), which manifests as silent transcripts during meetings.

Two independent `AVAudioEngine` instances cannot escape this — VPIO state is process-scoped, not engine-scoped. The shared-engine design accepts this and exploits it: subscribers explicitly request VPIO or raw, the stream resolves the engine's actual mode (sticky once engaged, deferred when a non-VPIO subscriber blocks), and every subscriber that consumes audio while VPIO is engaged extracts channel 0 as mono. See `Sources/MacParakeetCore/Audio/SharedMicrophoneStream.swift` and `extractChannelZero(from:)` in `AudioRecorder.swift` for the implementation.

**Why a shared engine is also fine for lifecycle:** the original ADR worried that a long-running meeting engine would glitch when dictation start/stop touched it. In practice, dictation `subscribe`/`unsubscribe` calls are buffer-fanout list mutations behind a lock — they don't touch the running `AVAudioEngine`, don't reconfigure VPIO, and don't restart the engine. The engine starts on the first subscriber and stops on the last; mid-session subscribers join an already-running engine.

Instant Dictation keeps that same topology. Its idle warm lease is passive:
it can keep the engine running and maintain a small RAM-only pre-roll, but it
is not a user-visible capture session. If an explicit VPIO subscriber arrives
while only the warm lease is present, the shared stream may promote to VPIO
immediately. If active raw dictation or raw meeting capture is present, the
existing deferral rule still protects that live session from a mid-stream
format flip.

### 2. Shared STT runtime with explicit scheduling

Both flows submit STT work to a process-wide STT scheduler backed by one shared `STTRuntime` owner. Feature services do not own their own runtimes and the app does not rely on implicit CoreML contention as its scheduling policy.

The scheduler defines:

- a reserved dictation slot for the highest-priority interactive workload
- a shared background slot where meeting finalization beats live preview work
- meeting live chunks as best-effort under backlog
- file / YouTube transcription and legacy saved-meeting fallbacks as queued batch work behind active meeting STT
- saved meetings with archived source metadata reuse the higher-priority meeting-finalization path instead of the generic mixed-file path

See ADR-016 for the full runtime and scheduler design.

### 3. Priority-based menu bar icon

Both flows update the menu bar icon. A priority aggregator resolves conflicts:

```
Priority (highest → lowest):
1. Meeting recording active  →  recording indicator
2. Dictation active          →  recording indicator
3. File transcription        →  processing indicator
4. Idle                      →  default icon
```

The aggregator is a stateless function that checks all flow states and returns the highest-priority icon. It replaces the current direct `updateMenuBarIcon()` calls from each flow.

### 4. Independent UI layers

All UI surfaces are independent `NSPanel` instances with no z-order conflicts:

| Surface | When Visible | Layer |
|---------|-------------|-------|
| Idle pill | Neither flow active | `.floating` |
| Dictation overlay | During dictation | `.floating` (above idle pill) |
| Meeting pill | During meeting recording | `.floating` |
| Meeting panel | User-opened during meeting | `.floating` |

During concurrent operation:
- Idle pill is hidden (either flow active)
- Meeting pill remains visible
- Dictation overlay appears on top during dictation, disappears when done
- Meeting pill stays visible underneath — the meeting is still recording

### 5. Hotkey conflict prevention (already solved)

`HotkeyRecorderView.additionalValidation` prevents assigning the same hotkey to both dictation and meeting recording. At runtime, `GlobalShortcutManager` ensures distinct hotkeys map to distinct handlers. No change needed.

### 6. Audio semantics are correct without deduplication

During concurrent operation, the user's dictation speech appears in both streams:
- **Dictation** captures it → STT → paste to clipboard (correct — that's what the user said)
- **Meeting mic** captures it → appears in meeting transcript (correct — the user spoke during the meeting)

No deduplication is needed. Both representations are semantically accurate.

## Implementation

### Remove mutual exclusion and preserve idle pill suppression

1. `DictationFlowCoordinator.startDictation()` — remove `guard !isMeetingRecordingActive()` check
2. `AppDelegate.toggleMeetingRecording()` — remove `guard dictationFlowCoordinator?.isDictationActive != true` check and `presentMeetingRecordingBlockedAlert()`
3. `DictationFlowCoordinator` — rename the `isMeetingRecordingActive` closure to `shouldSuppressIdlePill`, keep it for idle pill suppression, and guard `showIdlePill()` so the idle pill does not reappear while meeting recording is active

### Add MenuBarIconAggregator

A lightweight function (not a new class) that replaces direct `updateMenuBarIcon()` calls:

```swift
private func resolveMenuBarIcon() -> BreathWaveIcon.MenuBarState {
    if meetingRecordingFlowCoordinator?.isMeetingRecordingActive == true { return .recording }
    if dictationFlowCoordinator?.isDictationActive == true { return .recording }
    if transcriptionViewModel.isTranscribing { return .processing }
    return .idle
}
```

Both flows call `resolveMenuBarIcon()` instead of directly setting their state.

### Adjust idle pill visibility

Idle pill hides when either flow is active, shows when both are idle.

## Consequences

### Positive

- Users can dictate freely during meetings — the primary use case
- No architectural coupling between the two flows
- One process-wide `AVAudioEngine` instead of two — fewer Core Audio resources, no cross-engine VPIO contention
- STT ownership can remain centralized even while audio capture is fanned out per-subscriber

### Negative

- Buffer fan-out runs on the audio render thread; subscribers must do only lightweight work in their handlers (the stream's documented contract is "copy and dispatch off-thread for anything heavier"). `AudioRecorder` honours this by copying the tap buffer and processing on a serial userInitiated queue
- Device info from the platform is not yet plumbed through to dictation telemetry — `recordingDeviceInfo` is `nil` for shared-stream recordings (tracked as follow-up)
- Menu bar icon can only show one state — user must infer meeting is still recording from the meeting pill when dictation is briefly active

### Risk assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| VPIO duplex layout misread by a subscriber | Low | High | `extractChannelZero(from:)` is the design rule; centralized in shared code |
| Slow handler blocks the audio render thread | Low | High | Subscribers copy + dispatch; documented in stream's `BufferHandler` contract |
| STT queue starvation | Low | Medium | Explicit scheduler and backpressure policy in ADR-016 |
| UI layer collision | Low | Low | NSPanel z-ordering is deterministic |
| Engine death mid-session | Low | High | `onEngineDeath` callbacks notify subscribers; meeting/dictation surface as stall errors |
