# STT

> One process-wide speech-to-text control plane. Parakeet (FluidAudio /
> CoreML) is default; WhisperKit is optional for languages outside
> Parakeet's coverage.

## Entry point

`STTScheduler` — the public actor every feature submits work to.
Owns slot assignment, queueing, priority, backpressure, cancellation,
and progress fan-out. App code reaches it as
`AppEnvironment.sttScheduler`. The scheduler delegates model lifecycle
to one `STTRuntime`; callers do not own model lifecycles directly.

## What's here

**Speech control plane**
- `STTScheduler.swift` — public broker. Job admission, slot scheduling,
  engine routing, session leases for active meetings.
- `STTRuntime.swift` — sole owner of the Parakeet `AsrManager`s and
  the optional `WhisperEngine`. Handles warm-up, model init, cache
  clearing, shutdown.
- `STTClient.swift` + `STTClientProtocol.swift` — **CLI / test
  facade only**. Each `STTClient` instantiates its own runtime and
  scheduler, bypassing the process singleton. App code must use the
  shared scheduler from `AppEnvironment`.
- `STTResult.swift` — value type returned by every transcribe call
  (text, word-level timing, optional detected language, the engine
  that produced the result, and an optional engine-specific model
  variant).
- `WhisperEngine.swift` — WhisperKit wrapper conforming to the same
  shape as the Parakeet path.

**Hotkey state (lives here for testability)**
- `FnKeyStateMachine.swift` — pure state machine for combined
  dictation gestures (double-tap → persistent, hold → push-to-talk,
  Esc → cancel window).
- `HotkeyGestureController.swift` — wraps the state machine for the
  app's hotkey driver and scopes behavior to combined, hands-free-only,
  or push-to-talk-only roles.
- `HotkeyTrigger.swift` — value types describing trigger kinds.
- `KeyCodeNames.swift` — display strings for keys.
- `OnboardingProgressParser.swift` — parses FluidAudio model-download
  progress lines for the onboarding UI.

These hotkey/onboarding files live in `STT/` because they were
originally tied to the dictation start path and need to be in
`MacParakeetCore` for cross-target test access. Folder naming is a
minor historical wart, not a design statement.

## Cross-references

- ADR-001 — Parakeet TDT 0.6B-v3 as primary STT.
- ADR-007 — FluidAudio CoreML migration; Parakeet runs on the Apple
  Neural Engine via CoreML.
- ADR-016 — centralized STT runtime + 2-slot scheduler; this folder
  is the implementation.
- ADR-021 — WhisperKit as optional multilingual engine; engine
  routing and meeting engine leases live in `STTScheduler`.
- ADR-009 — custom hotkey support (relevant to the hotkey files
  above).
- `spec/06-stt-engine.md` — narrative spec.
- Audio buffers feeding the scheduler: `../Audio/`.

## What to know before editing

**One scheduler per process.** ADR-016 is non-negotiable. App code
gets `STTScheduler` from `AppEnvironment`. Never instantiate
`STTRuntime`, `STTScheduler`, or `STTClient` from a feature service
— that fragments the control plane and breaks admission control.
The lone exception is `STTClient`, which is intentionally
self-contained for the CLI and tests.

**Two execution slots, four job classes.** The scheduler exposes
`dictation`, `meetingFinalize`, `meetingLiveChunk`, and
`fileTranscription`. Dictation has its own reserved slot so
interactive latency is preserved. The other three share a
background slot, with explicit priority: meeting finalize
> meeting live chunk > file transcription. Backpressure on the
shared slot drops the lowest-priority pending work.

**Engine routing is per-job.** Parakeet stays default. A subscriber
can request WhisperKit globally (Settings) or per call (CLI
`--engine whisper --language ko`). When set globally, dictation
also routes there; when set per-job, only that job uses Whisper.

**Active meetings hold an engine lease.** Once a meeting recording
starts, its engine selection is captured for the session's duration.
Engine switching is blocked while the lease is held — switching
mid-meeting would split a single recording across two engines'
output formats, which the transcript assembler does not support.
The lease releases when the meeting stops or recovery completes.

**Model lifecycle is the runtime's job, not yours.** Don't call
`AsrManager` directly from app code, don't `Task { try await
manager.initialize() }`, and don't reach into `STTRuntime`'s
private state. Warm-up happens automatically (background or
explicit); use `STTRuntime.observeWarmUpProgress()` to surface UI.

**Hotkey state is pure and testable.** `FnKeyStateMachine` and
`HotkeyGestureController` take abstract gesture events with timestamps
and emit actions. Don't add CGEvent or NSEvent imports here — that
machinery lives in the GUI target's `Hotkey/` folder and translates
real events into the controller's input shape.

## How to verify a change

- `swift test --filter STT` — scheduler, runtime, slot ordering,
  backpressure, engine routing, lease semantics.
- `swift test --filter FnKeyStateMachine` — gesture state machine.
- `swift test` — full suite (~100 s). STT changes ripple through
  dictation and meeting recording tests.
- Manual: dev-app smoke covering all four job classes — dictate
  during a file transcription (file work should yield to
  dictation), start a meeting and dictate during it, kick off a
  long file transcription and confirm cancellation works mid-job.
- For engine routing: run the CLI
  `swift run macparakeet-cli transcribe --engine whisper --language ja
  /path/to/japanese.m4a` and confirm Whisper is used.
