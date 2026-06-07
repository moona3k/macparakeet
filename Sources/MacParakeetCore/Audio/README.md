# Audio

> One mic engine per process, fanned out to dictation and meeting
> recording. This folder owns capture, format conversion, and on-disk
> diagnostic logging.

## Entry point

`SharedMicrophoneStream` — the process-wide microphone source. Every
consumer (dictation, meeting mic) calls
`subscribe(wantsVPIO:onEngineDeath:handler:)` and receives every
buffer. The stream owns engine lifecycle, VPIO arbitration, and
fan-out. There is exactly one instance per process, owned by
`AppEnvironment`.

## What's here

**Shared mic engine (the core of this folder)**
- `SharedMicrophoneStream.swift` — fan-out, VPIO state machine,
  subscriber tokens, `Diagnostics` snapshot. ADR-015 + ADR-016.
- `MicrophoneEnginePlatform.swift` — `AVAudioEngine` wrapper. Device
  fallback chain, VPIO toggle, tap install, engine recreation on
  every teardown (so coreaudiod releases the VPAU aggregate
  device), `AVAudioEngineConfigurationChangeNotification` observer.

**Mic consumers (each subscribes to the shared stream)**
- `AudioRecorder.swift` — dictation capture.
  `subscribe(wantsVPIO: false)`. Writes 16 kHz mono Float32 WAVs to
  `$TMPDIR/macparakeet/`. Owns the dictation diagnostic timers
  (first-buffer watchdog + recording heartbeat).
- `MicrophoneCapture.swift` — meeting microphone capture. Subscribes
  with `wantsVPIO: false` by default via `MeetingMicProcessingMode.raw`.
  VPIO modes remain available for explicit experiments, with raw fallback
  when `.vpioPreferred` cannot engage. Has its own silent-buffer watchdog
  with a stall observer wired up to the meeting flow.

**Meeting-side audio (independent of the mic stream)**
- `SystemAudioStream.swift` — meeting system audio via
  `ScreenCaptureKit` (`SCStream`). Independent of the
  `AVAudioEngine`. Has its own first-buffer watchdog.
- `MeetingAudioCaptureService.swift` — composes mic + system audio
  for meeting recording.
- `MeetingAudioStorageWriter.swift` — fragmented MP4 writer for
  meeting source files (ADR-019 crash recovery).
- `MeetingAudioError.swift`, `MeetingMicProcessingMode.swift` —
  value types.

**Helpers**
- `AudioCaptureDiagnostics.swift` — public `append(_:)` to
  `~/Library/Logs/MacParakeet/dictation-audio.log`. 5 MB cap;
  delete-on-overflow (not rotated). Used by every file in this
  folder and by `AppDelegate`'s boot marker.
- `AudioChunker.swift` — actor that buffers resampled audio for
  incremental STT (live meeting transcription).
- `MeetingLiveAudioChunking.swift`,
  `SpeechBoundaryMeetingLiveAudioChunker.swift`,
  `MeetingVADChunkingSimulator.swift` — meeting live-preview chunking
  strategies. The fixed adapter preserves the original 5s / 1s-overlap
  cadence; the VAD strategy cuts cached-model Parakeet sessions at
  speech boundaries and falls back to fixed on VAD errors.
- `AudioFileConverter.swift` — file-side converter (FFmpeg /
  AVFoundation) for file/YouTube/meeting transcription inputs.
- `AudioProcessor.swift` + `AudioProcessorProtocol.swift` — thin
  facade composing `AudioRecorder` + `AudioFileConverter` behind a
  single protocol. Useful where a caller wants both the dictation
  and file-conversion entry points behind one injection seam.
- `AudioDeviceManager.swift` — Core Audio HAL helpers (default
  device, set input on engine, list devices).
- `extractChannelZero` (in `AudioRecorder.swift`),
  `CMSampleBufferToPCMBuffer.swift`, `PCMBufferToSampleBuffer.swift`,
  `UncheckedSendableAudioPCMBuffer.swift`,
  `ObjCExceptionBridge.swift` — pure utilities.

## Cross-references

- ADR-014 — meeting recording (system + mic dual stream, ScreenCaptureKit).
- ADR-015 — concurrent dictation and meeting recording, the shared
  mic engine, and the channel-0 mono-extraction rule.
- ADR-016 — centralized STT scheduler. Audio buffers feed the
  scheduler; STT lifecycle lives in `../STT/`.
- ADR-019 — crash-resilient meeting recording; explains the
  fragmented MP4 writer + lock-file conventions in the meeting
  audio files above.
- ADR-021 — engine routing for multilingual STT. Active meetings
  hold a speech-engine lease; this folder enforces the audio side
  of that contract by keeping the meeting capture pipeline
  independent of dictation.
- `spec/05-audio-pipeline.md` — narrative spec.
- `journal/2026-05-03-dictation-silent-stall.md` — active
  regression hunt; the diagnostic logging in `AudioRecorder`,
  `SharedMicrophoneStream`, and `MicrophoneEnginePlatform` is part
  of that investigation.

## What to know before editing

**VPIO is sticky once engaged (process-wide).** Once any subscriber
requests VPIO, it stays on for the engine's lifetime. The state
machine in `SharedMicrophoneStream.decideSubscribeAction` enforces
this. Don't try to disengage VPIO mid-session — coreaudiod attaches
the VPAU aggregate device to the **process**, and toggling VPIO mid-
flight changes the input format under live subscribers.

**Channel 0 mono extraction is mandatory when VPIO is engaged.** VPIO
exposes a duplex layout (typically `ch=9`) where only ch[0] is the
post-AEC processed mono and the rest are reference channels. Use
`extractChannelZero(from:)` — never let `AVAudioConverter`'s default
channel reduction average across them. This was the bug PR #189
fixed; do not regress it.

**The `AVAudioEngine` is recreated on every teardown.** `tearDownLocked`
in `MicrophoneEnginePlatform` does `audioEngine = AVAudioEngine()`
deliberately. Releasing the old instance triggers coreaudiod to drop
the VPAU aggregate device. Long-lived engines inherit duplex layout
into sibling engines in the same process — exactly the bug PR #189
fixed. Do not optimize this away by caching the engine.

**Tap closures run on the audio render thread.** No allocation, no
actor hops, no `await`. State touched from the tap path uses
`OSAllocatedUnfairLock`-protected nonisolated fields. The buffer
passed in is valid only for the synchronous duration of the call —
copy via `copyPCMBufferForAsyncUse` before retaining or dispatching
async.

**Dictation startup requires a first buffer.** `AudioRecorder.start()`
does not report a healthy recording until the shared stream delivers a
first usable buffer. A transient engine-start failure is retried once;
a stream that starts but never delivers a first buffer fails as
`AudioProcessorError.inputUnavailable(.noInputBuffers)` instead of
letting the user record into a dead capture. The heartbeat remains
diagnostic, and stop-time health still separates silent buffers from
genuine short/no-speech recordings.

**First-buffer can arrive before timers are armed.** When subscribing
from an actor, the AVAudioEngine tap can fire its first buffer
during the `await sharedStream.subscribe(...)` suspension, before
post-await `armCaptureDiagnostics` runs. State that tracks "have we
seen the first buffer yet" must be generation-keyed (see
`firstBufferSeenGeneration` in `AudioRecorder`) and the arming code
must check it before scheduling the watchdog. Bool flags get reset
on arm and lose the early buffer.

**Concurrent dictation and meeting recording is supported (ADR-015).**
A user can dictate while a meeting recording is active. Both flows
fan out from the same `SharedMicrophoneStream` instance. Don't add
state that assumes a single consumer at a time.

**System audio is a separate stream.** `SystemAudioStream` uses
`ScreenCaptureKit`, not `AVAudioEngine`. It does not share lifecycle,
VPIO state, or the fan-out path with the mic stream. Meeting
recording composes both via `MeetingAudioCaptureService`.

**The diagnostic log file is shared across processes.** Both the dev
app and `swift test` write to
`~/Library/Logs/MacParakeet/dictation-audio.log`. The
`dictation_diagnostics_session_start` line emitted by `AppDelegate`
on launch is the only reliable per-process separator. The 5 MB cap
deletes the file when crossed (no rotation); a heavy user retains
tens of days of context.

## How to verify a change

- `swift test --filter Audio` — covers the shared stream's state
  machine, the platform adapter, the recorder, and the diagnostic
  helpers under deterministic mocks.
- `swift test --filter SharedMicrophoneStream` — the VPIO state
  machine specifically.
- `swift test` — full suite (~100 s). Audio changes ripple into
  dictation, meeting, and STT scheduler tests.
- Dev-app smoke (the canonical happy-path check):
  1. `scripts/dev/run_app.sh`.
  2. Dictate three times in sequence.
  3. Start a meeting recording.
  4. Dictate during the meeting.
  5. Stop the meeting; dictate once more.
  6. Inspect `~/Library/Logs/MacParakeet/dictation-audio.log` —
     expect clean `engine_started → first_buffer → heartbeat → stop`
     cycles for each dictation and a clean
     `meeting_mic_capture_started → meeting_mic_first_buffer →
     meeting_mic_capture_stopped` cycle for the meeting.
- After a stall report: cross-reference the user's log against the
  decision tree in PR #210's description.
