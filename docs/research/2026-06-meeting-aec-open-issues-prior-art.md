# Meeting AEC and Open-Issue Priority Review

> Status: research and implementation recommendation
> Date: 2026-06-27 America/Los_Angeles
> Baseline: `origin/main` at `81aa755f1`
> Inputs: live GitHub issues and PRs, current MacParakeet code, and primary-source
> open-source meeting-recorder / AEC repositories.

## Executive recommendation

Prioritize acoustic echo cancellation for speaker-mode meetings before more
meeting polish or diarization work. The highest-priority issue cluster is
[#605](https://github.com/moona3k/macparakeet/issues/605),
[#480](https://github.com/moona3k/macparakeet/issues/480),
[#430](https://github.com/moona3k/macparakeet/issues/430),
[#501](https://github.com/moona3k/macparakeet/issues/501),
[#542](https://github.com/moona3k/macparakeet/issues/542), and
[#106](https://github.com/moona3k/macparakeet/issues/106). The user-visible
failure is not only "diarization is imperfect." It is that remote speaker audio
physically leaks from laptop speakers into the microphone track, so the same
words appear as both `Others` and false `Me` text. In #605 the report says the
meeting transcript is unusable because `meeting.m4a` contains remote echo while
`system.m4a` is clean but lacks the local user's voice.

The recommended implementation path is:

1. Finish the existing LocalVQE-style `StreamingMeetingEchoSuppressor` path.
2. Produce or test a cleaned microphone signal, not only transcript-layer
   deletion.
3. Run WebRTC AEC3 as a side-by-side benchmark candidate before committing to
   release packaging.
4. Keep raw `microphone.m4a` and `system.m4a` as durable truth, and add a
   cleaned mic output or cleaned final-STT path as a derived artifact.
5. Treat VPIO as an explicit experimental path only, because previous live-call
   testing showed it can affect the user's outgoing call microphone.

This should be the next meeting focus. Open PR
[#537](https://github.com/moona3k/macparakeet/pull/537) can improve speaker
diarization and evaluation, but it does not remove system-audio bleed from the
mic. Shipping diarization controls before AEC risks labeling duplicated content
more neatly rather than removing the duplicate content.

## Current open backlog map

Live state at review time: 49 open issues and 3 open PRs
([#621](https://github.com/moona3k/macparakeet/pull/621),
[#537](https://github.com/moona3k/macparakeet/pull/537),
[#363](https://github.com/moona3k/macparakeet/pull/363)).

| Priority | Cluster | Issues | Why it ranks here |
| --- | --- | --- | --- |
| P0 | Meeting AEC and source trust | #605, #480, #430, #501, #542, #106 | #605 says meetings are unusable without headphones; #430's owner comments already point to echo/system bleed before diarization. |
| P1 | Dictation trust and capture reliability | #606, #432, #470, #541, #481, #409, #562, #527, #603 | These affect whether dictated text is correct, audible, or even captured. |
| P1 | Meeting privacy, retention, and storage control | #547, #462, #609, #460, #576, #502, #126 | Transcript-only mode and audio retention are trust surfaces for people recording real meetings. |
| P2 | AI/chat honesty and recovery | #563, #478, #550, #408, #412, #439, #433, #312, #265, #514 | Important, but mostly downstream of having a trustworthy transcript and explicit context limits. |
| P2 | Model, diarization, and transcription quality | #610, #497, #490, #469, #290, #526 | Valuable after source trust. #537 overlaps this cluster but not AEC. |
| P3 | UX polish, integrations, and setup | #612, #604, #595, #533, #455, #310, #294, #473 | Useful quality work, but not release-blocking relative to capture correctness. |
| P4 | Feedback / acknowledgement | #611, #548, #449 | Product signal rather than implementation blockers. |

## Current MacParakeet implementation

MacParakeet already has the right foundation for AEC:

- Meeting capture preserves microphone and system audio as separate selected
  source files.
- The shipped meeting mic path is raw by default, so recording does not engage
  VPIO and should not alter what Zoom, Meet, Teams, or other participants hear.
- System audio uses ScreenCaptureKit rather than a Core Audio process tap in
  the production path.
- `CaptureOrchestrator` pairs mic/system samples before live chunking.
- `MicConditioning` can transform mic samples with a paired system reference.
- `StreamingMeetingEchoSuppressor` handles frame carry, reference delay,
  missing/partial references, processor failures, and flush behavior.
- `MeetingEchoSuppressionRuntime` can dynamically load a LocalVQE-compatible
  runtime and model when configured by environment or bundle assets.
- `MeetingRecordingService` still has a short-window live mic suppression guard
  when system energy strongly dominates mic energy.
- `MeetingTranscriptSourceReconciler` removes long simultaneous mic runs that
  match remote/system words during final transcript assembly.

What remains unsolved:

- No LocalVQE runtime library or model is bundled in the app today.
- The optional echo suppressor is asset/config gated, so the default production
  behavior is still passthrough mic conditioning plus transcript cleanup.
- The final post-stop transcript still runs from retained source files, not
  from a verified cleaned mic artifact.
- There is no `microphone-cleaned.m4a` artifact for inspection or replay.
- There are no speaker-playback fixtures that model far-end-only, near-end-only,
  and double-talk cases with measurable ERLE, correlation, WER, and near-end
  retention.
- Live system-dominance suppression has behavioral coverage through service
  tests, but the exact energy gate should get direct regression fixtures before
  being considered a release proof.

The current code is therefore a good scaffold, not a completed AEC fix for #605.

## Prior art

### Anarlog / Hyprnote / former char name

Primary source: [fastrepl/anarlog](https://github.com/fastrepl/anarlog)

The README says Anarlog started as Hyprnote, briefly used the char name, and is
now the open-source local-first meeting notetaker while the team builds
char.com. This is likely the "char" reference, but the repository is not the
current char.com codebase.

Relevant implementation details:

- `crates/audio/src/lib.rs` models each capture frame as `raw_mic`,
  `raw_speaker`, and optional `aec_mic`.
- `CaptureFrame.preferred_mic()` uses the cleaned mic only when it exists, while
  raw dual-source access remains available.
- `crates/audio-actual/src/capture/stream.rs` joins raw mic and speaker chunks,
  aligns the speaker reference with `AecReferenceAligner`, then passes both to
  `hypr_aec::AEC`.
- `crates/aec/src/onnx/mod.rs` ships ONNX AEC models and tests them against
  double-talk, Hyprnote, and Theo mic/loopback fixtures in both batch and
  streaming modes.
- The AEC path also applies residual linear echo cancellation after the neural
  processor.

Applicability to MacParakeet: high. The raw-plus-cleaned model matches the
trust contract MacParakeet should keep: never delete raw source truth, but feed
meeting transcription from a cleaned near-end candidate when it passes gates.

### Prismical WebRTC AEC3

Primary source: [amicalhq/prismical](https://github.com/amicalhq/prismical)

Prismical is the strongest WebRTC AEC3 implementation reference found:

- `Aec3Processor.swift` wraps a native AEC3 bridge.
- The fixed contract is 48 kHz mono with 480-sample, 10 ms frames.
- Render/system audio is ingested before capture/microphone audio is processed.
- `NativeTimedDualAecSession` preserves a timed dual-stream model and emits
  separate `micRaw`, `system`, and `micProcessed` chunks.
- It has render holdback / timeout logic so mic frames can wait for the
  matching render reference without deadlocking forever.

Applicability to MacParakeet: high as a benchmark and possible implementation
path. The downside is vendoring and maintaining WebRTC AEC3 native artifacts.
The upside is maturity and the exact far-end/reference API that MacParakeet's
paired mic/system pipeline already approximates.

### Muesli LocalVQE / DTLN

Primary source: [Muesli-HQ/muesli](https://github.com/Muesli-HQ/muesli)

Muesli is the closest Swift/macOS comparison point for MacParakeet's current
LocalVQE direction:

- The README says meeting echo cancellation uses bundled LocalVQE
  `localvqe-v1.2-1.3M-f32.gguf` by default, with DTLN fallback.
- `MeetingNeuralAec.swift` preloads LocalVQE first, falls back to DTLN, and
  keeps pending mic samples plus system history so the processor receives a
  timestamp-aligned far-end reference frame.
- It has a delay estimator and reference wait behavior for independent mic and
  Core Audio tap callbacks.
- `LocalVQEProcessor.swift` resolves a model, verifies optional SHA256, loads a
  dynamic library, and uses frame-size/sample-rate checks.

Applicability to MacParakeet: very high. MacParakeet already has much of this
shape in `MeetingEchoSuppressionRuntime` and `StreamingMeetingEchoSuppressor`;
the missing part is packaging, validation, and deciding whether the cleaned
track becomes an inspectable retained artifact.

### Corti FDAF/NLMS

Primary source: [vasovagal/corti](https://github.com/vasovagal/corti)

Corti is a useful non-neural baseline:

- `crates/corti-aec` implements streaming acoustic echo cancellation for
  speaker bleed using an FDAF/NLMS adaptive filter.
- The library documents the invariant that raw mic and far-end tracks are
  preserved upstream and the AEC output is an additional cleaned track.
- Its config exposes filter length, step size, double-talk gating, delay
  search, and residual suppression.

Applicability to MacParakeet: medium-high. The Rust implementation is not a
drop-in, but the verification discipline is valuable. A classical baseline can
also reveal whether LocalVQE/WebRTC is actually doing better on MacParakeet
recordings.

### Meeting Transcriber and Recap

Primary sources:
[pasrom/meeting-transcriber](https://github.com/pasrom/meeting-transcriber),
[RecapAI/Recap](https://github.com/RecapAI/Recap)

These are useful capture references rather than AEC solutions:

- Meeting Transcriber captures app audio via `CATapDescription` and mic via
  `AVAudioEngine`, then keeps dual-source diarization. It does not provide the
  same level of true AEC as Anarlog, Prismical, Muesli, or Corti.
- Recap is a minimal process-tap plus optional mic example. Its transcription
  service combines separate system/mic transcripts, but no AEC path was found.

Applicability to MacParakeet: low for #605 itself, but useful for crash/restart,
timeline, and process-tap reference material.

### LocalVQE

Primary source: [localai-org/LocalVQE](https://github.com/localai-org/LocalVQE)

LocalVQE is a compact GGML/PyTorch voice-quality enhancement stack for 16 kHz
streaming speech. The README documents 256-sample hops, far-end reference input,
and models for joint AEC/noise/dereverb as well as echo-only AEC variants.

Most relevant options:

- v1.4-AEC: echo-only, keeps voice/noise/room more intact.
- v1.2 or v1.3 joint models: remove echo plus noise/reverb, but may be more
  aggressive than a meeting recorder should be.
- The C API supports whole-clip and per-frame processing with mic and reference
  buffers.

Applicability to MacParakeet: high. The current MacParakeet runtime expects a
LocalVQE-compatible dynamic library and model, so this is the shortest path to
turning the scaffold into a testable implementation.

### Secondary references checked

Primary sources:
[AudioCap](https://github.com/insidegui/AudioCap),
[AECAudioStream](https://github.com/kasimok/AECAudioStream),
[Vexa Desktop](https://github.com/Vexa-ai/vexa-desktop),
[dtln-aec-coreml](https://github.com/MimicScribe/dtln-aec-coreml),
[SpeexDSP](https://github.com/xiph/speexdsp),
[WebRTC AudioProcessing](https://webrtc.googlesource.com/src/+/main/api/audio/audio_processing.h)

- AudioCap is valuable process-tap sample code for macOS 14.4+ system audio,
  but it does not solve microphone bleed.
- AECAudioStream demonstrates `kAudioUnitSubType_VoiceProcessingIO`. It is a
  useful VPIO reference, but MacParakeet should not use VPIO by default for
  speaker-mode meetings.
- Vexa Desktop is a Granola-style recorder that captures mic/system audio and
  uses transcript-layer echo dedupe. It is useful product signal, but it is not
  a true AEC reference for a cleaned microphone signal.
- `dtln-aec-coreml` is an archived Swift/CoreML AEC package. It is useful as
  fallback/cautionary prior art, but Muesli's current LocalVQE-first direction
  is a better match for MacParakeet.
- SpeexDSP's echo API is simple and well-known, with 10-20 ms frames and
  100-500 ms filters. If MacParakeet adds a classical baseline, Corti's
  FDAF/NLMS implementation is more directly product-shaped for long meeting
  recordings.
- The official WebRTC AudioProcessing API confirms the shape Prismical uses:
  far-end frames flow through `ProcessReverseStream`, near-end frames through
  `ProcessStream`, and stream delay is supplied through `set_stream_delay_ms`.

## Implementation options

### Option A - finish the LocalVQE path

Recommended first path because it aligns with current code.

Work:

- Build/sign/notarize a universal `liblocalvqe.dylib` or decide on a first-run
  download path.
- Pick an initial model. Prefer testing v1.4-AEC and v1.2 side by side before
  defaulting to the joint v1.2 model.
- Add a model checksum and runtime diagnostics visible in logs and feedback.
- Create synthetic and real speaker-playback fixtures.
- Add a cleaned mic artifact or route final mic STT through the same cleaner.
- Gate rollout behind an app feature flag until the fixture matrix passes.

Pros: smallest architectural jump, strong Swift prior art in Muesli, strong
model prior art in LocalVQE.

Cons: new binary/model packaging and quality risk on double-talk.

### Option B - evaluate WebRTC AEC3

Work:

- Prototype a Swift wrapper with MacParakeet's paired mic/system samples.
- Resample to 48 kHz mono and feed 480-sample frames.
- Preserve raw and processed mic outputs.
- Compare against LocalVQE on the same fixtures.

Pros: mature AEC algorithm and clear render/capture API.

Cons: native dependency complexity, vendoring/build maintenance, and more
sample-rate/timing glue than the current LocalVQE scaffold.

### Option C - port or adapt Anarlog's ONNX AEC

Work:

- Evaluate its ONNX AEC models on MacParakeet recordings.
- Determine whether ONNX Runtime packaging is acceptable for the app.
- Port the reference-alignment and residual cancellation ideas even if not the
  exact model.

Pros: open-source meeting-app prior art with raw/cleaned capture semantics and
fixtures.

Cons: Rust/ONNX stack mismatch with the current Swift/CoreML/GGML direction.

### Option D - keep VPIO as an explicit experiment

Work:

- Keep `MeetingMicProcessingMode.vpioPreferred` and `.vpioRequired`.
- Do not make VPIO the default.
- Use it only for controlled tests where the user accepts that it may affect
  live call mic quality.

Pros: platform AEC can be useful in narrow conditions.

Cons: previous MacParakeet testing found unacceptable outgoing-mic risk.

### Option E - transcript-layer cleanup only

Work:

- Continue improving `MeetingTranscriptSourceReconciler` and live energy gates.

Pros: cheap and already partially shipped.

Cons: not enough for #605. It cannot produce a clean mic signal, cannot make
`meeting.m4a` trustworthy, and risks deleting real local speech during
double-talk if pushed too far.

## Release proof for #605

Do not call #605 fixed until these pass:

- Raw `microphone.m4a` and `system.m4a` are still preserved.
- A cleaned mic path exists for final transcription, either as
  `microphone-cleaned.m4a` or an equivalent retained/reproducible derived
  processing input.
- Far-end-only speaker playback produces little or no false `Me` transcript.
- Near-end-only local speech is retained.
- Double-talk keeps the local speaker while suppressing only the far-end echo.
- At least one real Zoom/Meet/Teams speaker-mode recording passes manual QA.
- Fixture tests report ERLE/correlation improvement and near-end retention, not
  just fewer words.
- Missing, partial, delayed, and silent references fall back clearly and log
  diagnostics instead of silently degrading.
- The user can inspect or export enough artifacts to understand what happened.

## Suggested next branch

Start with a small branch that does not change product behavior:

1. Add fixture harnesses for mic/reference/cleaned output.
2. Build LocalVQE and WebRTC AEC3 adapters behind compile/runtime gates.
3. Run both against the same recordings.
4. Decide whether to ship LocalVQE alone, WebRTC AEC3 alone, or LocalVQE with a
   WebRTC escape hatch.

Then do the product branch:

1. Package the selected runtime/model.
2. Add cleaned mic final-STT integration.
3. Add diagnostics and user-visible fallback messaging.
4. QA against #605, #480, and a double-talk fixture before release.
