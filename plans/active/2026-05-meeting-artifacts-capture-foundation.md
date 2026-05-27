# Meeting Artifacts Capture Foundation

> Status: ACTIVE PLAN
> Date: 2026-05-26
> Scope: durable screenshots, images, and attachments captured with a meeting.

## Problem

Meeting recording currently captures audio, transcript text, live typed notes,
and prompt/chat outputs. That is enough for many meetings, but it misses an
important capture case: the user needs to preserve the screen, image, or file
that made the conversation meaningful.

Most meetings should stay simple:

```text
userNotes: "follow up with QA"
artifacts: []
```

But some meetings need richer context:

```text
userNotes: "bug repro is in the screenshot"
artifacts:
  - screenshot of the failing dialog
  - customer log file
  - design comp image
```

Do not turn `Transcription.userNotes` into a rich document model. Notes should
remain plain text. Add a separate artifact foundation that can support richer
capture without complicating the common case.

## Goals

- Keep `Transcription.userNotes` as plain text meeting notes.
- Add a durable `MeetingArtifact` foundation for screenshots, images, and file
  attachments.
- Store artifact metadata in SQLite and artifact bytes on disk.
- Allow artifacts to be captured during a live meeting before the final
  `Transcription` row exists.
- Attach session artifacts to the finalized transcription after successful
  meeting transcription or recovery.
- Keep artifacts inside the existing app-owned meeting session folder so
  deletion/recovery/export can reason about the whole meeting as one unit.
- Make the foundation usable by future UI surfaces: screenshot button, paste,
  drag/drop, attachment strip, timeline, export, OCR, Ask, and vision models.
- Preserve MacParakeet's local-first privacy posture. Capturing an artifact must
  not imply that image/file bytes are sent to an LLM.

## Non-Goals

- Do not implement notes-first summary behavior in this plan.
- Do not replace `userNotes` with a rich-text editor.
- Do not store image or file blobs in SQLite.
- Do not add cloud sync, accounts, or hosted artifact storage.
- Do not add continuous screen recording or automatic screenshot capture.
- Do not automatically send raw images/files to LLM providers.
- Do not generalize into a cross-app document vault or screen-memory product.
- Do not rename the existing `summaries` table or prompt-result model.

## Current Architecture To Preserve

Important existing facts:

- `MeetingRecordingService.startRecording` creates a UUID `sessionID` and a
  session folder under `AppPaths.meetingRecordingsDir`.
- A live meeting is recoverable through that folder and `recording.lock`; there
  is no `transcriptions` row while the meeting is still being captured.
- `TranscriptionService.transcribeMeeting(recording:)` creates the processing
  `Transcription` row after stop, then updates it to completed/error.
- `MeetingRecordingRecoveryService` can recover an interrupted session from the
  session folder and lock file.
- `Transcription.userNotes` is canonical for typed notes; `notes.md` is a
  finalize/recovery snapshot only.
- `TranscriptionAssetCleanup` removes the whole app-owned meeting folder when a
  meeting transcription is deleted.
- Database changes live in inline GRDB migrations in `DatabaseManager`; the
  data-model spec and database README must be updated with any schema change.
- One table means one repository. Cross-table joins belong in services.

The artifact design must work with this lifecycle instead of forcing a
`Transcription` row to exist at recording start.

## Data Model Decision

Add a new `meeting_artifacts` table and a matching `MeetingArtifact` Swift model.
Artifacts are session-first and transcription-second:

- `meetingSessionId` is non-null and set as soon as an artifact is captured.
- `transcriptionId` is nullable while a meeting is live or awaiting recovery.
- `transcriptionId` is filled only after a meeting transcription completes
  successfully, or after recovery finds an already-completed transcription.

This avoids a premature `meeting_sessions` database table while still giving
artifacts a stable live parent: the same `sessionID` already used by the meeting
folder and `recording.lock`.

Proposed schema:

```sql
CREATE TABLE meeting_artifacts (
    id TEXT PRIMARY KEY,
    meetingSessionId TEXT NOT NULL,
    transcriptionId TEXT
        REFERENCES transcriptions(id) ON DELETE CASCADE,
    kind TEXT NOT NULL,
    source TEXT NOT NULL,
    relativePath TEXT NOT NULL,
    originalFilename TEXT,
    mimeType TEXT NOT NULL,
    byteCount INTEGER,
    sha256 TEXT,
    title TEXT,
    textContent TEXT,
    capturedAt TEXT NOT NULL,
    transcriptOffsetMs INTEGER,
    includeInContext INTEGER NOT NULL DEFAULT 1,
    metadataJSON TEXT,
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    CHECK (relativePath NOT LIKE '/%'),
    CHECK (kind IN ('image', 'fileAttachment')),
    CHECK (source IN ('user', 'system'))
);

CREATE INDEX idx_meeting_artifacts_session_captured_at
    ON meeting_artifacts(meetingSessionId, capturedAt);

CREATE INDEX idx_meeting_artifacts_transcription_captured_at
    ON meeting_artifacts(transcriptionId, capturedAt);

CREATE INDEX idx_meeting_artifacts_kind_captured_at
    ON meeting_artifacts(kind, capturedAt);
```

### Field Semantics

- `id`: artifact UUID.
- `meetingSessionId`: the `MeetingRecordingOutput.sessionID` / live
  `MeetingRecordingService.Session.id`.
- `transcriptionId`: nullable FK to `transcriptions.id`; set after successful
  finalization/recovery.
- `kind`: stable product category. Start with only `image` and
  `fileAttachment`; do not make screenshot a schema kind. A screenshot is an
  image artifact with screenshot capture metadata.
- `source`: who/what supplied the artifact. Initial explicit user actions write
  `user`; future automatic contextual capture can write `system`. Do not add
  `app` or `agent` until a concrete write path needs that provenance.
- `relativePath`: path relative to the session folder, not an absolute path.
  Example: `artifacts/<artifact-id>/original.png`.
- `originalFilename`: user-facing filename when imported/dropped. Screenshots
  can use a generated name.
- `mimeType`: detected UTType/MIME value, never inferred from untrusted display
  text alone.
- `byteCount` and `sha256`: optional integrity/debug metadata. Hashing can run
  after the file is copied; do not block capture UI on a large-file hash.
- `title`: optional user/UI label.
- `textContent`: optional OCR, extracted text, caption, or user description.
  This is the field future Ask/summary context should consume first.
- `capturedAt`: wall-clock time of capture.
- `transcriptOffsetMs`: elapsed meeting time at capture, nullable for artifacts
  added after finalization or imported without a live timeline.
- `includeInContext`: eligibility flag for future context assembly. It does not
  mean raw bytes may be sent to an LLM. Initial context assembly should include
  `textContent` only unless the user explicitly enables a vision-capable path.
- `metadataJSON`: small local metadata such as `captureMethod` (`screenshot`,
  `paste`, `dragDrop`, `filePicker`), pixel dimensions, source app bundle ID,
  display ID bucket, image EXIF subset, or extraction diagnostics. Keep
  capture method here in v1 rather than promoting it to a column. Do not put
  transcript text, file bytes, or large OCR payloads here.

## File Layout

Store artifact bytes under the existing meeting session folder:

```text
~/Library/Application Support/MacParakeet/meeting-recordings/<session-id>/
|-- microphone.m4a
|-- system.m4a
|-- meeting.m4a
|-- meeting-recording-metadata.json
|-- notes.md
|-- recording.lock
|-- chunks/
`-- artifacts/
    `-- <artifact-id>/
        |-- original.<safe-extension>
        `-- preview.jpg              # future, optional
```

Rules:

- Copy imported files into the session folder; do not keep external bookmarks as
  the canonical artifact.
- Never persist absolute artifact paths in the database.
- Sanitize display filenames separately from storage names.
- Use an atomic write/copy strategy: write to a temporary path inside the same
  artifact folder, then rename into place.
- Insert the database row only after the file write succeeds.
- If the database insert fails after the file write, remove the just-written
  artifact folder.
- If a file is missing when fetching, surface the artifact as broken metadata
  rather than crashing the meeting/transcription view.

## Core Types

Add these in `MacParakeetCore`:

```swift
public struct MeetingArtifact: Codable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case image
        case fileAttachment
    }

    public enum Source: String, Codable, Sendable {
        case user
        case system
    }

    public var id: UUID
    public var meetingSessionId: UUID
    public var transcriptionId: UUID?
    public var kind: Kind
    public var source: Source
    public var relativePath: String
    public var originalFilename: String?
    public var mimeType: String
    public var byteCount: Int64?
    public var sha256: String?
    public var title: String?
    public var textContent: String?
    public var capturedAt: Date
    public var transcriptOffsetMs: Int?
    public var includeInContext: Bool
    public var metadataJSON: String?
    public var createdAt: Date
    public var updatedAt: Date
}
```

Add `MeetingArtifactRepositoryProtocol` and `MeetingArtifactRepository` with:

- `save(_:)`
- `fetch(id:)`
- `fetchAll(sessionId:)`
- `fetchAll(transcriptionId:)`
- `attachSessionArtifacts(sessionId:toTranscriptionId:)`
- `delete(id:)`
- `deleteAll(sessionId:)`
- `deleteAll(transcriptionId:)`
- `count(sessionId:)`

Use GRDB's Codable-aware APIs for UUID primary-key and FK predicates. Do not use
raw SQL `WHERE id = ?` with `uuid.uuidString`.

Add `MeetingArtifactFileStore` with:

- create artifact directory
- copy/write original bytes
- sanitize file extension from UTType/MIME/original name
- compute optional byte count/hash
- resolve `relativePath` against a session folder
- remove one artifact folder
- remove all artifact folders for a session

Keep file I/O outside the repository. The repository owns metadata. The file
store owns bytes.

## Lifecycle Integration

### Live Capture

When a meeting is active, a future UI/capture service should add artifacts using
the current meeting `sessionID` and folder URL:

1. Validate the meeting is active.
2. Generate `artifactID`.
3. Write bytes under `folderURL/artifacts/<artifactID>/`.
4. Insert `meeting_artifacts` row with:
   - `meetingSessionId = sessionID`
   - `transcriptionId = nil`
   - `relativePath = artifacts/<artifactID>/original.<ext>`
   - `capturedAt = Date()`
   - `transcriptOffsetMs = elapsed meeting time if available`
5. Publish an in-memory update for UI.

Do not write artifact metadata into `recording.lock`. The lock file is for
recording recovery state and small user notes; large or frequently changing
artifact metadata belongs in the database.

### Stop and Transcription

`MeetingRecordingService.stopRecording()` should not attach artifacts because it
does not own the final transcription row. The right attachment point is after
`TranscriptionService.transcribeMeeting(recording:)` has successfully completed
and saved the completed transcription.

Future coding agent should wire this carefully:

1. Keep artifacts `transcriptionId = nil` while transcription is processing.
2. After final `Transcription` save succeeds with `.completed`, call
   `MeetingArtifactRepository.attachSessionArtifacts(sessionId:toTranscriptionId:)`.
3. Only after that should the normal successful path delete `recording.lock`.

Do not attach artifacts to the initial `.processing` transcription row. If STT
fails, the lock remains recoverable and `MeetingRecordingRecoveryService` may
delete incomplete transcriptions before retrying. Session-only artifacts should
survive that retry.

Attachment failure should not invalidate the completed transcription, but it
must prevent lock deletion. The existing recovery path can then find the
completed transcription by `meeting.m4a`, retry artifact attachment, and delete
the lock after metadata is consistent. Deleting the lock before artifact
attachment would strand `transcriptionId = nil` rows with no natural retry path.

### Recovery

Recovery needs two paths:

- If recovery creates a new completed transcription, attach all artifacts with
  matching `meetingSessionId` before deleting the lock.
- If recovery finds an existing completed transcription for the session's
  `meeting.m4a`, attach any still-unattached artifacts to that transcription
  before deleting the lock.

`MeetingRecordingRecoveryService.completeExistingTranscription` and
`completeRecovery` are the likely attachment points. They already centralize the
"safe to delete lock" decision after finding or saving a completed
transcription.

Discarding a recoverable session should remove:

- artifact rows for `meetingSessionId`
- artifact files under the session folder
- existing session audio/metadata folder, as today

### Cancel / Failed Start / No Audio

When a meeting is cancelled or failed before it becomes a saved transcription,
delete session artifacts by `meetingSessionId` before removing the folder. This
covers:

- `MeetingRecordingService.cancelRecording()`
- `cleanupFailedStart(folderURL:)`
- `stopRecording()` path that throws `MeetingAudioError.noAudioCaptured`

If a user captured only artifacts but no audio, current product semantics still
treat the meeting as no recording. Do not silently create a transcription row
just to preserve artifacts in v1. That behavior would be a separate product
decision.

### Deletion

The current app-owned meeting deletion removes the whole session folder based on
`Transcription.filePath`. That will remove artifact bytes if they live under the
session folder. The database still needs explicit coverage:

- `transcriptionId` FK uses `ON DELETE CASCADE`.
- Tests should verify deleting a meeting transcription removes artifact rows.
- Tests should verify `TranscriptionAssetCleanup.removeOwnedAssets` removes the
  artifact files because they live under the same app-owned folder.

### Retranscription

Saved meeting retranscription should not duplicate artifacts. Artifacts are
capture context, not STT output. Keep them attached to the meeting transcription
row and do not rewrite `capturedAt`, `relativePath`, or `source` during
retranscription.

## Context And AI Policy

Artifacts are captured locally. Future Ask/summary context should assemble them
in this order:

1. `userNotes`
2. transcript text
3. selected artifact `textContent`
4. selected artifact metadata such as title, filename, captured time, and kind
5. raw image/file bytes only when the user explicitly chooses a vision-capable
   provider path

`includeInContext` means "eligible to include in context assembly." It is not a
permission to upload raw files. The first implementation should treat images and
binary files as metadata-only unless OCR/caption text exists.

Telemetry must never include artifact text, filenames, file paths, image bytes,
or OCR output. Acceptable telemetry is bucketed counts and sizes:

```text
meeting_artifacts_added count=<n> kinds=<bucketed> total_size_bucket=<bucket>
```

## Export Policy

Initial export can be metadata-only. A later export pass can support:

```text
Meeting Export/
|-- transcript.md
|-- notes.md
|-- artifacts.json
`-- artifacts/
    `-- <artifact files>
```

Do not block the schema on export UI. The schema should already preserve enough
metadata for export to be deterministic later.

## Implementation Phases

### Phase 1: Core Foundation Only

- Add `MeetingArtifact` model.
- Add `meeting_artifacts` migration in `DatabaseManager`.
- Update `spec/01-data-model.md`.
- Update `Sources/MacParakeetCore/Database/README.md`.
- Add `MeetingArtifactRepository`.
- Add `MeetingArtifactFileStore`.
- Add repository/file-store tests.
- Add lifecycle cleanup hooks for cancel, failed start, no-audio stop, recovery
  discard, and transcription deletion.

No visible UI is required in Phase 1.

### Phase 2: Live Meeting Capture API

- Add a small meeting artifact capture service that takes `sessionID`,
  `folderURL`, and elapsed meeting time.
- Support adding an image/file from bytes or source URL supplied by the app UI.
- Publish updates to the live meeting panel view model.
- Attach session artifacts to the completed transcription after successful
  finalization/recovery.

### Phase 3: Minimal UI

- Add an attachment strip or list to the meeting panel.
- Support paste/drop image or file into the live meeting panel.
- Add a screenshot button only if the permission/ScreenCaptureKit path is clean.
- Show broken/missing artifact state without crashing.
- Keep notes as plain text.

### Phase 4: Context, OCR, And Export

- Add optional OCR/text extraction into `textContent`.
- Let Ask include selected artifact text.
- Let prompt generation include selected artifact text.
- Add export packaging for artifact files.
- Add provider-gated vision support only after text-context paths are stable.

## Test Plan

### Database

- Empty DB migrates with `meeting_artifacts`.
- Repository saves/fetches artifact by ID, session, and transcription.
- `attachSessionArtifacts` updates only matching session rows with nil or matching
  transcription IDs.
- Deleting a transcription cascades artifact rows.
- UUID lookups use GRDB key/filter APIs, not raw string equality.
- `relativePath` rejects absolute paths in tests.

### File Store

- Writes image/file bytes under `artifacts/<id>/original.<ext>`.
- Sanitizes unsafe filenames and path traversal attempts.
- Removes just-written files if DB save fails in the capture service.
- Resolves relative paths only under the session folder.
- Handles missing files as broken artifacts, not fatal crashes.

### Lifecycle

- Artifact captured during live meeting starts as `transcriptionId == nil`.
- Successful meeting finalization attaches artifacts to the completed
  transcription.
- Failed STT leaves artifacts session-only and recoverable.
- Recovery-created transcription attaches session artifacts.
- Recovery path that finds an existing completed transcription attaches leftover
  session artifacts.
- Cancel removes session artifact rows and files.
- No-audio stop removes session artifact rows and files.
- Recovery discard removes session artifact rows and files.
- Deleting a completed meeting removes artifact rows and files.

### Privacy / Context

- Artifact telemetry contains only counts/size buckets/kind buckets.
- Ask/summary context includes `textContent` only; no raw bytes without an
  explicit future vision path.
- Metadata JSON does not contain transcript text, file bytes, or OCR payloads.

### Commands

For the implementation PR:

```bash
swift test --filter MeetingArtifact
swift test --filter Database
swift test --filter MeetingRecording
swift test
```

## Open Questions For Implementation

- Exact per-artifact and per-meeting size limits. Suggested starting point:
  warn above 25 MB per artifact, hard-stop above 100 MB per artifact, and show
  meeting-folder size only in storage/settings later.
- Whether user-triggered screenshots default `includeInContext` to true for
  OCR/text only, or false until the user explicitly opts in.
- Whether post-finalization artifact add/edit is in scope for the first UI pass.
  The schema supports it, but the first implementation should bias toward live
  capture only.
- Whether `MeetingArtifact` should eventually generalize to
  `TranscriptionArtifact` for file/YouTube transcripts. Do not generalize now;
  meeting capture is the concrete product need.

## First Coding-Agent Prompt

Implement Phase 1 of `plans/active/2026-05-meeting-artifacts-capture-foundation.md`.
Keep `Transcription.userNotes` as plain text. Add a `meeting_artifacts` GRDB
table, `MeetingArtifact` model, one-table repository, and app-owned file store
for artifact bytes under each meeting session folder. Preserve the existing
meeting lifecycle: artifacts are keyed by `meetingSessionId` while live/recoverable
and attach to `transcriptionId` only after successful transcription or recovery.
Do not add UI, OCR, vision, rich notes, or notes-first summaries in Phase 1.
Update `spec/01-data-model.md` and `Sources/MacParakeetCore/Database/README.md`,
then run focused database/artifact/meeting tests plus full `swift test`.
