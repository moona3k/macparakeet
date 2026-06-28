# STT

> One process-wide speech-to-text control plane. Parakeet (FluidAudio /
> CoreML) is default, with v3 multilingual as the default build, v2
> English-only and Parakeet Unified (English-only, punctuated offline output
> plus native live dictation partials)
> as opt-in Parakeet variants; Nemotron is an opt-in Beta
> engine with two builds — multilingual (Nemotron 3.5, default) and an
> English-only streaming build (Nemotron Speech Streaming EN 0.6B);
> WhisperKit is optional for broad language coverage; Cohere Transcribe is an
> opt-in batch-only accuracy engine.

## Entry point

`STTScheduler` — the public actor every feature submits work to.
Owns slot assignment, queueing, priority, backpressure, cancellation,
and progress fan-out. App code reaches it as
`AppEnvironment.sttScheduler`. The scheduler delegates model lifecycle
to one `STTRuntime`; callers do not own model lifecycles directly.

## What's here

**Speech control plane**
- `STTScheduler.swift` — public broker. Job admission, slot scheduling,
  engine routing, session leases for active meetings, and Cohere's
  scheduler-level single-flight admission.
- `STTRuntime.swift` — sole owner of the Parakeet TDT `AsrManager`s, the
  optional `ParakeetUnifiedEngine` (routed when the persisted
  `ParakeetModelVariant` is `.unified`), the optional Beta
  `NemotronEngine`/`NemotronEnglishEngine` pair (routed by the persisted
  `NemotronModelVariant`), the optional `WhisperEngine`, and the optional
  `CohereTranscribeEngine`. Handles warm-up, model init, cache clearing,
  shutdown, and Parakeet/Nemotron build swaps.
- `STTClient.swift` + `STTClientProtocol.swift` — **CLI / test
  facade only**. Each `STTClient` instantiates its own runtime and
  scheduler, bypassing the process singleton. App code must use the
  shared scheduler from `AppEnvironment`.
- `STTResult.swift` — value type returned by every transcribe call
  (text, word-level timing, optional detected language, the engine
  that produced the result, and an optional engine-specific model
  variant).
- `ParakeetUnifiedEngine.swift` — FluidAudio `UnifiedAsrManager` +
  `StreamingUnifiedAsrManager` wrapper for NVIDIA Parakeet Unified EN 0.6B
  (English-only, int8). Selected when `ParakeetModelVariant == .unified`.
  File, meeting, and recorded-file dictation use FluidAudio's overlapping 15 s
  offline batch transcription (`parakeet-unified-offline-15s`) because that is
  the best stop-time quality path. Live dictation uses the native low-latency
  streaming build (`parakeet-unified-2080ms`) to emit partials while capture is
  active. No word timings; `language` fixed to `en`.
- `WhisperEngine.swift` — WhisperKit wrapper conforming to the same
  shape as the Parakeet path.
- `NemotronEngine.swift` — FluidAudio Nemotron 3.5 wrapper for the
  Beta local multilingual engine. Uses separate interactive/background
  managers backed by shared model weights so it fits the scheduler lanes.
  Preserves FluidAudio token timings as MacParakeet word timestamps when
  available.
- `NemotronEnglishEngine.swift` — FluidAudio Nemotron Speech Streaming
  EN 0.6B wrapper (English-only Beta build, `english-1120ms`). Same
  two-lane shape; no language hints, no shared-weights API (both lanes
  load the same compiled artifacts). File/meeting jobs feed batch-at-stop
  through the streaming manager in bounded slices; live dictation drives
  the same manager incrementally and emits partials (see below). Preserves
  FluidAudio token timings as MacParakeet word timestamps when available.
- `CohereTranscribeEngine.swift` — FluidAudio Cohere Transcribe wrapper.
  Batch-only: dictation records first and transcribes after stop, file and
  meeting-finalize jobs run offline, live dictation preview stays off, and
  meeting live preview chunks are not routed to Cohere. No word timings;
  meetings degrade to plain text. Loads only an explicitly downloaded model
  cache; it does not download from normal transcription/warm-up paths. Its
  CoreML model has a large runtime footprint, so Settings gates both selecting
  Cohere and downloading its model to machines with at least
  `EngineSettingsViewModel.cohereMinimumMemoryBytes` (16 GB) of RAM.
- `NativeLiveDictating.swift` — internal protocol the native streaming engines
  conform to so `STTRuntime` can route a live dictation session to the active
  Nemotron or Parakeet Unified build without knowing the concrete engine type.

**Hotkey state (lives here for testability)**
- `FnKeyStateMachine.swift` — pure state machine for legacy combined
  dictation gestures and shared timing constants.
- `HotkeyGestureController.swift` — wraps the state machine for the
  app's hotkey driver and scopes behavior to combined, hands-free-only,
  or push-to-talk-only roles.
- `HotkeyTrigger.swift` — value types describing trigger kinds.
- `KeyCodeNames.swift` — display strings for keys, plus the
  function-family classification used to tell a genuinely held Fn
  modifier from the phantom `.function` flag macOS sets on F-key,
  arrow, and nav-cluster presses.
- `OnboardingProgressParser.swift` — parses FluidAudio model-download
  progress lines for the onboarding UI.

These hotkey/onboarding files live in `STT/` because they were
originally tied to the dictation start path and need to be in
`MacParakeetCore` for cross-target test access. Folder naming is a
minor historical wart, not a design statement.

## Cross-references

- ADR-001 — Parakeet TDT 0.6B-v3 as primary/default STT, amended to expose
  v2 English-only as an opt-in Parakeet build.
- ADR-007 — FluidAudio CoreML migration; Parakeet runs on the Apple
  Neural Engine via CoreML.
- ADR-016 — centralized STT runtime + 2-slot scheduler; this folder
  is the implementation.
- ADR-021 — WhisperKit as optional multilingual engine; engine
  routing and meeting engine leases live in `STTScheduler`.
- ADR-001 amendment / benchmark notes — Cohere Transcribe as an opt-in local
  accuracy engine.
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

**Meeting stop does not create a second ASR lane.** Back-to-back meeting
recording is implemented by returning the recorder to idle after the stopped
meeting's audio files, `awaitingTranscription` lock, and processing Library row
are durable. The queued final STT still enters the shared background slot as
`meetingFinalize`. If a file, folder, YouTube, podcast, or media URL
transcription is already running, it is not preempted; the stopped meeting
waits for that job to finish. Once the slot is free, `meetingFinalize` outranks
queued `fileTranscription` work. URL download and metadata extraction do not
occupy STT; only the post-download transcription job does.

**Native live dictation sessions (Nemotron and Parakeet Unified).** When the
selected engine is Nemotron — either build, multilingual or English-only — or
Parakeet with the `.unified` variant, dictation can hold a live streaming
session via `beginLiveDictationTranscription` / `appendLiveDictationSamples` /
`finishLiveDictationTranscription` / `cancelLiveDictationTranscription`. The
runtime routes the session to the active native streaming build through
`NativeLiveDictating`.
The session owns the interactive slot for its duration: competing
dictation transcribe jobs are rejected with `engineBusy`, engine-switch
availability reports `transcribing`, and quiesce/shutdown cancels the
session (or waits out an in-flight finish). Meeting live chunks and
finalize are unaffected — they stay on the background slot.
`DictationService` always records the WAV alongside the live stream and uses
recorded-file transcription for the final paste/history result. Native live
partials remain display-only; if the live stream fails, drops samples, or
finishes empty, only the preview is degraded.

**Display-only dictation preview (Parakeet/Whisper-capable path).**
Dictation can request a single-flight tail-window preview via
`transcribeDictationPreview`. This does not reserve a scheduler slot and
does not replace the recorded-file final transcript; it is only for the
floating overlay text while capture is active. Parakeet v2/v3 use this
tail-window batch preview; Parakeet Unified and Nemotron use native streaming
partials instead, and Whisper and Cohere remain default-off. Engine switches, variant
switches, and dictation stop/cancel paths cancel the preview with bounded drain.
If a cancelled preview still has runtime work in flight, engine/variant switches
fail fast with `engineBusy` rather than reloading under active inference; the
final paste path still proceeds after its bounded display-preview drain. Runtime
quiesce paths such as shutdown and cache clear wait for preview drain under the
unhealthy-runtime watchdog before unloading or clearing model state.

**Dictation finalize pads trailing silence (issue #562).** The Parakeet TDT
final pass for `job == .dictation` decodes the recorded WAV to 16 kHz mono
samples, appends `dictationTrailingSilenceSeconds` of silence, and transcribes
through the samples API instead of `manager.transcribe(audioURL:)`. Without the
pad the TDT decoder can drop a fast final word that lands right on the end of
the recording even though the audio was captured. FluidAudio's own fixed-size
input padding does not help because the decode is bounded to the real (pre-pad)
audio length, so only *real* trailing samples extend the decode window. This is
scoped deliberately: the pad path is taken only for short clips that fit
FluidAudio's single-window tier (`maxModelSamples`); longer dictations and
file/meeting jobs keep the URL path (FluidAudio disk-backs long audio for
constant memory), and Whisper is never padded (trailing silence can trigger
hallucinated text). Decode/pad preparation is best-effort: an unreadable,
empty, or too-long clip yields no samples and falls through to the URL path, while
transcription errors propagate from whichever path ran. Don't "simplify"
dictation back onto the shared URL path without restoring this trailing context.

**All Parakeet TDT inference is gated.** The pad, URL, and preview paths each
wrap their `AsrManager.transcribe(...)` in `inferenceGate.withExclusiveAccess`,
which serializes Neural Engine inference on macOS 14 (`ANEInferenceGate`; a no-op
on macOS 15+) to avoid the concurrent-inference SIGBUS (FluidAudio #661). The gate
is applied inline at each site rather than via a shared helper because the closure
captures the actor-owned, non-Sendable `AsrManager`, which Swift 6 only lets the
gate close over inline. A new call site that invokes `AsrManager.transcribe`
directly **must** wrap it the same way — calling the manager bare reopens the
crash for whichever lane runs unguarded.

**Engine routing is per-job.** Parakeet stays default. The selected Parakeet
build is `v3` unless the user opts into `v2` through Settings or the CLI
(`config set parakeet-model`, `models select parakeet-v2`, or
`transcribe --parakeet-model v2`). A subscriber can request Nemotron or
WhisperKit or Cohere globally (Settings / `models select`) or per call (CLI
`--engine nemotron --language ko`, `--engine cohere --language ja`,
`--engine whisper --language ko`). When set globally, dictation also routes
there; when set per-job, only that job uses the requested engine. Cohere
dictation remains record-then-transcribe and does not enter live-preview paths.

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
  `swift run macparakeet-cli transcribe --engine nemotron --language ja
  /path/to/japanese.m4a` and
  `swift run macparakeet-cli transcribe --engine whisper --language ja
  /path/to/japanese.m4a`, then confirm the requested engine is used.
