# Meeting Audio Auto-Delete After N Days

**Status:** ACTIVE PLAN — not started
**Date:** 2026-06-18
**ADRs:** ADR-014/015/016 (meeting recording, concurrency, scheduler), ADR-019 (crash-resilient recording — recovered-meeting handling)
**Requirement:** REQ-MEET-019 (proposed — register in `spec/kernel/requirements.yaml` at implementation kickoff; extends the #508 retention controls)
**Issues:** #547, #462, #478
**Decision (owner, 2026-06-18):** N-day + immediate-delete only. **No** true transcript-only / stream-and-discard mode in this plan (deferred). **No** size-based "max disk, delete oldest" eviction (unpredictable; out of scope).

## What this plan closes out

PR #508 (`Add meeting audio retention controls`, shipped) added the binary
`saveMeetingAudio` toggle (default on), per-meeting transcript-safe audio
delete/detach, Settings storage stats + clear-all, and the CLI
`history delete-meeting-audio` / `clear-meeting-audio` commands. What it did
*not* add is the most-requested piece: **time-based cleanup** — "keep the audio
for a while, then delete it automatically so my disk doesn't fill up."

Three issues converge on this:
- **#462** (andreagrandi): "possibility to automatically delete the audio once
  transcribed" + "see how much space they take."
- **#478** (andreagrandi): "with 2-3 meetings/day the audio size could grow very
  fast: an option to automatically remove the audio files after x days. Once I
  have the full transcription, I don't need the original audio anymore."
- **#547**: privacy-driven — does not want a persistent audio file. The
  *immediate-delete* path (already in #508 via `saveMeetingAudio = false`) is
  the in-scope answer for this user; the stricter never-write-to-disk mode is
  explicitly deferred (see Out of scope).

Net new surface: a **retention policy** with three user-facing choices —
**Keep forever** / **Delete after N days** / **Delete immediately after
transcription** — plus a launch + gated-daily/foreground background sweep, all of
which *only ever touch the audio file and always keep the transcript*.

## Scope boundaries

### In scope
- A `meetingAudioRetention` preference modeling: keep-forever (default),
  delete-after-N-days (N configurable), delete-immediately.
- A pure, testable retention policy (given a list of meetings + clock + config,
  return the set whose audio is eligible for deletion).
- A background sweep (launch + gated daily/foreground) that detaches audio (keeps
  transcript) for eligible meetings, reusing the existing `TranscriptionAssetCleanup`
  managed-path-guarded detach.
- Settings Storage card UI: the three-way retention control + the existing
  stats; a one-time confirmation when the user first enables an auto-delete
  policy (because it deletes user data on a schedule).
- CLI `config` key (`meeting-audio-retention`) for headless parity.
- Telemetry: reuse the existing `settingChanged` event for the preference
  change, adding only a new `TelemetrySettingName` value if needed. If the sweep
  emits a new privacy-safe result event (for example `{swept: Int}`), that new
  `TelemetryEventName` must be mirrored in the website `ALLOWED_EVENTS`
  allowlist in the same change, or the Worker drops the batch.

### Out of scope (deferred, by owner decision)
- **True transcript-only / stream-and-discard mode** (never assemble a full
  audio file on disk). This is a real lift in the capture pipeline and is the
  only thing that fully satisfies a "contractually may not record" user beyond
  what immediate-delete gives. Tracked as a follow-up, not built here.
- **Size-cap eviction** ("max N GB, delete oldest"). Predictable time-based
  deletion is safer than size-based eviction; explicitly dropped.
- **Configurable transcript export location / Obsidian** (#462/#478/#460) —
  belongs to the separate Obsidian-integration scope, not retention.
- Any change to dictation-audio or downloaded-media retention (separate toggles
  already exist in the Storage card).

### Invariants
- **Transcript is sacrosanct.** The sweep deletes *audio only*, via the existing
  detach path that nulls `filePath` and keeps the Library row, summary, and
  transcript. Never deletes a transcription row.
- **Never delete outside managed roots.** Reuse
  `TranscriptionAssetCleanup.isKnownMeetingFolder` guard — refuse any path not
  under the managed meeting-recordings roots.
- **Recovery input is protected; recovered meetings are not permanent
  exceptions.** Any folder with a `recording.lock` is excluded from automatic
  retention, and the recovery flow may opt out of immediate deletion while it is
  turning crash audio into a transcript. Once recovery has completed, the lock is
  gone, and the row is `.completed`, the normal retention policy applies. A user
  choosing "Recover" should not silently mean "keep this audio forever."
- **Never delete untranscribed or in-flight audio.** The sweep only detaches audio
  for rows whose status is `.completed`. Empty completed transcripts are still
  completed; do not keep their audio forever just because the meeting was silent
  or STT produced no text. Skip any session folder that still has a
  `recording.lock` in *any* state (`recording` or `awaitingTranscription`),
  regardless of whether the PID is still alive. A dead-PID `awaitingTranscription`
  lock is crash-recovery input, not sweepable storage.
- **No surprise.** First time an auto-delete policy is enabled, confirm with copy
  that states transcripts are kept and audio older than N days will be removed.
- Idle-CPU hygiene: the sweep runs at launch + a gated daily/foreground check
  (a `lastSweptAt` timestamp prevents redundant runs); no resident
  high-frequency timer.

## Verified current state (file:line)

- Immediate-delete path: `Sources/MacParakeetViewModels/TranscriptionViewModel.swift:789`
  `applyMeetingAudioRetentionIfNeeded(_:)` runs right after transcription
  (called ~766/772); when `!shouldSaveMeetingAudio` it deletes audio now.
  The `applyMeetingRetention: Bool = true` param (~841/853) is how recovered
  meetings opt out of deletion *during recovery* (`Sources/MacParakeet/AppDelegate.swift:181`
  passes `false`). This new plan should keep that immediate recovery opt-out but
  let later scheduled sweeps apply once the recovered row is completed and
  unlocked.
- Detach (keeps transcript): `Sources/MacParakeetCore/Utilities/TranscriptionAssetCleanup.swift`
  — `detachOwnedMeetingAudio()` (~66-81) removes the folder + `updateFilePath(id, nil)`;
  `isKnownMeetingFolder()` managed-path guard (~113-126).
- Preference plumbing: `Sources/MacParakeetCore/AppRuntimePreferences.swift`
  — `saveMeetingAudioKey` (~221) + protocol (~3-32) + `UserDefaults` impl (~210-363).
  New `meetingAudioRetention` (enum + days) follows this exact pattern.
- Settings binding: `Sources/MacParakeetViewModels/SettingsViewModel.swift:325`
  currently stores the binary `saveMeetingAudio` toggle and emits
  `.settingChanged(setting: .saveMeetingAudio)`; the tri-state setting should
  follow this path with an exact telemetry setting name (likely
  `.meetingAudioRetention`) and load in `loadSettings()`.
- Storage card UI: `Sources/MacParakeet/Views/Settings/SettingsView.swift:1799`
  `storageCard` — "Keep meeting audio" toggle (~1833) is where the new control replaces/augments the toggle; stats tiles (~1841-1862); clear-all (~1943-1960).
- Storage stats: `Sources/MacParakeetViewModels/SettingsViewModel.swift`
  `meetingAudioStats()` (~1430-1450) counts meeting folders and sizes the
  meeting-recordings directory.
- Launch ordering: `Sources/MacParakeet/App/AppStartupBootstrapper.swift`
  `bootstrapEnvironment()` (~1-34) only has the database manager and dictation
  launch cleanup; do **not** add the meeting retention sweep directly there.
  `Sources/MacParakeet/AppDelegate.swift:538` schedules launch recovery later via
  `MeetingRecoveryCoordinator.scheduleLaunchRecoveryScanIfReady(...)`, and that
  scan is asynchronous. The retention sweep needs an app-layer coordinator after
  `AppEnvironment` setup, sequenced after the launch recovery scan task when one
  is scheduled.
- Age anchor: `Sources/MacParakeetCore/Models/Transcription.swift` `createdAt`
  (~19, indexed `idx_transcriptions_created_at` in `DatabaseManager.swift:132`).
  **No `audioSavedAt` column** — see Open Questions for the anchor decision.
- Active-recording guard precedent: manual `clear-meeting-audio` refuses while a
  live `recording.lock` exists (`MeetingRecordingLockFileStore`, #508 message).
  Scheduled retention is stricter than the manual destructive command: it must
  skip *any* lock, live or dead, because dead `awaitingTranscription` locks feed
  recovery.
- Cross-plan recovery guard: `MeetingRecordingLockFileStore` models both
  `.recording` and `.awaitingTranscription` states. The back-to-back plan creates
  pre-transcription Library rows and `awaitingTranscription` locks, so retention
  cannot use PID liveness alone as the in-flight signal.
- Lock API: `MeetingRecordingLockFileStoring.read(folderURL:)` already answers
  "is there a lock in this exact folder?" Use that (or a tiny wrapper over it)
  for retention; do not use `discoverActiveSessions(...)`, which filters by PID
  liveness.
- Repository API: `TranscriptionRepositoryProtocol` has no purpose-built
  retention-candidate query today. Add one rather than full-scanning the Library:
  filter `sourceType == .meeting`, `filePath != nil`, `status == .completed`,
  and `createdAt <= cutoff` in SQL, then let the sweep runner check lock/managed
  path state.
- CLI config: `Sources/CLI/Commands/ConfigCommand.swift` (`save-meeting-audio` ~66; add `meeting-audio-retention` while keeping `save-meeting-audio` as a documented legacy alias).

## Design

### Preference model (`AppRuntimePreferences`)
```swift
public enum MeetingAudioRetention: Equatable, Sendable {
    case keepForever                 // default — current behavior when saveMeetingAudio == true
    case deleteAfterDays(Int)        // N in a bounded set, see below
    case deleteImmediately           // == existing saveMeetingAudio == false behavior
}
```
- Backward-compat:
  - Derive the initial value from the existing `saveMeetingAudio` bool
    (`true -> .keepForever`, `false -> .deleteImmediately`) once on first read,
    then persist the richer key.
  - Migrate Settings and app runtime callers to the tri-state in the same PR.
    Keep `shouldSaveMeetingAudio` only as a compatibility computed view:
    `deleteImmediately -> false`; `keepForever` and `deleteAfterDays` -> true.
  - Keep CLI `config get/set save-meeting-audio` as a documented legacy alias for
    at least one CLI release. Setting it to `off` maps to `.deleteImmediately`;
    setting it to `on` maps to `.keepForever`; exact N-day state is exposed only
    through `meeting-audio-retention`. Add this to `Sources/CLI/CHANGELOG.md`.
    [Greptile P2]
- N choices: a small, opinionated stepper/menu — **7 / 14 / 30 / 90 days**
  (matches the mental model in #478; avoids a free-form field). Default N when
  switching into the mode: **30**.

### Pure policy (Core, fully unit-tested)
`Sources/MacParakeetCore/Services/MeetingRecording/MeetingAudioRetentionPolicy.swift`
```swift
public enum MeetingAudioRetentionPolicy {
    public struct Candidate: Sendable, Equatable {
        public var id: UUID
        public var hasAudioOnDisk: Bool   // filePath != nil
        public var isCompleted: Bool      // status == .completed; text may be empty
        public var ageReferenceDate: Date // createdAt (see Open Questions)
        public var hasRecoveryLock: Bool  // any recording.lock, live or dead PID
    }
    /// Returns the ids whose AUDIO should be detached now. Pure; no I/O.
    public static func sweep(_ candidates: [Candidate],
                             config: MeetingAudioRetention,
                             now: Date) -> [UUID]
}
```
Rules: skip `!hasAudioOnDisk`, `!isCompleted`, or `hasRecoveryLock`;
`.keepForever` -> []; `.deleteAfterDays(n)` include where
`now - ageReferenceDate > n days`;
**`.deleteImmediately` is treated as `.deleteAfterDays(0)` by the sweep** so that
switching *into* delete-immediately also reclaims already-transcribed audio. The
post-transcription hook only fires for freshly-finished recordings, so without
this the sweep would return `[]` for that mode and a privacy-motivated user would
be left with a library of audio they believe is gone. [Greptile P1]

### Sweep runner (app layer)
A small app-layer `MeetingAudioRetentionSweepCoordinator`, owned after
`AppEnvironment` is available:
1. At launch, schedule the recovery scan first. Run the retention sweep after
   that scan task completes, or immediately if no launch recovery scan is
   scheduled. If the user chooses "Later" in the recovery dialog, the lock
   remains and still excludes the candidate.
2. On daily foreground/wake checks, run directly if the cadence gate allows it;
   lock and completion guards remain the safety boundary.
3. Load meeting transcriptions + completion + lock status.
   Lock status is "any lock exists", not "PID is alive": dead-PID
   `awaitingTranscription` sessions belong to recovery. Use `read(folderURL:)`
   against the meeting folder or an equivalent helper, not
   `discoverActiveSessions(...)`.
4. Call the pure policy.
5. For each id, `TranscriptionAssetCleanup.detachOwnedMeetingAudio()` (guarded).
6. Emit one privacy-safe telemetry count (`{swept: Int}`) if adding the paired
   website allowlist entry in the same change; otherwise log locally only.

**Cadence (not launch-only):** MacParakeet is a persistent menu-bar app that can
run for weeks, so a once-per-launch sweep could effectively never fire. Run it at
launch **and** on a lightweight daily cadence — a `lastMeetingRetentionSweepAt`
timestamp gates re-runs, checked at launch and on foreground/wake
(`NSApplication.didBecomeActiveNotification`). No resident high-frequency timer. [Gemini]

### UI (Storage card)
Replace the bare "Keep meeting audio" toggle with a labeled control:
- A segmented/menu picker: **Keep forever · Delete after [30 ▾] days · Delete
  after transcription**.
- The days stepper only enabled in the middle mode.
- Helper caption: *"Transcripts are always kept. Only the audio recording is
  removed."*
- On first transition into an auto-delete mode, a confirmation sheet/alert:
  *"Delete meeting audio older than 30 days? Transcripts, summaries, and notes
  are always kept — only the audio files are removed. This runs automatically."*
- Keep the existing stats tiles + manual "Clear meeting audio" as-is.

## Phases
1. **Preference + migration** — add `MeetingAudioRetention` to
   `AppRuntimePreferences` (+ derive from `saveMeetingAudio`, keep a legacy
   computed bool view), `SettingsViewModel` binding + telemetry setting name,
   `AppRuntimePreferencesTests`.
2. **Pure policy + tests** — `MeetingAudioRetentionPolicy` with exhaustive
   table tests (boundaries at exactly N days, `deleteImmediately` ==
   `deleteAfterDays(0)`, non-completed skip, empty-completed eligible,
   recovered-completed-without-lock eligible, any-recovery-lock skip,
   no-audio skip).
3. **Repository + lock plumbing** — add the retention-candidate query, use
   folder-local lock existence (`read(folderURL:)` or a wrapper), and cover both
   live and dead `recording` / `awaitingTranscription` locks.
4. **Sweep runner + app hook** — wire a coordinator after `AppEnvironment` setup;
   test against an in-memory repo + temp folders proving transcript survives and
   only eligible audio is detached. Launch wiring must run after the launch
   recovery scan task when one is scheduled, and tests must plant a dead-PID
   `awaitingTranscription` lock to prove untranscribed audio is not swept.
5. **Settings UI + first-enable confirmation** — Storage card control; verify in dev app.
6. **CLI parity** — `config get/set meeting-audio-retention`, legacy
   `save-meeting-audio` alias behavior, `ConfigCommandTests`,
   `Sources/CLI/CHANGELOG.md`.
7. **Telemetry/docs** — if a new sweep event is emitted, update the website
   allowlist in the same change; update `spec/05-audio-pipeline.md`,
   `spec/README.md`/`02-features.md`, and register REQ-MEET-019.

## Testing
- Policy unit tests (pure, deterministic): N-day boundary, keep-forever,
  immediate behaves as `deleteAfterDays(0)`, non-completed skip, empty completed
  transcript eligible, recovered completed row eligible after lock removal, any
  `recording.lock` skip (`recording` and
  `awaitingTranscription`, live and dead PID), no-audio skip.
- Repo/integration: detach keeps the transcription row and nulls `filePath`;
  managed-path guard refuses a planted out-of-root path; retention candidate
  query does not return file/YouTube rows, nil `filePath` rows, non-completed
  rows, or rows newer than the cutoff.
- Recovery ordering: a launch scenario with a dead-PID `awaitingTranscription`
  lock and a pre-transcription Library row must run recovery discovery before
  the retention sweep, or be skipped by the lock/status guards if the user defers
  recovery.
- ViewModel: enabling a mode persists + emits telemetry; first-enable confirmation gating.
- CLI: round-trip `config set/get meeting-audio-retention`; legacy
  `save-meeting-audio` maps `off -> deleteImmediately`, `on -> keepForever`,
  and is documented as an alias.
- Telemetry: if adding a new sweep event, assert it is present in the app event
  catalog and website allowlist.
- `swift test` before merge.

## Open questions (resolve in Phase 1)
1. **Age anchor:** `createdAt` (record creation, already indexed) vs. true
   audio-finalized time vs. on-disk mtime. `createdAt` is within minutes of the
   recording in the current lifecycle and needs no migration — **recommended**.
   Because policy only considers `.completed` rows, queued/back-to-back rows are
   protected while processing. Only add `audioSavedAt` or switch to `updatedAt`
   if long queued transcription delays make the user-visible retention window
   materially wrong. Decide before Phase 2.

(Resolved during PR #556 review: `deleteImmediately` is swept as
`deleteAfterDays(0)` so a mode switch reclaims existing audio; legacy
`saveMeetingAudio` readers are migrated to the tri-state in-PR with a legacy CLI
alias; the sweep runs at launch + a gated daily/foreground check rather than
launch-only; retention skips non-completed/untranscribed meetings and any session
with a recovery lock so it cannot delete queued back-to-back audio before crash
recovery re-enqueues it. Follow-up review clarified that empty completed
transcripts are eligible, recovered meetings are not permanent exemptions after
lock removal, startup wiring belongs after `AppEnvironment`/recovery scan rather
than inside `AppStartupBootstrapper`, and only genuinely new telemetry events
need website allowlist updates.)

## Docs to update on completion
`spec/05-audio-pipeline.md`, `spec/02-features.md`, `spec/README.md`,
`Sources/CLI/CHANGELOG.md`, `spec/kernel/requirements.yaml` (REQ-MEET-019),
plus issue replies on #547/#462/#478.
