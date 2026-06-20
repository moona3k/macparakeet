# Per-Capture Speech Engine Routing

> Status: **PROPOSAL**
> Date: 2026-06-08
> Related: `spec/adr/016-centralized-stt-runtime-scheduler.md`, `spec/06-stt-engine.md`, `docs/planning/2026-06-nemotron-stt-benchmark-report.md`

## Verdict

Per-capture speech engines are feasible, but they should be implemented as a
small routing-policy layer on top of the existing shared STT scheduler/runtime.
They should not create separate audio streams, separate feature-owned STT
runtimes, or a parallel scheduler.

The strongest first product slice is:

- Dictation stays on Parakeet by default.
- Meeting recording can opt into Nemotron Beta.
- File/URL transcription continues to use the shared app default plus explicit
  CLI/retranscription overrides.

## Architecture Shape

Keep the current control plane:

- `SharedMicrophoneStream` remains the single process-wide microphone fan-out.
- `STTScheduler` remains the single admission, priority, cancellation, and
  backpressure owner.
- `STTRuntime` remains the single model lifecycle owner for Parakeet, Nemotron,
  and Whisper.
- Meeting recordings continue to capture a `SpeechEngineSelection` at start and
  hold a scheduler lease until stop/cancel.

Add a preference-resolution layer before scheduler admission:

```text
CaptureFlow.dictation      -> SpeechEngineSelection
CaptureFlow.meeting        -> SpeechEngineSelection
CaptureFlow.fileTranscribe -> SpeechEngineSelection
```

The resolved selection is passed into the existing routed scheduler call when a
flow needs a pinned engine. If a flow uses "app default", it resolves through the
current global speech engine preference.

## Recommended Product Slice

Start with one advanced/Beta setting:

```text
Meeting Speech Engine
  App Default
  Parakeet
  Nemotron Beta
  Whisper
```

Default it to `App Default` or `Parakeet`. Avoid launching with a full matrix of
dictation/file/meeting controls. A single meeting setting covers the main use
case - Parakeet for dictation, Nemotron for meetings - without making normal
settings harder to understand.

Dictation should remain Parakeet-first unless benchmark data proves another
engine matches its latency, punctuation, and timestamp behavior.

## Hardware and Runtime Tradeoffs

Per-capture routing does not require multiple audio streams, but it can increase
model residency and switching pressure:

- Parakeet v3/v2 are about 465 MB each on disk; Parakeet Unified is about
  565 MB for its int8 export.
- Nemotron Beta is about 1.5 GB on disk.
- Whisper depends on the selected model variant.
- Keeping multiple engines warm may be fine on 16-48 GB Macs, but lower-memory
  machines should expect more unload/reload behavior.
- CoreML/ANE contention is still process-wide; the scheduler should remain the
  explicit policy rather than letting each flow compete implicitly.

The existing two-slot scheduler remains the right execution model:

- Dictation uses the interactive slot.
- Meeting live/final and file work share the background slot.
- Meeting finalization still outranks live chunks and file transcription.

## Quality and Feature-Parity Tradeoffs

Parakeet remains the default because it is the best-proven MacParakeet path for
latency, punctuation, timestamps, and user-facing dictation feel.

Nemotron is a promising meeting candidate because it is local and fast in the
smoke benchmark, but it should stay Beta until tested on real meeting audio.
Known caution areas:

- Nemotron does not currently surface word timestamps through MacParakeet.
- VAD-guided live chunking is currently Parakeet-only; Nemotron meetings use the
  fixed live chunk cadence.
- Synthetic smoke data showed good speed but not enough quality proof to make
  Nemotron the default.
- Meeting summaries and chat can tolerate weaker timestamp detail better than
  dictation insertion or subtitle export can.

Whisper remains the mature broad-coverage fallback, but it is slower and should
not be positioned as the default low-latency path.

## Implementation Notes

Suggested implementation sequence:

1. Add a `CaptureFlow` enum in Core or ViewModels where preference resolution can
   be tested without SwiftUI.
2. Add a persisted meeting-engine preference with `appDefault` plus explicit
   engine values.
3. Resolve the meeting engine before `MeetingRecordingService.startRecording`
   begins the speech-engine lease.
4. Store the resolved `SpeechEngineSelection` in the existing meeting metadata
   and lock-file path.
5. Keep engine switching blocked while the meeting lease is active.
6. Add CLI/config support only if users need headless provisioning of the
   per-meeting default.

Do not:

- Instantiate `STTClient`, `STTRuntime`, or `STTScheduler` from feature services.
- Split dictation and meeting microphone capture into separate mic engines.
- Add automatic fallback from one engine to another inside a recording. A single
  meeting should be deterministic from live preview through final transcript and
  crash recovery.

## Open Questions

- Should the first setting be `App Default` or `Parakeet` by default?
- Should CLI expose `config set meeting-speech-engine` immediately, or wait until
  the GUI proves the setting is useful?
- Should Nemotron be allowed for meeting live preview before word timestamps are
  available, or should it initially apply only to final transcription?
- What minimum real-world corpus result would promote Nemotron from Beta for
  meetings?
