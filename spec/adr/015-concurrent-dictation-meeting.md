# ADR-015: Concurrent Dictation and Meeting Recording

> Status: ACCEPTED
> Date: 2026-04-06
> Related: ADR-014 (meeting recording), ADR-009 (custom hotkeys), ADR-016 (centralized STT runtime and scheduler), [GitHub #57](https://github.com/moona3k/macparakeet/issues/57)
> Amended by: ADR-016 for STT runtime ownership, scheduling, and backpressure policy

## Context

ADR-014 introduced meeting recording as a third co-equal mode. The initial implementation mutually excludes dictation and meeting recording — starting one blocks the other. This was a simplifying constraint for MVP, but it conflicts with the product vision: a user in a 45-minute meeting recording should still be able to press their dictation hotkey to quickly dictate a Slack message.

Both flows need microphone access, both use the Parakeet STT engine, both display UI elements (pills/overlays), and both own menu bar icon state. The question is whether they can run concurrently in a reliable, architecturally clean way.

## Decision

### Dictation and meeting recording run concurrently as fully independent pipelines

There is no mutual exclusion. A user can start a meeting recording, then use dictation as many times as they want during the meeting. Both flows operate independently with no shared mutable state between them.

### 1. Independent AVAudioEngine instances (no shared audio engine)

Each flow owns its own `AVAudioEngine` instance:

| Flow | Audio Engine | Tap |
|------|-------------|-----|
| Dictation | `AudioRecorder.audioEngine` | `inputNode.installTap(onBus: 0)` |
| Meeting (mic) | `MicrophoneCapture.audioEngine` | `inputNode.installTap(onBus: 0)` |
| Meeting (system) | `SystemAudioTap` | Core Audio Taps (separate from AVAudioEngine) |

macOS Core Audio's Hardware Abstraction Layer (HAL) natively multiplexes microphone access across multiple clients. Multiple `AVAudioEngine` instances tapping the same physical mic is a supported, documented pattern — it's how multiple apps can record simultaneously.

**Why not a shared engine?** Dictation and meeting recording have fundamentally different lifecycles:

- Dictation: burst (3-10 seconds), starts/stops rapidly, engine created and destroyed per session
- Meeting: sustained (minutes-hours), engine runs continuously for the entire session

A shared engine would mean dictation start/stop could glitch a long-running meeting recording. Isolation is more valuable than the marginal resource savings of a single engine.

### 2. Shared STT runtime with explicit scheduling

Both flows submit STT work to a process-wide STT scheduler backed by one shared `STTRuntime` owner. Feature services do not own their own runtimes and the app does not rely on implicit CoreML contention as its scheduling policy.

The scheduler defines:

- a reserved dictation slot for the highest-priority interactive workload
- a shared background slot where meeting finalization beats live preview work
- meeting live chunks as best-effort under backlog
- file / YouTube transcription and saved-meeting retranscribes as queued batch work behind active meeting STT

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
- macOS handles mic multiplexing natively
- STT ownership can remain centralized even while audio capture stays independent

### Negative

- Slightly higher resource usage during concurrent operation (two AVAudioEngine instances)
- Edge case: single-channel USB mic with limited format support could theoretically conflict between two engines (mitigated by macOS HAL resampling)
- Menu bar icon can only show one state — user must infer meeting is still recording from the meeting pill when dictation is briefly active

### Risk assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Mic format conflict | Very low | Medium | macOS HAL handles resampling; test with USB mics |
| STT queue starvation | Low | Medium | Explicit scheduler and backpressure policy in ADR-016 |
| UI layer collision | Low | Low | NSPanel z-ordering is deterministic |
| Meeting audio glitch during dictation start | Very low | High | Independent engines prevent cross-contamination |
