# ADR-027: Tentative Live Speaker Labels

> Status: **PROPOSAL**
> Date: 2026-06-15
> Related: ADR-010 (speaker diarization), ADR-014 (meeting recording), ADR-016
> (STT runtime scheduler), ADR-018 (live meeting Ask), ADR-020 (live meeting
> notepad), ADR-026 (cross-meeting speaker identity proposal),
> `docs/research/speaker-diarization-frontier-2026-06.md`.

## Context

MacParakeet meeting recording already produces a live transcript preview and a
canonical final transcript after stop. The final transcript is built from
durable source files, not from the mixed playback artifact:

- microphone source is source-attributed to `Me`
- system source is transcribed separately and may be diarized after stop
- final post-stop reconciliation is the durable transcript truth

ADR-010 originally rejected streaming diarization because file transcription is
batch-oriented and the offline FluidAudio pipeline is more accurate. The pinned
FluidAudio dependency now exposes public streaming diarizers, including
`LSEENDDiarizer`. Its docs describe LS-EEND as a streaming diarizer with
variable speaker slots, 8 kHz input, 100 ms frame duration, step-size variants,
and reported AMI SDM DER around 20.7% for the documented CoreML bundle.

This makes live speaker turns technically possible. It does not make them final
truth.

## Proposal

Add live speaker labels only as a tentative, feature-flagged meeting-preview
experiment. The canonical transcript remains the existing post-stop batch path:
source-separated ASR plus final offline system-side diarization.

The first experiment should:

- run on the isolated system stream, not the mixed `meeting.m4a`
- keep microphone source attribution as `Me`
- use FluidAudio `LSEENDDiarizer` before Sortformer because LS-EEND has variable
  speaker slots and avoids Sortformer's fixed four-speaker shape
- render labels as tentative in the live transcript preview
- discard or reconcile live labels at stop; never let them overwrite final
  assignments without reprocessing
- remain local-only and default off

This ADR does not propose live cross-meeting identity. Live labels are anonymous
turn labels such as `Speaker 1?`, not remembered names like "Alice", unless a
future accepted identity ADR defines explicit live suggestion behavior.

## Product Contract

Live speaker labels are a navigation aid while the meeting is happening. They
must not imply final accuracy.

- Live labels use tentative visual treatment and copy.
- Exports, artifacts, and CLI output use final post-stop speaker assignments.
- If the live and final speakers disagree, final wins.
- If live diarization fails, meeting recording and live transcript preview
  continue without speaker labels.
- Live speaker models must not be part of default onboarding or readiness until
  the feature is accepted and enabled.

## Architecture

Introduce a `LiveSpeakerPreview` layer only after this ADR is accepted.

Suggested flow:

```text
system audio samples
  -> live STT preview path
  -> LiveSpeakerPreview(LSEENDDiarizer)
  -> tentative live turns
  -> live transcript renderer

stop recording
  -> durable microphone/system source files
  -> canonical post-stop ASR + offline diarization
  -> persisted transcript, artifacts, exports
```

The live layer should not sit inside `TranscriptionService`. It belongs next to
meeting live-preview orchestration, with cancellation and model-lifecycle rules
that match the meeting recording flow.

Model ownership must be separate from the STT runtime scheduler unless and until
we have measured contention. Speaker diarization is not ASR, but the UI may need
one readiness state that explains whether live labels are available.

## Evaluation Gates

Before enabling beyond an internal flag, benchmark:

- latency from speech to visible tentative speaker change
- runtime and memory while Parakeet/Nemotron live preview is also active
- speaker-count error on meeting-like system audio
- live-vs-final speaker assignment agreement
- behavior on overlap, silence, music, and noisy calls
- failure recovery when the streaming diarizer throws or is cancelled
- no final transcript mutation from live labels

The benchmark should include source-separated meeting fixtures. Mixed-audio
results are not enough because the product path is source-aware.

## Consequences

### Positive

- Users can skim live remote-speaker turns during a meeting instead of waiting
  for finalization.
- The experiment stays Swift/CoreML/local by using the existing FluidAudio
  dependency.
- Keeping live labels tentative preserves the trustworthy final transcript
  contract.

### Negative

- Live labels add model lifecycle, latency, and UI-state complexity to the most
  time-sensitive meeting path.
- Streaming diarization is expected to be less accurate than final offline
  diarization.
- The product can appear more intelligent than it really is unless tentative
  state is obvious and final output is clearly canonical.

## Rejected Alternatives

### Make Live Labels Final

Rejected. Final transcript quality depends on durable source files and the
offline batch pass. Live diarization is a preview aid only.

### Run Streaming Diarization On `meeting.m4a`

Rejected. The mixed playback artifact throws away source truth. The first live
experiment should use the isolated system stream and preserve `Me` from the
microphone source.

### Sortformer First

Rejected for the first experiment. Sortformer is useful for known <=4-speaker
low-latency scenarios, but its fixed speaker shape is the wrong default for
general meetings.

### Identity-Aware Live Names

Deferred to ADR-026 or a successor. Live anonymous labels and persistent speaker
identity have different privacy, consent, and wrong-name risks.
