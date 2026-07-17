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
- `MeetingArtifactStore`: materializes `manifest.json`, `meeting.md`,
  `transcript.json`, `notes.md`, `prompt-results.json`, and
  `prompt-results/*.md`.
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

- `meeting-playback.m4a`: mixed playback/export audio referenced by
  `transcriptions.filePath` while retained.
- `microphone-raw.m4a`: optional source mic audio.
- `system-raw.m4a`: optional source system audio.
- `microphone-cleaned.m4a`: optional derived echo-cancelled mic (16 kHz mono),
  produced after stop from `microphone-raw.m4a` + `system-raw.m4a` when a meeting echo
  suppressor is loaded (plan #605 U3). Internal STT input for the local ("Me")
  track only after final-STT readiness/decodability gates pass, not a
  user-facing export; the raw `microphone-raw.m4a` remains the source of truth.
  Absent for single-source meetings, missing/unloaded AEC assets, render
  failures, and when the echo-path probe finds no system-audio bleed to cancel.
  Removed with the other managed audio by retention/detach.
- `meeting-recording-metadata.json`: optional source-alignment and speech-route
  sidecar. `speechEngine` is the authoritative final-transcription selection;
  optional additive `previewSpeechEngine` records the live-preview route when
  one was supported. Missing preview provenance remains valid for legacy
  folders. It may also include additive `echoSuppression` provenance with
  `reasonCode` plus optional `modelVersion`, `renderDurationMs`,
  `delayEstimateMs`, and `probeBestCorrelation` fields so shared artifact
  folders can explain cleaned-vs-raw microphone routing without app logs. It
  may also include additive `startContext` with the one-shot local start
  snapshot. `calendarEventSnapshot`, when present, is local EventKit context
  and can include attendee/organizer names and emails.
- `manifest.json`: folder manifest.
- `meeting.md`: deterministic Markdown view for users and local agents. It
  keeps YAML frontmatter with local metadata and stable sections for title,
  notes when present, transcript, prompt results when present, and artifact
  paths. Speaker labels are included only when word-level speaker alignment is
  still valid; otherwise `speakerLabelsIncluded` is `false` and the transcript
  section uses plain transcript text.
- `transcript.json`: transcript view.
- `notes.md`: optional user notes view. Removed when notes are empty or nil.
- `prompt-results.json`: JSON array of prompt-result records.
- `prompt-results/`: refreshed directory of per-result Markdown files.
- `prompt-results/*.md`: filenames use a stable two-digit 1-based index prefix
  plus sanitized prompt-result name.

New recordings write the role-explicit audio filenames above. For read
compatibility with folders created before the in-place v1 audio filename
rename, readers and artifact materializers must also resolve legacy
`microphone.m4a` and `system.m4a` when the current raw-audio filename is absent.
Regenerated `manifest.json` and `meeting.md` path fields point to the actual
existing current or legacy raw-audio file. New captures must not create legacy
raw-audio filenames.

## Stable JSON Fields

`MeetingArtifactSnapshot` and CLI artifact output keep these fields stable:

- `schema`: `com.macparakeet.meeting-session`
- `schemaVersion`: `1`
- `generatedAt`
- `meetingID`
- `title`
- `folderPath`
- `manifestPath`
- `markdownPath`
- `rawMicrophoneAudioPath`
- `cleanedMicrophoneAudioPath`
- `rawSystemAudioPath`
- `playbackAudioPath`
- `transcriptPath`
- `notesPath`
- `promptResultsPath`
- `promptResultsDirectoryPath`
- `promptResultCount`
- `calendarEventSnapshot`

`manifest.json` keeps:

- `schema`
- `schemaVersion`
- `generatedAt`
- `meeting` (including optional `startContext`)
- `files`
- `promptResults`

`manifest.meeting.calendarEventSnapshot`, when present, keeps the same local
EventKit snapshot shape as `transcriptions.calendarEventSnapshot`: confidence,
event identifiers, scheduled time range, title, attendee/organizer names and
emails, meeting URL/service, and capture timestamp.

`manifest.files` keeps path fields for `folderPath`, `playbackAudioPath`,
`rawMicrophoneAudioPath`, `cleanedMicrophoneAudioPath`, `rawSystemAudioPath`,
`metadataPath`, `manifestPath`, `markdownPath`, `transcriptPath`, `notesPath`,
`promptResultsPath`, and `promptResultsDirectoryPath`.

`meeting.md` frontmatter keeps the local Markdown schema
`com.macparakeet.meeting-markdown` with `schemaVersion: 1`, meeting identity,
timestamps, duration/status/source/engine metadata, artifact/audio paths when
available, `speakerLabelsIncluded`, and `promptResultCount`. The body section
order is: title, optional notes, transcript, optional prompt results, and
artifact paths.

`transcript.json` keeps meeting essentials: `id`, `title`, timestamps,
`durationMs`, `status`, raw/clean/transcript text, word/speaker/diarization
fields, durable `transcriptSegments`, `userNotes`, language/engine attribution,
`sourceType`, `recoveredFromCrash`, `isTranscriptEdited`, and optional
`startContext` and `calendarEventSnapshot`.

`transcriptSegments` is an additive v1 field populated from the DB row when a
meeting has durable segments. Each segment keeps `id`, `startMs`, `endMs`,
`speakerId`, `speakerLabel`, `text`, and a half-open `wordRange`
(`startIndex`, `endIndexExclusive`) into the same transcript's
`wordTimestamps` array. Segment IDs are stable for that transcript version;
meeting retranscription may replace the array with newly minted segment IDs.

`startContext`, when present, keeps the recording-start snapshot:

- `triggerKind`: `manual`, `hotkey`, or `calendar_auto_start`
- `sourceMode`: configured meeting source mode at start (`microphone_only`,
  `microphone_and_system`, or `system_only`)
- `frontmostApplication`: optional object with `bundleIdentifier` and
  `localizedName`

`calendarEventSnapshot`, when present, keeps local calendar context captured at
recording start. It can include EventKit identifiers, title, scheduled
start/end, attendee/organizer names and emails, meeting URL/service, confidence,
and capture timestamp.

## Non-Stable Fields

- `generatedAt` changes on every materialization.
- Absolute paths vary by user, configured meeting artifact folder, and DEBUG
  smoke-state root.
- Prompt-result ordering follows the supplied prompt-result input order.
- Prompt-result Markdown body can gain additive sections when the
  corresponding JSON fields remain readable.

## Versioning And Compatibility

The current schema is v1. This contract absorbed the pre-hardening rename to
role-explicit audio filenames and path fields in place before external
compatibility was promised. Future additive fields and new optional files can
remain v1 when old consumers can ignore them. Future renames or removals of
stable filenames or fields require a schema-version bump and CLI/changelog
notes.

The database row stays canonical. Do not teach features to treat the folder as
the source of truth for mutable meeting metadata unless the contract is updated
with a migration and conflict-resolution rule.

Audio retention and "Remove Audio Only" clear `transcriptions.filePath` but
must preserve `transcriptions.meetingArtifactFolderPath` and leave the folder's
non-audio artifact files in place. The retention sweeper acts only on the
age-based `delete_after_days` mode. `delete_immediately` ("Remove audio after
transcription") applies at capture/finalization to new recordings and must
never retroactively remove previously saved audio — selecting it in Settings
is not consent to delete the existing library. Bulk meeting-audio cleanup removes top-level
app-managed audio files in the session folder, including canonical filenames
and other managed audio extensions, while preserving JSON/Markdown artifacts.
Full meeting deletion removes the artifact folder even when retained audio was
already deleted.

## Tests that enforce this

- `MeetingArtifactStoreTests`
- `MeetingsCommandTests`
- `HistoryCommandTests`
- `MeetingAudioRetentionSweeperTests`
- `TranscriptionDeletionCleanupTests`
- `TranscriptionRepositoryTests`

Focused coverage pins stable filenames, schema/schemaVersion, manifest path
references, `meeting.md` frontmatter/sections, transcript essentials,
`notes.md` deletion, refreshed `prompt-results/` contents, durable transcript
segments in `transcript.json`, speaker-label Markdown fallback, non-meeting
rejection, CLI artifact envelope fields, retained-out audio, full deletion
after audio detach, and artifact-folder path preservation.

## When this changes

Update this file, `spec/01-data-model.md`, `Sources/CLI/CHANGELOG.md` when CLI
users are affected, and the focused XCTest coverage in the same PR.
