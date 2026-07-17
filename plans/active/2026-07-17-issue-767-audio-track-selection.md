# Issue 767: Multi-audio-track selection

> Status: ACTIVE
> Issue: https://github.com/moona3k/macparakeet/issues/767
> Branch: `feat/767-audio-track-selection`

## Goal

Let file transcription users choose which embedded audio track is sent to
speech-to-text. Preserve the current zero-friction path for ordinary files,
make the choice explicit only when a local file contains multiple audio
tracks, persist it with the transcription, and expose the same capability to
the CLI.

## Context zone

In scope:

- Discover audio tracks in supported local audio/video containers with the
  bundled FFmpeg runtime.
- Continue immediately for exactly one audio track; show an app picker only
  for two or more tracks; report a clear error for no audio tracks.
- Convert an explicitly selected track with FFmpeg's `0:a:N` audio-stream
  ordinal mapping.
- Apply one selected ordinal across a batch's multi-track files while leaving
  single-track files automatic; fail a multi-track file clearly when that
  ordinal does not exist and never silently fall back to another track.
- Persist the zero-based audio-stream ordinal and reuse it for retranscription.
- Add the CLI's user-facing, one-based `--audio-track` option for local files
  and folders.

Must not change:

- Single-track file behavior, URL/download transcription, meeting recording,
  dictation, STT model selection, normalized WAV format, or local-first data
  handling.
- Existing public service calls and test doubles that do not request an
  explicit track.
- Batch ordering and sequential execution.

Governing surfaces:

- Issue #767 and its comments.
- `spec/02-features.md`, `spec/04-ui-patterns.md`,
  `spec/05-audio-pipeline.md`, and `spec/01-data-model.md`.
- `AudioFileConverter`, `AudioProcessor`, `TranscriptionService`,
  `TranscriptionViewModel`, `TranscribeView`, and `TranscribeCommand`.

## Implementation

1. Add typed audio-track discovery and selection in `MacParakeetCore`, with an
   isolated FFmpeg stderr parser and numbered fallback labels.
2. Make file conversion accept an optional audio-stream ordinal and emit
   `-map 0:a:N` only when explicitly selected.
3. Route selection through file transcription, persist it with a new nullable
   transcription column, and preserve it during retranscription.
4. Add view-model preflight state and a conditional SwiftUI selection sheet;
   reuse one choice for sequential batches.
5. Add and validate the CLI's one-based `--audio-track` option, rejecting URL
   and podcast lanes where it cannot be honored.
6. Update the feature, UI, audio-pipeline, data-model, CLI, and boundary
   contract documentation.

## Verification

- Red/green focused tests for FFmpeg mapping and track discovery.
- Red/green focused tests for single-track continuation, multi-track waiting,
  cancellation, batch reuse, and missing-ordinal failure behavior.
- Migration/model/retranscription persistence tests.
- CLI parsing, validation, and forwarding tests.
- Focused suites while iterating; one full `swift test` run as the final local
  gate.
- Format/lint, standards review, specification review, no-mistakes gate, PR
  CI, and unresolved-review-thread check before declaring merge-ready.

## Current progress

- [x] Reproduced the reported default-track failure with a synthetic
  multi-audio MKV and verified explicit `-map 0:a:1` selects the intended
  stream.
- [x] Confirmed the bug remains on `origin/main` and the current release line.
- [x] Agreed the conditional UI and one-based user / zero-based internal
  selection semantics.
- [x] Core discovery and conversion mapping.
- [x] App flow, batch behavior, persistence, and retranscription.
- [x] CLI and documentation.
- [ ] Verification, review, and merge-ready PR.
