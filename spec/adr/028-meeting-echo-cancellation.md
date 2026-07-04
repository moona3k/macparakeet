# ADR-028: Offline Meeting Echo Cancellation via Derived Cleaned-Mic Artifact

Status: Accepted (2026-07-03)

## Context

Meeting recording captures two sources: the microphone and system audio
(remote participants). When the user plays remote audio through speakers,
the microphone also captures it — delayed and room-colored. This bleed
degrades transcription accuracy on the user's own speech and misattributes
remote speech to the "Me" track. Users expect high-accuracy meeting
transcripts; echo bleed is the largest accuracy defect in the
speakers-playback case.

Constraints that shaped the decision:

- Local-first: all processing on-device.
- The shared mic engine (ADR-015) deliberately avoids Apple's
  voice-processing I/O; dictation and meetings share one plain
  AVAudioEngine capture path, and raw audio must remain available.
- The consumer of echo cancellation is transcription, not live playback —
  there is no real-time requirement.
- Meeting artifacts are durable user data; processing must be reversible
  and debuggable.

## Decision

Perform echo cancellation OFFLINE, after recording stops, producing a
derived artifact — `microphone-cleaned.m4a` — while preserving the raw
microphone recording untouched.

Pipeline (see `MeetingCleanedMicRenderer`, `MicConditioner`,
`MeetingEchoDelayEstimator`, `MeetingEchoSuppressionConfiguration`, and
`MeetingEchoSuppressionFactory`):

1. The recorded system-audio track is the echo reference. It is captured
   anyway for the meeting, giving a perfect reference most AEC systems
   lack.
2. Alignment: host-time recorded offset, plus periodic cross-correlation
   bulk-delay estimation (scalar read-offset only; no sample mutation).
3. Suppression: the LocalVQE neural model — echo-only variant (v1.4),
   selected by a measured scoring gate (`MeetingAecModelScoringTests`,
   issue #605 U5) — is the only stage that modifies samples. Echo-only
   (no general denoising) minimizes distortion of the speech being
   transcribed. No linear DSP pre-stage exists; adding one is deferred
   until the double-talk metric (PR #669) demonstrates a measurable gap.
4. Final meeting transcription prefers the cleaned mic for the "Me" track.

Coordination (readiness gate, PR #671):

- Stop schedules the render when the duration guard predicts it can finish
  inside the bounded deadline; otherwise it skips upfront with
  `predictedRenderTimeout`. Stop latency is never proportional to meeting
  length.
- Final transcription awaits render readiness (a Task handle, not file
  polling) with a bounded, duration-scaled deadline before choosing the
  microphone source.
- Fallback to raw is intentional and observable via a structured reason
  taxonomy: `cleanedUsed`, `rawTimeout`, `rawInvalidArtifact`,
  `rawRenderFailed`, `rawMissingSystemReference`, `rawNoAECAssets`,
  `skippedNoEchoPath`, `predictedRenderTimeout`. Silent raw fallback is a
  defect.

Render skip (echo probe, PR #676):

- Before running the model, the delay estimator doubles as a cheap probe
  over reference-energy windows. No correlation → no echo path (headphones
  of any kind, or remote inaudible) → skip the render with
  `skippedNoEchoPath`. Echo detection is measured from the artifacts, not
  inferred from output-route metadata, so Bluetooth speakers and route
  changes need no special cases and the recovery path behaves identically.
- Each render/skip emits a per-session diagnostics summary (model version,
  render duration and realtime factor, delay estimate, probe score, final
  reason) so accuracy complaints are debuggable from one line.
- The same render/skip summary is persisted into the session's
  `meeting-recording-metadata.json` sidecar as additive optional
  `echoSuppression` fields (`reasonCode` plus optional `modelVersion`,
  `renderDurationMs`, `delayEstimateMs`, `probeBestCorrelation`), per
  `spec/contracts/meeting-artifacts-v1.md`, so shared artifact folders
  self-describe cleaned-vs-raw routing without app logs.

The cleaned mic is exposed in the artifact manifest
(`cleanedMicrophoneAudioPath`, `spec/contracts/meeting-artifacts-v1.md`).

## Alternatives considered

- **Live system AEC (Apple VPIO)** — rejected. Reverses ADR-015: forks the
  shared capture path, destroys raw audio, and its far-end suppression
  audibly ducks the user during double-talk (observed directly in earlier
  testing; see also `../../docs/research/vpio-process-tap-conflict.md`). VPIO
  optimizes live-call comfort; we optimize post-hoc transcript accuracy.
- **Transcript-level echo removal** (delete mic-transcript segments that
  duplicate the system transcript) — rejected. Bleed corrupts the user's
  own words before ASR sees them; deleting duplicates cannot restore
  accuracy and fails on overlapping speech.
- **Linear DSP AEC only** (adaptive filter, WebRTC-AEC3 style) — rejected
  as the sole mechanism. Leaves nonlinear residual (speaker distortion,
  reverb, clock drift). May later be added as a pre-stage if measurement
  justifies it.

## Consequences

Positive:

- Raw audio preserved; cleaned is derived — past meetings can be
  re-rendered when better models ship.
- Offline processing with a known reference is strictly easier than live
  AEC: precise alignment, lookahead, unconstrained compute.
- Every raw-vs-cleaned decision is observable; no silent quality
  degradation.

Negative / accepted risks:

- Double-talk over-suppression is the primary quality risk; it is tracked
  by a dedicated harness metric (PR #669) rather than assumed away.
- The bundled LocalVQE dylib + model are a permanent
  signing/notarization/asset-gate liability
  (`REQUIRE_MEETING_ECHO_ASSETS=1` build gate).
- Render costs compute after each speakers-playback meeting; bounded by
  the deadline policy and eliminated for no-echo meetings by the probe or
  very long meetings by the duration guard.

## References

- Tracking issue #605 (U1–U5 PRs #638/#650/#651/#654/#656).
- Readiness gate: PR #671. Echo probe + skip: PR #676. Long-meeting
  duration guard: PR #705.
- Double-talk metric: PR #669.
- Prior art survey: `../../docs/research/2026-06-meeting-aec-open-issues-prior-art.md`.
- Related ADRs: 014 (meeting recording), 015 (concurrent dictation/meeting,
  shared engine), 019 (crash-resilient recording).
