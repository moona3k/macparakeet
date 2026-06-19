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
- Telemetry: a `settingChanged` case + a privacy-safe sweep-result count
  (**both new `TelemetryEventName` cases must be mirrored in the website
  `ALLOWED_EVENTS` allowlist in the same change, or the Worker drops the whole
  batch** — two-repo gotcha).

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
- **Recovered meetings are exempt** from automatic retention (same exemption the
  immediate-delete path already honors via `applyMeetingRetention: false`); the
  user made an explicit recover/discard choice for those.
- **Never delete untranscribed or in-flight audio.** The sweep only detaches audio
  for completed meeting transcripts. Skip any meeting whose row is still
  non-completed / transcript-empty, and skip any session folder that still has a
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
  meetings opt out (`AppDelegate.swift:181` passes `false`).
- Detach (keeps transcript): `Sources/MacParakeetCore/Utilities/TranscriptionAssetCleanup.swift`
  — `detachOwnedMeetingAudio()` (~66-81) removes the folder + `updateFilePath(id, nil)`;
  `isKnownMeetingFolder()` managed-path guard (~113-126).
- Preference plumbing: `Sources/MacParakeetCore/AppRuntimePreferences.swift`
  — `saveMeetingAudioKey` (~221) + protocol (~3-32) + `UserDefaults` impl (~210-363).
  New `meetingAudioRetention` (enum + days) follows this exact pattern.
- Settings binding: `Sources/MacParakeetViewModels/SettingsViewModel.swift:324`
  `Telemetry.send(.settingChanged(setting: .audioRetention))`; load in `loadSettings()`.
- Storage card UI: `Sources/MacParakeet/Views/Settings/SettingsView.swift:1799`
  `storageCard` — "Keep meeting audio" toggle (~1833) is where the new control replaces/augments the toggle; stats tiles (~1841-1862); clear-all (~1943-1960).
- Storage stats: `Sources/MacParakeetViewModels/SettingsViewModel.swift` `meetingAudioStats()` (~2444-2465) — counts + sizes per meeting folder.
- Launch sweep hook: `Sources/MacParakeet/App/AppStartupBootstrapper.swift`
  `bootstrapEnvironment()` (~1-34) already runs detached launch cleanup
  (`dictationRepo.deleteEmpty()`, `clearMissingAudioPaths()`); add the meeting
  retention sweep right after.
- Age anchor: `Sources/MacParakeetCore/Models/Transcription.swift` `createdAt`
  (~19, indexed `idx_transcriptions_created_at` in `DatabaseManager.swift:132`).
  **No `audioSavedAt` column** — see Open Questions for the anchor decision.
- Active-recording guard precedent: `clear-meeting-audio` already refuses while a
  live `recording.lock` exists (`MeetingRecordingLockFileStore`, #508 message).
- Cross-plan recovery guard: `MeetingRecordingLockFileStore` models both
  `.recording` and `.awaitingTranscription` states. The back-to-back plan creates
  pre-transcription Library rows and `awaitingTranscription` locks, so retention
  cannot use PID liveness alone as the in-flight signal.
- CLI config: `Sources/CLI/Commands/ConfigCommand.swift` (`save-meeting-audio` ~66; add `meeting-audio-retention`).

## Design

### Preference model (`AppRuntimePreferences`)
```swift
public enum MeetingAudioRetention: Equatable, Sendable {
    case keepForever                 // default — current behavior when saveMeetingAudio == true
    case deleteAfterDays(Int)        // N in a bounded set, see below
    case deleteImmediately           // == existing saveMeetingAudio == false behavior
}
```
- Backward-compat: derive the initial value from the existing
  `saveMeetingAudio` bool (true -> `.keepForever`, false -> `.deleteImmediately`)
  once on first read, then persist the richer key. **Migrate #508's legacy
  readers (Settings + CLI `save-meeting-audio`) to the tri-state in the same PR**
  rather than faking the bool — `deleteAfterDays(N)` has no honest boolean
  (`true` would read as "keep forever" to a legacy consumer), so a sync shim
  would silently mislead. Keep a one-way read shim only if an external consumer
  is found that cannot be migrated. [Greptile P2]
- N choices: a small, opinionated stepper/menu — **7 / 14 / 30 / 90 days**
  (matches the mental model in #478; avoids a free-form field). Default N when
  switching into the mode: **30**.

### Pure policy (Core, fully unit-tested)
`Sources/MacParakeetCore/Services/MeetingRecording/MeetingAudioRetentionPolicy.swift`
```swift
public enum MeetingAudioRetentionPolicy {
    public struct Candidate: Sendable, Equatable {
        public var id: UUID
        public var hasAudioOnDisk: Bool        // filePath != nil
        public var hasCompletedTranscript: Bool // status == .completed + transcript text present
        public var ageReferenceDate: Date      // createdAt (see Open Questions)
        public var isRecovered: Bool
        public var hasRecoveryLock: Bool       // any recording.lock, live or dead PID
    }
    /// Returns the ids whose AUDIO should be detached now. Pure; no I/O.
    public static func sweep(_ candidates: [Candidate],
                             config: MeetingAudioRetention,
                             now: Date) -> [UUID]
}
```
Rules: skip `!hasAudioOnDisk`, `!hasCompletedTranscript`, `isRecovered`,
`hasRecoveryLock`; `.keepForever` -> []; `.deleteAfterDays(n)` include where
`now - ageReferenceDate > n days`;
**`.deleteImmediately` is treated as `.deleteAfterDays(0)` by the sweep** so that
switching *into* delete-immediately also reclaims already-transcribed audio. The
post-transcription hook only fires for freshly-finished recordings, so without
this the sweep would return `[]` for that mode and a privacy-motivated user would
be left with a library of audio they believe is gone. [Greptile P1]

### Sweep runner (app layer)
A small `@MainActor`/service shim invoked from `AppStartupBootstrapper`:
1. Run only after launch crash-recovery has scanned/re-enqueued recoverable
   sessions. If ordering changes later, the policy is still conservative because
   any remaining `recording.lock` excludes the candidate.
2. Load meeting transcriptions + transcript completion + lock/recovery status.
   Lock status is "any lock exists", not "PID is alive": dead-PID
   `awaitingTranscription` sessions belong to recovery.
3. Call the pure policy.
4. For each id, `TranscriptionAssetCleanup.detachOwnedMeetingAudio()` (guarded).
5. Emit one privacy-safe telemetry count (`{swept: Int}`), log a single line.

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
   `AppRuntimePreferences` (+ derive from `saveMeetingAudio`, keep in sync),
   `SettingsViewModel` binding + telemetry case, `AppRuntimePreferencesTests`.
2. **Pure policy + tests** — `MeetingAudioRetentionPolicy` with exhaustive
   table tests (boundaries at exactly N days, `deleteImmediately` ==
   `deleteAfterDays(0)`, non-completed/no-transcript skip, recovered skip,
   any-recovery-lock skip, no-audio skip).
3. **Sweep runner + launch hook** — wire into `AppStartupBootstrapper`; integration
   test against an in-memory repo + temp folders proving transcript survives and
   only eligible audio is detached. Launch wiring must run after crash-recovery
   scanning/re-enqueue, and tests must plant a dead-PID `awaitingTranscription`
   lock to prove untranscribed audio is not swept.
4. **Settings UI + first-enable confirmation** — Storage card control; verify in dev app.
5. **CLI parity** — `config get/set meeting-audio-retention`; `ConfigCommandTests`; `Sources/CLI/CHANGELOG.md`.
6. **Docs** — `spec/05-audio-pipeline.md` retention section, `spec/README.md`/`02-features.md` progress, register REQ-MEET-019.

## Testing
- Policy unit tests (pure, deterministic): N-day boundary, keep-forever,
  immediate behaves as `deleteAfterDays(0)`, non-completed/no-transcript skip,
  recovered exemption, any `recording.lock` skip (`recording` and
  `awaitingTranscription`, live and dead PID), no-audio skip.
- Repo/integration: detach keeps the transcription row and nulls `filePath`;
  managed-path guard refuses a planted out-of-root path.
- Recovery ordering: a launch scenario with a dead-PID `awaitingTranscription`
  lock and a pre-transcription Library row must re-enqueue/recover before the
  retention sweep, or be skipped by the lock/transcript guards if recovery has
  not run yet.
- ViewModel: enabling a mode persists + emits telemetry; first-enable confirmation gating.
- CLI: round-trip `config set/get meeting-audio-retention`.
- `swift test` before merge.

## Open questions (resolve in Phase 1)
1. **Age anchor:** `createdAt` (record creation, already indexed) vs. true
   audio-finalized time vs. on-disk mtime. `createdAt` is within minutes of the
   recording and needs no migration — **recommended**; only add an `audioSavedAt`
   column if drift proves to matter. Decide before Phase 2.

(Resolved during PR #556 review: `deleteImmediately` is swept as
`deleteAfterDays(0)` so a mode switch reclaims existing audio; legacy
`saveMeetingAudio` readers are migrated to the tri-state in-PR; the sweep runs at
launch + a gated daily/foreground check rather than launch-only; retention skips
non-completed/untranscribed meetings and any session with a recovery lock so it
cannot delete queued back-to-back audio before crash recovery re-enqueues it.)

## Docs to update on completion
`spec/05-audio-pipeline.md`, `spec/02-features.md`, `spec/README.md`,
`Sources/CLI/CHANGELOG.md`, `spec/kernel/requirements.yaml` (REQ-MEET-019),
plus issue replies on #547/#462/#478.
