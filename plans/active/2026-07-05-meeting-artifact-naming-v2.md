# Meeting Artifact Naming v2

## Status

- **Status:** IMPLEMENTED on `feat/meeting-artifact-naming-v2` (2026-07-05);
  verify acceptance criteria on `main`, then archive.
- **Priority:** P1 while the meeting artifact contract is still new and cheap to
  correct.
- **Decision date:** 2026-07-05.
- **Product decision:** Update the current v1 artifact contract in place. Do not
  preserve compatibility with the first-pass filenames/fields; this surface is
  still brand new and should be made clear before users or agents depend on it.
- **Boundary:** Naming/contract/docs/tests only. Do not change AEC quality,
  meeting capture behavior, final STT routing policy, retention policy, or
  speaker rename behavior.

## Problem

Current meeting folders use:

- `microphone.m4a` for raw microphone capture.
- `microphone-cleaned.m4a` for the optional AEC-cleaned microphone artifact.
- `system.m4a` for raw system capture.
- `meeting.m4a` for the mixed playback/export artifact.

That first-pass naming is functional, but it is not role-explicit enough for the
artifact folder to become a user/agent surface. The worst ambiguity is the mic
pair: `microphone.m4a` is raw, while `microphone-cleaned.m4a` is derived. The
mixed playback file also reads like the canonical meeting audio even though it
is not the final STT input.

Because this contract is still new, keep the implementation simple: rename the
contract now instead of carrying legacy fallback code.

## Proposed Direction

Adopt role-explicit v1 filenames:

| Role | Filename |
|------|----------|
| Raw microphone source | `microphone-raw.m4a` |
| Cleaned microphone source | `microphone-cleaned.m4a` |
| Raw system source | `system-raw.m4a` |
| Mixed playback/export audio | `meeting-playback.m4a` |

Adopt role-explicit v1 JSON/frontmatter fields:

| Role | Field |
|------|-------|
| Raw microphone source | `rawMicrophoneAudioPath` |
| Cleaned microphone source | `cleanedMicrophoneAudioPath` |
| Raw system source | `rawSystemAudioPath` |
| Mixed playback/export audio | `playbackAudioPath` |

Do not add fallback reads for the old names. Do not bulk-rename existing local
folders. Existing development artifacts created with the first-pass names may be
discarded or re-recorded.

## Required Shape

1. Add central filename constants for:
   - `microphone-raw.m4a`
   - `microphone-cleaned.m4a`
   - `system-raw.m4a`
   - `meeting-playback.m4a`
2. Make meeting capture write the role-explicit filenames.
3. Make archive/recovery/loading expect the role-explicit filenames only.
4. Make AEC cleaned output remain `microphone-cleaned.m4a`.
5. Make cleanup/retention delete the role-explicit managed audio files.
6. Update `spec/contracts/meeting-artifacts-v1.md` in place; do not create a v2
   schema only for this pre-hardening rename.
7. Update `spec/05-audio-pipeline.md`, `spec/01-data-model.md`, ADR text, and
   plan references that describe the stable artifact names.
8. Update manifest, `meeting.md` frontmatter, CLI JSON/envelope output, and
   `spec --json` docs to use the role-explicit path fields.
9. Update tests that assert filenames or artifact JSON/frontmatter fields.
10. Run focused tests for meeting artifact, cleanup/retention, recovery, and CLI
    artifact/export surfaces.

## Acceptance Criteria

- A new dual-source meeting folder contains `microphone-raw.m4a`,
  `system-raw.m4a`, `microphone-cleaned.m4a` when viable, and
  `meeting-playback.m4a`.
- `transcriptions.filePath` points to `meeting-playback.m4a` while retained.
- Final meeting STT uses `rawMicrophoneAudioPath` or
  `cleanedMicrophoneAudioPath` according to the existing cleaned-mic readiness
  gate; it never treats `playbackAudioPath` as the authoritative final-STT
  source.
- `manifest.json`, `meeting.md` frontmatter, `macparakeet-cli meetings show`,
  `meetings artifact`, and `meetings export --format json` expose the new field
  names only.
- Retention/audio-only deletion removes all managed audio files with the new
  names and preserves non-audio artifacts.
- The v1 contract docs list only the role-explicit names and do not document
  legacy fallback.

## Test Surfaces

- `MeetingAudioStorageWriter`
- `MeetingRecordingOutput.loadArchived`
- meeting recovery
- meeting artifact store / markdown renderer
- transcription asset cleanup
- CLI `meetings artifact` / export JSON
- final meeting STT source resolution

## Non-Goals

- Do not add compatibility fallbacks for `microphone.m4a`, `system.m4a`, or
  `meeting.m4a`.
- Do not migrate existing folders in place.
- Do not change `microphone-cleaned.m4a`; the name accurately describes the
  derived AEC-cleaned mic side.
- Do not change the database schema solely for the rename unless the current
  `filePath` / `meetingArtifactFolderPath` model cannot represent the new names.
- Do not broaden this into artifact-folder-as-source-of-truth work.
