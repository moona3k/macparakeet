# Meeting Artifact Naming v2

## Status

Future cleanup. Do not include in the 0.6.25 release unless a separate product
decision reopens artifact naming as release scope.

## Problem

Current meeting folders use:

- `microphone.m4a` for raw microphone capture.
- `microphone-cleaned.m4a` for the optional AEC-cleaned microphone artifact.

That is stable and correct, but the raw filename is less explicit than the
derived filename. `microphone-raw.m4a` paired with `microphone-cleaned.m4a`
would be clearer for debugging, artifact export, CLI output, and future docs.

## Proposed Direction

Adopt `microphone-raw.m4a` for new recordings while keeping old
`microphone.m4a` folders fully readable.

Do not bulk-rename existing user files.

## Required Shape

1. Add central filename constants for:
   - `microphone-raw.m4a`
   - legacy `microphone.m4a`
   - `system.m4a`
   - `meeting.m4a`
   - `microphone-cleaned.m4a`
2. Make new recordings write `microphone-raw.m4a`.
3. Make archive/recovery/loading prefer `microphone-raw.m4a` and fall back to
   legacy `microphone.m4a`.
4. Keep AEC output as `microphone-cleaned.m4a`.
5. Make cleanup/retention delete both raw mic names.
6. Update `spec/contracts/meeting-artifacts-v1.md` or create a v2 contract
   section that documents backward-compatible loading.
7. Update CLI/export JSON docs and tests if artifact paths surface the raw mic
   filename.

## Test Surfaces

- `MeetingAudioStorageWriter`
- `MeetingRecordingOutput.loadArchived`
- meeting recovery
- meeting artifact store / markdown renderer
- transcription asset cleanup
- CLI `meetings artifact` / export JSON
- final meeting STT source resolution

## Non-Goals

- Do not rename `meeting.m4a`; it remains playback/export.
- Do not rename `microphone-cleaned.m4a`; the name accurately describes the
  derived AEC-cleaned mic side.
- Do not migrate existing folders in place.
