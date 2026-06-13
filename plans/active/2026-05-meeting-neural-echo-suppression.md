# Meeting Neural Echo Suppression

> Status: ACTIVE PLAN
> Date: 2026-05-22
> Updated: 2026-06-10
> Scope: meeting recording microphone cleanup, source separation, and release packaging.

## Progress (2026-06-10, issue #480)

Phase 1's streaming-coordinator defects are fixed and the transcript-layer
safety net is hardened; the LocalVQE validation experiment is unblocked:

- `StreamingMeetingEchoSuppressor` now carries partial frames across
  `condition` calls (the pending-mic-frame queue this plan specified). Before,
  every batch leaked an unprocessed raw tail (batches are not hop-size
  multiples) and fed the stateful processor discontiguous frames — any live
  test would have under-reported the model's real quality.
- Reference delay is implemented: a reference-history ring serves the frame at
  stream position `p` reference audio from `p - delay`, configured via
  `MACPARAKEET_MEETING_ECHO_REFERENCE_DELAY_MS` (default 0). This is the
  "configured reference offset" step; the cross-correlation estimator remains
  future work if live tests show residual delay mismatch.
- `MicConditioning.flush()` drains held samples; `CaptureOrchestrator` drains
  before synthetic-silence pairs (ordering) and on pending-pair flush.
- `MeetingTranscriptNoiseFilter` gained a confidence-independent
  simultaneous-echo rule (>=5-word mic runs fuzzy-matching >=80% of the remote
  speaker's simultaneous words are dropped) — the final-transcript fix for
  high-confidence echo that the existing low-confidence rule missed.
- VPIO experiment plumbing now sets `isVoiceProcessingAGCEnabled = false`
  (macOS 14+): VPIO AGC can write the shared hardware input gain other apps
  inherit, the likely mechanism behind the 2026-05-14 "muffled outgoing mic"
  finding. Raw capture remains the shipped default; this only de-risks future
  experiments.

Next: obtain/build the LocalVQE assets, run the env-gated two-party
speaker-call validation (Phase 5's "real two-party call validation"), then
decide Phase 4 (cleaned final artifact) and release packaging.

## Problem

Meeting recording currently captures microphone and system audio as separate
sources, which is the right foundation. The defect is that speaker playback can
physically leak into the microphone. When that happens, remote participants can
appear in both streams:

- system audio correctly produces `Others` text
- microphone audio also produces false `Me` text
- live suggestions and post-meeting artifacts can treat remote speech as local
  user speech

The previous macOS Voice Processing I/O approach reduced bleed but created a
higher-risk failure mode: it could affect the live microphone path used by Zoom,
Meet, Teams, and similar apps. Meeting recording must not change how the other
participants hear the user. The shipped baseline should stay raw/call-safe, with
echo suppression implemented inside MacParakeet's meeting pipeline.

## Goals

- Keep microphone and system audio as first-class separate sources.
- Preserve raw mic capture for retained source audio and recovery.
- Add a call-safe neural echo-suppression stage for the meeting transcript path.
- Drive live microphone VAD/STT from cleaned mic samples, not raw mic samples.
- Use the captured system stream as the far-end reference for microphone
  cleanup.
- Keep final post-stop transcription source-aware and rebuild from retained
  source files.
- Make missing/silent/misaligned system reference visible in diagnostics.
- Treat packaging, signing, and fallback behavior as release gates.

## Non-Goals

- Do not re-enable Voice Processing I/O by default.
- Do not merge microphone and system audio into one STT input.
- Do not rely on transcript-only dedupe as the primary fix.
- Do not change the user-facing `Me` / `Others` model in this pass.
- Do not delete existing VPIO plumbing; keep it as explicit experimental
  fallback/testing infrastructure.

## Current Architecture

The useful existing seams are:

- `MeetingAudioCaptureService`: emits microphone and system buffers.
- `MeetingRecordingService`: writes source files, updates levels, orchestrates
  live chunks, and finalizes meetings.
- `CaptureOrchestrator`: aligns microphone/system sample batches and feeds
  source-specific `AudioChunker`s.
- `MicConditioning`: narrow hook for transforming microphone samples with system
  reference samples.
- `LiveChunkTranscriber`: performs source-aware live STT.
- `TranscriptionService.transcribeMeetingAudio`: performs final source-aware
  batch transcription from retained source files.
- `MeetingTranscriptNoiseFilter`: final transcript cleanup safety net.

The first implementation should build around `MicConditioning` and
`CaptureOrchestrator`, then decide whether final batch transcription needs a
cleaned mic artifact in addition to live cleaned chunks.

## Proposed Design

Add a production meeting echo-suppression subsystem with this shape:

```text
raw microphone buffers
        |
        +-- retained source writer -> microphone.m4a
        |
        +-- resampled float stream
                  |
                  v
system reference buffers ---> MeetingEchoSuppressor ---> cleaned mic stream
                  |                                      |
                  |                                      +-- live mic VAD/STT
                  |                                      +-- optional cleaned mic artifact
                  |
                  +-- retained source writer -> system.m4a -> live/final system STT
```

### Processor Abstraction

Introduce a small processor contract, separate from capture ownership:

```swift
protocol MeetingEchoSuppressing: AnyObject, Sendable {
    var name: String { get }
    var sampleRate: Int { get }
    var frameSize: Int { get }
    func reset()
    func processFrame(microphone: [Float], reference: [Float]) throws -> [Float]
}
```

Then implement a streaming coordinator that:

- accepts arbitrary microphone/reference sample batches
- frames them at the processor's required hop size
- buffers pending mic frames until enough reference exists
- emits cleaned samples in input order
- falls back to raw mic frames on processor errors
- records diagnostics for full, partial, missing, and late reference frames

`LocalVQE` should be the preferred processor once packaged. `DTLN` should remain
the practical fallback because it has a simpler Apple-platform integration path.
`PassthroughMicConditioner` remains the final fallback.

### Reference Alignment

The system reference must match the microphone sample position closely enough
for cancellation to work. The coordinator needs:

- per-source sample counters at the normalized processing sample rate
- a system-reference history ring
- pending mic frame queue
- delay estimate or configured reference offset
- a maximum wait threshold so live transcription cannot stall indefinitely
- counters for reference quality:
  - full reference frames
  - partial reference frames
  - missing reference frames
  - frames passed through raw after processing failure

Initial implementation can reuse the pair boundaries from `MeetingAudioPairJoiner`
and add diagnostics. If live tests show residual bleed from delay mismatch, add a
small cross-correlation delay estimator over recent mic/system windows.

### Live Path

Live mic chunks must be produced from cleaned mic samples. This is the core
behavioral change. Raw mic-driven VAD/STT will keep generating false `Me`
segments whenever speaker playback enters the mic.

Expected behavior:

- raw mic writes continue even if echo suppression fails
- cleaned mic drives microphone chunking
- system audio drives system chunking unchanged
- system-dominance transcript suppression remains as a secondary guard
- transcript updates can include echo-suppression health in diagnostics, not in
  user-visible text

### Final Path

The safest final path is two-stage:

1. Ship live cleaned mic first while retaining raw source artifacts.
2. Add a cleaned mic final artifact when the streaming path is proven stable.

The final artifact should be explicit, for example:

```text
meeting-recordings/<uuid>/
|-- microphone.m4a              # raw mic source
|-- system.m4a                  # raw system source
|-- microphone-cleaned.m4a      # optional cleaned mic transcript source
|-- meeting.m4a                 # playback/export mix
`-- meeting-recording-metadata.json
```

Final transcription should prefer `microphone-cleaned.m4a` for the `Me` stream
when it exists and passes basic health checks. It should fall back to
`microphone.m4a` if cleaned audio is missing, silent, corrupt, or shorter than
expected.

## Packaging Plan

### LocalVQE

Expected assets:

- native runtime library: `liblocalvqe.dylib`
- dependent native libraries: likely GGML-related dylibs
- model: `localvqe-v1.2-1.3M-f32.gguf`
- Swift dynamic-loader bridge for `localvqe_new`,
  `localvqe_process_frame_f32`, `localvqe_reset`, and `localvqe_free`
- 16 kHz mono Float32 processing with the runtime-reported hop length
  (currently 256 samples)

Release requirements:

- app build script copies native dylibs into the app bundle
- each dylib is signed with hardened runtime compatible options
- notarization validates the bundled dylibs
- model is bundled or downloaded through the existing model-management pattern
- model checksum is validated before use
- model download failure never breaks meeting recording
- runtime load failure falls back to DTLN or passthrough

### DTLN Fallback

DTLN is less attractive as the primary quality path, but useful as a fallback
because CoreML packaging is more familiar to this app. Requirements:

- resource bundle copied into the app bundle
- bundle lookup tested in the distributed app layout
- missing bundle is nonfatal and falls back to passthrough
- signing/notarization verifies the model bundle

## Diagnostics

Add a concise diagnostic line at meeting stop:

```text
meeting_echo_suppression_summary
session=<uuid>
processor=<localvqe|dtln|passthrough>
loaded=<true|false>
mic_frames=<n>
processed_frames=<n>
raw_fallback_frames=<n>
full_reference_frames=<n>
partial_reference_frames=<n>
missing_reference_frames=<n>
processing_failures=<n>
system_rms_avg=<bucket>
cleaned_mic_rms_avg=<bucket>
```

Do not log transcript text, audio paths, device names, CoreAudio device IDs, or
model paths in public diagnostics. Raw errors can go to private OSLog fields
when needed.

## Test Plan

### Unit Tests

- processor framing preserves sample count after flush
- missing reference passes through raw mic and increments diagnostics
- partial reference zero-pads only the unavailable region
- processor exception falls back to raw frame
- reset clears history and pending mic state
- cleaned mic samples feed microphone chunker
- system chunker remains aligned during mic-only and system-only stretches
- final transcription prefers cleaned mic artifact when healthy
- final transcription falls back to raw mic when cleaned artifact is missing or
  invalid

### Synthetic Audio Tests

Create deterministic synthetic fixtures:

- far-end-only: system speech echoed into mic should suppress mic energy
- near-end-only: local speech should survive cleanup
- double-talk: local and remote speech overlap; local speech must remain
- delayed echo: system reference offset by 50-250 ms
- silent system reference: no false confidence; raw fallback is visible

Pass criteria should measure both:

- echo return loss / reduced mic-system correlation
- near-end speech preservation / non-silent cleaned mic where local speech exists

### Manual Validation

- Zoom, Google Meet, Teams, and Slack Huddle.
- Built-in speakers + built-in mic.
- Studio Display speakers + Studio Display mic.
- AirPods output + built-in mic.
- Headphones/earbuds baseline.
- Long meeting, at least 30 minutes.
- Pause/resume and stop while buffers are queued.
- Dictation during meeting still works.
- Output-device switch during recording is nonfatal.

## Rollout Phases

### Phase 1: Pipeline and Diagnostics

- Add streaming echo-suppression coordinator around `MicConditioning`.
- Keep default processor passthrough.
- Wire diagnostics and tests.
- Prove cleaned mic can drive live chunks without changing capture/storage.

### Phase 2: DTLN Fallback

- Add DTLN processor behind explicit configuration.
- Package CoreML resources.
- Verify build, signing, notarization, and distributed app lookup.
- Run synthetic and manual meeting tests.

### Phase 3: LocalVQE Primary

- Add native bridge and model resolver.
- Add build script support for dylib copy/signing.
- Add checksum validation and nonfatal fallback.
- Enable as preferred processor when runtime and model are available.

### Phase 4: Final Cleaned Mic Artifact

- Write `microphone-cleaned.m4a` during recording or derive it immediately after
  stop from retained source files.
- Prefer cleaned mic for final `Me` STT when healthy.
- Preserve raw source files for audit/recovery/fallback.

### Phase 5: Release Gate

- Full `swift test`.
- `git diff --check`.
- Dev app smoke.
- Real two-party call validation.
- Release build verifies bundled model/library presence.
- Notarization verifies app with native runtime assets.

## Acceptance Criteria

- Starting meeting recording does not degrade the outgoing mic heard by another
  participant.
- Far-end speaker playback no longer produces live false `Me` chunks in normal
  speaker setups.
- Near-end local speech remains intelligible during echo suppression.
- Meeting recording works when the echo-suppression runtime fails to load.
- Diagnostics distinguish capture silence from reference-misalignment from
  processor failure.
- Raw source audio remains available for recovery and debugging.
- Release packaging catches missing model/library resources before shipment.

## Open Questions

- Should the first production release bundle the LocalVQE model or download it
  on demand?
- Where should the user-visible setting live, if any: hidden feature flag,
  advanced meeting setting, or no setting until stable?
- Should `microphone-cleaned.m4a` be retained permanently or treated as a
  derived cache that can be regenerated?
- Is ScreenCaptureKit system audio sufficiently reliable for all native meeting
  apps, or do we need a device-level CoreAudio tap fallback later?
- What minimum echo-suppression metric should block release?
