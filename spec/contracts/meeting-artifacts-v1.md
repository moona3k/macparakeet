# Meeting Artifacts v1

> Status: ACTIVE - stable local meeting session artifact contract.

## Purpose

A meeting session folder is the durable local view of a recorded meeting. It is
safe for Finder actions, CLI automation, hooks, support diagnostics, and future
agent workflows to inspect. The database row remains canonical for meeting
identity and current metadata; files are refreshed views of that row and its
related prompt results.

For meeting rows, `transcriptions.meetingArtifactFolderPath` is the durable
folder locator. `transcriptions.filePath` is only the mixed-audio
playback/export path and may be cleared by user deletion or retention.

## Producers

- `MeetingRecordingService`: creates session folders and source audio.
- `MeetingTranscriptFinalizer` / meeting finalization: completes the DB row and
  final transcript.
- `MeetingArtifactStore`: materializes `manifest.json`, `transcript.json`,
  `notes.md`, `prompt-results.json`, and `prompt-results/*.md`.
- `macparakeet-cli meetings artifact`: refreshes and returns the artifact
  snapshot.
- Meeting notes and prompt-result write paths: refresh artifact views after
  user notes or agent-authored results change.

## Consumers

- Library, Meetings, and detail-view "Open Meeting Folder" / "Copy Artifact
  Folder Path" actions.
- Audio-specific "Show Audio in Finder" / "Save Audio As..." actions while
  retained meeting audio is still available.
- `macparakeet-cli meetings artifact` and `--envelope` output.
- Meeting automation hooks through `MACPARAKEET_ARTIFACT_DIR` and
  `MACPARAKEET_ARTIFACT_MANIFEST`.
- Support diagnostics and future local agent workflows.

## Stable Folder Entries

The v1 folder can contain these stable filenames:

- `meeting.m4a`: mixed playback/export audio referenced by
  `transcriptions.filePath` while retained.
- `microphone.m4a`: optional source mic audio.
- `system.m4a`: optional source system audio.
- `meeting-recording-metadata.json`: optional source-alignment and engine
  sidecar.
- `manifest.json`: folder manifest.
- `transcript.json`: transcript view.
- `notes.md`: optional user notes view. Removed when notes are empty or nil.
- `prompt-results.json`: JSON array of prompt-result records.
- `prompt-results/`: refreshed directory of per-result Markdown files.
- `prompt-results/*.md`: filenames use a stable two-digit 1-based index prefix
  plus sanitized prompt-result name.

## Stable JSON Fields

`MeetingArtifactSnapshot` and CLI artifact output keep these fields stable:

- `schema`: `com.macparakeet.meeting-session`
- `schemaVersion`: `1`
- `generatedAt`
- `meetingID`
- `title`
- `folderPath`
- `manifestPath`
- `transcriptPath`
- `notesPath`
- `promptResultsPath`
- `promptResultsDirectoryPath`
- `promptResultCount`

`manifest.json` keeps:

- `schema`
- `schemaVersion`
- `generatedAt`
- `meeting`
- `files`
- `promptResults`

`manifest.files` keeps path fields for `folderPath`, `mixedAudioPath`,
`microphoneAudioPath`, `systemAudioPath`, `metadataPath`, `manifestPath`,
`transcriptPath`, `notesPath`, `promptResultsPath`, and
`promptResultsDirectoryPath`.

`transcript.json` keeps meeting essentials: `id`, `title`, timestamps,
`durationMs`, `status`, raw/clean/transcript text, word/speaker/diarization
fields, `userNotes`, language/engine attribution, `sourceType`,
`recoveredFromCrash`, and `isTranscriptEdited`.

## Non-Stable Fields

- `generatedAt` changes on every materialization.
- Absolute paths vary by user, configured meeting artifact folder, and DEBUG
  smoke-state root.
- Prompt-result ordering follows the supplied prompt-result input order.
- Prompt-result Markdown body can gain additive sections when the
  corresponding JSON fields remain readable.

## Versioning And Compatibility

The current schema is v1. Additive fields and new optional files can remain v1
when old consumers can ignore them. Renaming or removing stable filenames or
fields requires a schema-version bump and CLI/changelog notes.

The database row stays canonical. Do not teach features to treat the folder as
the source of truth for mutable meeting metadata unless the contract is updated
with a migration and conflict-resolution rule.

Audio retention and "Delete Audio Only" clear `transcriptions.filePath` but
must preserve `transcriptions.meetingArtifactFolderPath` and leave the folder's
non-audio artifact files in place. Full meeting deletion removes the artifact
folder even when retained audio was already deleted.

## Tests that enforce this

- `MeetingArtifactStoreTests`
- `MeetingsCommandTests`
- `HistoryCommandTests`
- `MeetingAudioRetentionSweeperTests`
- `TranscriptionDeletionCleanupTests`
- `TranscriptionRepositoryTests`

Focused coverage pins stable filenames, schema/schemaVersion, manifest path
references, transcript essentials, `notes.md` deletion, refreshed
`prompt-results/` contents, non-meeting rejection, CLI artifact envelope fields,
retained-out audio, full deletion after audio detach, and artifact-folder path
preservation.

## When this changes

Update this file, `spec/01-data-model.md`, `Sources/CLI/CHANGELOG.md` when CLI
users are affected, and the focused XCTest coverage in the same PR.
