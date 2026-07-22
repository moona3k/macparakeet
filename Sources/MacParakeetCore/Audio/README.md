# Audio

> One mic engine per process, fanned out to dictation and meeting
> recording. This folder owns capture, format conversion, and on-disk
> diagnostic logging.

## Entry point

`SharedMicrophoneStream` — the process-wide microphone source. Every
consumer (dictation, meeting mic) calls
`subscribe(wantsVPIO:blocksVPIOPromotion:onEngineDeath:handler:)`
and receives every buffer. The stream owns engine lifecycle, VPIO
arbitration, and fan-out. There is exactly one instance per process,
owned by `AppEnvironment`.

## What's here

**Shared mic engine (the core of this folder)**
- `SharedMicrophoneStream.swift` — fan-out, VPIO state machine,
  subscriber tokens, `Diagnostics` snapshot. ADR-015 + ADR-016.
- `MicrophoneEnginePlatform.swift` — `AVAudioEngine` wrapper. Device
  fallback chain, VPIO toggle, tap install, engine recreation on
  every teardown (so coreaudiod releases the VPAU aggregate
  device), `AVAudioEngineConfigurationChangeNotification` observer,
  and source-liveness self-healing. A stopped graph or a tap that stops
  delivering callbacks converges on the same bounded fresh-engine recovery.
  Notifications received while a replacement still awaits its first buffer
  remain in the same recovery episode; they do not replenish the retry budget.

**Mic consumers (each subscribes to the shared stream)**
- `AudioRecorder.swift` — dictation capture.
  `subscribe(wantsVPIO: false)`. Writes 16 kHz mono Float32 WAVs to
  `$TMPDIR/macparakeet/`. VPIO buffers use channel 0; raw multichannel
  device buffers are downmixed to mono. Owns the dictation diagnostic timers
  (first-buffer watchdog + recording heartbeat). Optional Instant
  Dictation keeps a passive warm subscriber attached while idle,
  stores a 1-second RAM-only 16 kHz mono ring buffer, and prepends up
  to 0.45 seconds when the user starts dictation. It does not run STT
  while idle. The warm hold is suppressed while the resolved input is
  Bluetooth, and warm-capture refreshes are debounced (issue #481 —
  see "What to know" below). When the Pause Media round-trip confirms media was
  playing at press time, `discardPreRollForActiveRecording()` marks
  the session and `stop()` trims the prepended pre-roll from the WAV —
  pre-press media audio that no pause can silence (issue #474). Active
  dictation start now waits for the first real input buffer; if the shared
  engine starts but delivers none within the watchdog window, start aborts with
  a microphone-input error instead of handing an empty WAV to STT.
- `MicrophoneCapture.swift` — meeting microphone capture. Subscribes
  with `wantsVPIO: false` by default via `MeetingMicProcessingMode.raw`.
  VPIO modes remain available for explicit experiments, with raw fallback
  when `.vpioPreferred` cannot engage. Has its own silent-buffer watchdog
  with a stall observer wired up to the meeting flow. Stop is an ordered async
  boundary: it retires callbacks and awaits shared-stream unsubscription before
  a replacement meeting may start.

**Meeting-side audio (independent of the mic stream)**
- `SystemAudioStream.swift` — meeting system audio via
  `ScreenCaptureKit` (`SCStream`). Independent of the
  `AVAudioEngine`. The complete startup attempt and callback-style
  start/stop boundaries have deadlines; late successful starts are stopped
  again rather than allowed to revive capture. Has its own first-buffer
  watchdog. Unexpected `SCStreamDelegate` termination is a typed recoverable
  source loss; ScreenCaptureKit's explicit `userStopped` code remains terminal.
- `MeetingAudioCaptureService.swift` — composes mic + system audio
  for meeting recording. It owns partial startup explicitly, so Stop tears
  down whichever sources have started even before startup reports success.
  Each settled Stop creates a new event-stream session, and system-audio
  callback generations retire before teardown is awaited or a terminal event
  is published. A source failure racing the initial async start is retained
  until the start-to-running handoff, so a dead stream cannot be promoted.
- `MeetingAudioStorageWriter.swift` — fragmented MP4 writer for
  meeting source files (ADR-019 crash recovery).
- `MeetingAudioError.swift`, `MeetingMicProcessingMode.swift` —
  value types.
- Meeting mic conditioning lives outside this folder in
  `../Services/Capture/MicConditioner.swift` and
  `../Services/Capture/MeetingEchoSuppressionRuntime.swift`. Those files own
  the passthrough default and optional LocalVQE-compatible echo suppressor used
  after `CaptureOrchestrator` pairs `MeetingAudioCaptureService` mic/system events.

**Helpers**
- `AudioCaptureDiagnostics.swift` — public `append(_:)` to
  `~/Library/Logs/MacParakeet/dictation-audio.log`. 5 MB cap;
  delete-on-overflow (not rotated). Used by every file in this
  folder, by `AppDelegate`'s boot marker, and by the dictation
  media-pause path (`SystemMediaController` +
  `DictationMediaPauseCoordinator` mirror their `media_pause_*` /
  `media_resume_*` outcomes here so uploaded logs show the
  press→pause window next to the capture timeline; issue #474).
- `DiagnosticLogScope.swift` — `AudioCaptureDiagnostics.scopedLogForUpload`
  trims the log to a recent window (`.recent`, the feedback default:
  last 7 days, 2 MB / 20k-line safety ceilings, min-tail fallback) or
  the whole file (`.full`, advanced opt-in) before a feedback upload.
  Scopes whole lines by recency; never edits line contents.
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
- `extractChannelZero`, `microphoneCaptureMonoBuffer` (in `AudioRecorder.swift`),
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

**Passive warm subscribers do not block VPIO promotion.** User-visible
raw capture sessions (`AudioRecorder` active dictation and
`MicrophoneCapture` raw meeting mic) keep `blocksVPIOPromotion=true`
so an explicit VPIO request is deferred until they leave. The Instant
Dictation warm/pre-roll lease passes `blocksVPIOPromotion=false`: it
may keep the shared engine running while idle, but it is not a
recording session and must not prevent a meeting experiment from
promoting the process-wide engine to VPIO.

**Channel 0 mono extraction is mandatory when VPIO is engaged.** VPIO
exposes a duplex layout (typically `ch=9`) where only ch[0] is the
post-AEC processed mono and the rest are reference channels. Use
`extractChannelZero(from:)` — never let `AVAudioConverter`'s default
channel reduction average across them. This was the bug PR #189
fixed; do not regress it.

**Raw multichannel device input is different from VPIO.** Interfaces such as
USB audio boxes may expose several unrelated input channels, and the user's
active microphone can live on channel 2+. Raw capture paths should use
`microphoneCaptureMonoBuffer(from:extractVPIOChannelZero:)`, which downmixes
raw multichannel buffers but still preserves the VPIO channel-0 rule.

**The `AVAudioEngine` is recreated on every teardown.** `tearDownLocked`
in `MicrophoneEnginePlatform` does `audioEngine = AVAudioEngine()`
deliberately. Releasing the old instance triggers coreaudiod to drop
the VPAU aggregate device. Long-lived engines inherit duplex layout
into sibling engines in the same process — exactly the bug PR #189
fixed. Do not optimize this away by caching the engine.

**A `DictationAudioSampleSink` is finished on success but cancelled on
abort.** `AudioRecorder.stop()` calls `onFinish()` only when the capture
yields a usable WAV (>= the FluidAudio sample floor). The abort paths — an
unclaimed sink, no output file, or a too-short capture — call `onCancel()`
instead. The live-transcription wiring (`DictationService`, Nemotron streaming
path) treats `onCancel` as "tear down": cancel the inference task and finish
both the sample and partial continuations, rather than draining a partial
result the recorded audio can no longer back. Keep the success path on
`onFinish` and every early-out on `onCancel`; collapsing them leaks the
live-transcription continuations on cancelled dictations.

**Tap closures run on the audio render thread.** No allocation, no
actor hops, no `await`. State touched from the tap path uses
`OSAllocatedUnfairLock`-protected nonisolated fields. The buffer
passed in is valid only for the synchronous duration of the call —
copy via `copyPCMBufferForAsyncUse` before retaining or dispatching
async.

**Warm pre-roll is in-memory only.** Instant Dictation's idle audio is
bounded to the private ring in `AudioRecorder`, cleared when recording
starts/stops, when the setting is disabled, and when the warm engine
dies. The only persisted audio remains the normal dictation WAV after
the user starts dictation.

**Idle prepare keeps cold starts cheap without opening the mic.**
Independent of the Instant Dictation warm hold, the shared stream can
re-*prepare* the raw dictation engine whenever it goes idle
(`SharedMicrophoneStream(autoPrewarmWhenIdle:)`, plus a one-shot
`prewarmDictation()` at launch). Prepare pays the expensive cold-path
work up front — apply an explicit named-device selection when requested,
negotiate the output format, install the tap, and call
`AVAudioEngine.prepare()` — but leaves the engine **stopped**,
so there is no capture and no mic indicator while idle. The next
dictation press matches the prepared engine
(`AVAudioEngineMicrophonePlatform.prepare`/`goPreparedLocked`) and pays
only `audioEngine.start()` (~tens of ms) instead of the full
device-acquisition + format negotiation. Raw meetings use the same
non-VPIO stream configuration and can consume the prepared engine too;
an explicit VPIO request or different buffer size discards it and does
a full configure. Idle microphone-route changes trailing-debounce a
fresh preparation before the next capture. Like the warm hold, prepare
is **suppressed on Bluetooth or unresolved inputs**: pre-acquiring a
Bluetooth mic would pin HFP/SCO even while stopped, so the platform
declines and that press pays the full cold
path. This is the no-warm-window path: instant first words after
key-down without holding the mic open.

Idle preparation preserves the active routing contract below: a named
microphone stays explicitly pinned, while System Default stays implicit.
Preparation validates the resolved leading input for Bluetooth safety but
does not convert System Default into a `CurrentDevice` write. A default-input
change invalidates and trailing-debounces a new preparation.

**The warm hold must never pin a Bluetooth input (issue #481).** An
idle open Bluetooth microphone forces the headset into HFP/SCO, which
degrades playback the entire time and can flap the default input.
`AudioRecorder` consults `isBluetoothInputProvider` (wired in
`AppEnvironment` to the first device-attempt in the engine's chain)
before every warm start, and `refreshInstantDictationWarmCapture`
*drops* the warm subscriber outright — rather than deferring — when
the input is Bluetooth, so the shared stream's deferred passive
restart cannot revive a warm engine on the Bluetooth device after an
active session ends. Active dictation and meeting capture on a
Bluetooth mic are unaffected; only the idle hold is suppressed.

**Warm-capture refreshes are debounced (issue #481).** Default-input
changes arrive in bursts (Core Audio fires duplicate notifications,
and Bluetooth profile transitions flap the default input), and each
refresh restarts the warm engine — which itself can trigger the next
notification. `refreshInstantDictationWarmCapture` applies a trailing
debounce (0.5 s in `AppEnvironment`, 0 = disabled for direct
constructions) keyed by a supersession generation; superseded or
cancelled sleepers exit before touching any engine or pre-roll state.

**Input routing follows the microphone selection (issue #796).** A named mic
is attempted by its resolved Core Audio device ID. System Default is always
attempted implicitly, so AVAudioEngine can follow macOS routing without
pinning the same endpoint through a different setup path. The built-in mic is
kept as a final explicit fallback when it is distinct from the resolved
default. Audio output never rewrites this ordering. If a Bluetooth headset is
the macOS default input and the user wants to keep its output in high-quality
A2DP, they can explicitly select the Mac's built-in mic in Settings. The idle
warm-capture suppression above remains separate and still prevents Instant
Dictation from holding a Bluetooth input open between active sessions.

**Diagnostics stay narrow.** The recording heartbeat in `AudioRecorder`
remains observability-only. The first-buffer watchdog is now also a
startup readiness signal: `start()` does not report a healthy recording until
at least one microphone buffer arrives, and a no-buffer start aborts with a
microphone-input error. Sustained silent input is classified at `stop()` using
the capture-health snapshot before STT runs. Keep that signal-level heartbeat
non-disruptive: actual callback liveness belongs to the shared source owner
below, so dictation and meeting capture do not invent competing recovery paths.

**The shared mic source self-heals (gated, bounded recovery).** There are two
source-owned triggers. First, when `AVAudioEngine` stops itself after an
`AVAudioEngineConfigurationChange` notification (default-input, format, or
sample-rate change), the observer follows Apple's restart contract. It requires
the current engine instance, an active capture request, and
`AVAudioEngine.isRunning == false`; benign notifications around a healthy graph
are no-ops. Second, once a tap has delivered its first buffer, a five-second gap
with no further tap callbacks is treated as a stalled source even if
`AVAudioEngine.isRunning` remains true. This check is callback-based, not
amplitude-based: real silence continues to produce buffers and never triggers a
restart. It is not Bluetooth-specific because USB, aggregate, and virtual
devices can fail at the same source-lifecycle seam.

Both triggers converge on one recovery implementation. The immediate restart
and every retry rebuild the engine, resolve the current input route, and query
its live format. Failures use a bounded 31.5-second backoff; default-input
changes trailing-debounce a pending attempt so a USB/Bluetooth handoff can
settle without causing a restart storm. An engine start is only a candidate
recovery: the replacement must deliver its first real buffer before the attempt
is accepted. A replacement with no first buffer is torn down and retried.
Explicit Stop cancels the
episode and no queued retry may resurrect capture. If every retry fails, the
platform reports terminal engine death to `SharedMicrophoneStream`, which
invalidates subscriptions and fires their existing `onEngineDeath` handlers.
Meeting capture maps that terminal death to a microphone-source interruption
when system audio is also selected, so the healthy sibling source continues;
microphone-only capture keeps the existing whole-capture failure semantics.
The watchdog and heartbeat in `AudioRecorder` remain log-only; platform callback
liveness is the single mid-session recovery owner. Recovery log events include
`shared_mic_engine_callback_stalled`,
`shared_mic_engine_config_change_recovery_attempt`,
`shared_mic_engine_config_change_recovery_succeeded`, and
`shared_mic_engine_config_change_recovery_failed`, plus scheduling and terminal
exhaustion records. The
`shared_mic_engine_configuration_changed` line now includes an
`engine_is_running=` field (actual `AVAudioEngine.isRunning`) alongside the
existing `isRunning=` (platform `running` flag).

`MicrophoneEnginePlatform` also logs per-phase engine-start timings
(`shared_mic_engine_start_timing`) so a slow first-buffer report can be split
between device setting, VPIO toggling, input format lookup, tap install, and
`AVAudioEngine.start()`.

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

**ScreenCaptureKit callbacks are bounded but still awaited.** Ordered
start/stop matters, so `SystemAudioStream` awaits `SCStream` completion rather
than launching fire-and-forget teardown. The await has a deadline because the
framework callback is not trusted to arrive. Startup ownership is checked
after every suspension, including `SCShareableContent.current`; timeout, Stop,
or cancellation invalidates that attempt. A callback that reports a late
successful start triggers another non-blocking best-effort stop request. Keep
the stream in `stopping` until output removal and bounded teardown finish so a
replacement start cannot route an old callback into its new handler. Keep
`MeetingAudioCaptureService`'s `starting` ownership in sync with this rule:
Stop during partial startup must stop all sources already created and a late
start result must never restore the service to running.

**System-audio stalls use source-owned replacement, not in-place restart.**
`SystemAudioStream` reports first-buffer timeouts and heartbeat gaps as the
typed `MeetingSystemAudioStall` error. `MeetingAudioCaptureService`, which owns
the stream factory and meeting lifecycle, responds by retiring that capture
generation, awaiting its bounded Stop, and creating a fresh `SystemAudioStream`
for each bounded retry. Six attempts use 23 seconds of cumulative scheduled
backoff (`0, 1, 2, 4, 8, 8` seconds); bounded stream lifecycle and first-buffer
readiness waits are additional. This extends beyond the observed route-change
settlement window. A replacement is healthy only after its first valid buffer;
until then the service emits `sourceRecoveryStarted`, keeps the microphone
untouched, and retries start/no-buffer failures. The first replacement buffer
is delivered before `sourceRecovered`. Only exhausted retries produce the
terminal `sourceInterrupted`/`error` event. Duplicate stall callbacks are
coalesced, stale generations cannot publish buffers, and explicit Stop cancels
and awaits recovery so no delayed attempt can revive capture.

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
