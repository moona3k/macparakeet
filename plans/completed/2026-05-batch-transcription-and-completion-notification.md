# Batch File Transcription + Completion Notification

Status: **IMPLEMENTED**
Owner: Core app team
Updated: 2026-05-30
Related: [GitHub issue #397](https://github.com/moona3k/macparakeet/issues/397)

> Implemented on `feat/batch-transcription` (2026-05-30): Phases A (completion
> chime + backgrounded banner, opt-out toggle), B (sequential local-file batch
> via `AudioFileEnumerator` + `TranscriptionViewModel`), and C (CLI multi-input
> + `--output-dir`, CLI 2.5.0). Requirements REQ-TRANS-004, REQ-UI-006,
> REQ-CLI-002. Verified with the full suite + a real two-clip CLI batch.

## Problem

A master student needs to transcribe 40+ one-hour local recordings. Today the
file-transcription flow is strictly one-at-a-time: the file picker is
`allowsMultipleSelection = false`, and the drop handler accepts a multi-file
drop but deliberately processes only the first supported file and discards the
rest (`TranscriptionViewModel.handleFileDrop`, guarded by `dropAccepted` +
`isTranscribing`). So they must drop → wait → look → drop, forty times.

They also can't tell when a transcription finishes — the only signal is the
menu-bar glyph reverting to idle, which they (correctly) call "not obvious
enough." Notably, the `AppSound.transcriptionComplete` ("Glass") chime already
exists but is **never fired when a job completes** — it is only used as a
generic success chime for user actions (transcript edit/commit, export, save
audio). When a transcription job actually finishes, nothing plays and no banner
appears.

This is really **two asks**: (1) batch/queue transcription, and (2) an obvious
"done" signal. We ship both. They are decoupled, with different cost/risk, so
they are phased — but the notification is also the completion signal the batch
experience needs, so they are designed as one story.

## Decision

Deliver three pieces, sequenced:

- **Phase A — Completion notification (universal, ship first).** Fire the
  existing chime when a transcription finishes, plus a system banner when the
  app is backgrounded. Behind one Settings toggle, default on.
- **Phase B — Ambient GUI batch (local files only).** Multi-select + folder
  drop fan out into a sequential queue that drains in the background, with each
  result auto-appearing in Library and one completion banner at the end. YouTube
  stays single-URL.
- **Phase C — CLI batch.** `transcribe` accepts multiple inputs / a directory
  and an `--output-dir`, writing one transcript per file. Single-input stdout
  behavior is preserved exactly.

## Why this shape (long-term + UX)

- A master student dropping 40 lecture files is the **canonical
  file-transcription power user**, not an edge case. File transcription is one
  of the three core modes, so making it handle "a pile of files" is *deepening a
  pillar*, not feature creep — and MacWhisper (our nearest file rival) has batch.
- The right UX is **ambient, not a queue manager**: drop many → it works out of
  your way → Library fills up → you're told when it's done. We explicitly do
  **not** build reorder / per-item pause / priority controls. The scheduler
  already handles the only priority that matters (dictation has a reserved slot
  and never waits; meetings wait at most one file ≈ ~25s — ADR-016). The only
  batch control is "Cancel all."
- A and B are one story: a batch without a done-signal is unusable (you'd
  babysit it), and a done-signal helps single files too.
- CLI batch is the genuinely-best tool for 40 hours of audio (scriptable,
  walk-away) and fits the "CLI is the canonical Parakeet surface" direction. It
  serves the agent-operator audience, so it's complementary to B, not redundant.

## Context Zone

**In scope:** local audio/video file transcription (drag-drop, Browse,
menu-bar open), a completion chime + banner for file/YouTube single
transcriptions, batch for local files, CLI multi-input.

**Out of scope / must-not-change:**

- YouTube transcription stays **single-URL** (different bottleneck — yt-dlp
  download with its own failure classes; different ingestion model). The
  queue/notification machinery is generic, so a future YouTube-playlist
  front-end can reuse it — we're declining the front-end, not architecting
  against it.
- The single-file transcribe path and its single-result Transcribe-tab view
  must behave **exactly as today** when one file is submitted. Batch is the
  `count > 1` branch.
- Meeting recording / dictation flows untouched (they have their own
  coordinators and completion paths).
- No new STT execution slot and **no parallelism** — batch is sequential and
  non-interruptible per file, matching ADR-016.

**Invariants:**

- Every completed file is persisted to the DB by `TranscriptionService`
  (`transcriptionRepo.save`) independent of the auto-save toggle, so batch
  results land in Library and cannot silently vanish. (Auto-save is a separate
  *export-to-folder* feature and continues to follow its own toggle.)
- A failed file never aborts the batch; it increments a failure count and the
  batch advances.

## Phase A — Completion notification

**Audible signal (reliable path):** in
`TranscriptionViewModel.completeSuccessfulTranscription` (currently no sound),
call `SoundManager.shared.play(.transcriptionComplete)`. `SoundManager` already
respects the macOS "Play sound effects" preference and `AVAudioPlayer`/`NSSound`
play even when the app is backgrounded, so this is the dependable audio cue —
**we do not rely on a UN notification sound** (which would drag in the
`.sound`-authorization nuance). For a batch, suppress per-file chimes and play
one chime when the queue drains (gated by `batchActive`, see Phase B).

**Visual banner (backgrounded only):** post a `UNUserNotification` with `.alert`
when `!NSApp.isActive` at completion. Title = transcript name; body =
"Transcription complete · N words". Clicking activates the app and selects the
result. Reuse `CalendarNotificationAuthorization.requestIfNeeded()` as-is (it
already requests `.alert`); consider renaming it to `LocalNotificationAuthorization`
for clarity since it is now shared (updates the ~3 calendar callsites —
optional, low value, can defer). Skip the banner entirely under `xctest` (the
helper already guards host-bundle eligibility).

**Setting:** add `notifyOnTranscriptionComplete: Bool` to `SettingsViewModel`
(default **on**), following the existing `didSet { defaults.set(...) }` pattern
with a key in `UserDefaultsAppRuntimePreferences`. One toggle governs both the
finish-chime and the banner. Surface it in the Settings notifications/general
section: "Play a sound and notify when transcription finishes."

**Testability:** extract the gating into a pure function,
`TranscriptionCompletionNotifier.shouldBanner(appActive:settingEnabled:)` and
`shouldChime(settingEnabled:batchActive:isLastInBatch:)`, unit-tested without
AppKit/UN.

Files: `MacParakeetViewModels/TranscriptionViewModel.swift`,
`MacParakeet/Views/Components/SoundManager.swift` (callsite only),
`MacParakeetCore/Calendar/CalendarNotificationAuthorization.swift` (reuse),
`MacParakeetViewModels/SettingsViewModel.swift`, Settings view, a new small
`TranscriptionCompletionNotifier`.

## Phase B — Ambient GUI batch (local files only)

### Ingestion (accept many, expand folders)

- `TranscribeView.openFilePicker` (`:571`) and the menu-bar picker
  (`MenuBarCoordinator.swift:599`): set `allowsMultipleSelection = true` and
  `canChooseDirectories = true`; collect `panel.urls`.
- `TranscriptionViewModel.handleFileDrop` (`:231`): collect **all** supported
  file URLs instead of stopping at the first; expand dropped folders.
- New shared helper `expandToSupportedAudioFiles(_ urls:) -> [URL]`: for each
  URL, if it is a directory, enumerate it (recursively, skipping hidden files
  and symlink loops) filtering `AudioFileConverter.supportedExtensions`; else
  include if supported. **Cap at 200 files; if exceeded, `log()`/surface the
  count dropped — never truncate silently.**
- New entry point `transcribeFiles(urls: [URL], source:)`:
  - `count <= 1` → call the existing `transcribeFile` path unchanged.
  - `count > 1` → enqueue and start the drain loop.

### Batch queue (ViewModel-owned, sequential)

Rationale for ViewModel-owned (vs. submitting all to `STTScheduler`): the
scheduler already runs `.fileTranscription` sequentially and non-interruptibly
per file, so user-visible scheduling is identical either way; a ViewModel queue
reuses the existing single-job completion path verbatim, keeps the
single-active-job UI invariant, and makes "Cancel all" trivial (clear list +
cancel the one in-flight `transcriptionTask`).

New state on `TranscriptionViewModel`:

```
batchQueue: [URL]            // pending
batchTotalCount: Int
batchCompletedCount: Int
batchFailedCount: Int
batchActive: Bool            // batchTotalCount > 1 && (queue nonempty || job in flight)
```

- Drain loop: submit the head URL through the existing
  `transcribeFile`/`beginNewTranscription` path. In the three completion
  funnels — `completeSuccessfulTranscription`, `completeFailedTranscription`,
  `completeCancelledTranscription` — add an `advanceBatchIfNeeded()` hook that
  increments the right counter and submits the next URL.
- **Errors continue the batch** (increment `batchFailedCount`, advance).
- `cancelBatch()`: clear `batchQueue`, cancel the in-flight `transcriptionTask`,
  reset batch state. Stops advancing.
- On drain (queue empty, no job in flight): play one chime + post one banner
  ("N transcriptions complete" / "N complete, M failed") via Phase A.

### UI (reuse what exists; minimal additions)

- **Global bottom bar** already exists (`MainWindowView.swift:330+`) and shows
  on any tab except Transcribe while `isTranscribing`. Extend its headline to
  read "Transcribing 7 of 40 · 1 failed" when `batchActive`, keeping the
  current-file progress fraction. Add a **"Cancel all"** affordance when
  `batchActive`.
- **Transcribe tab:** when `batchActive`, show a compact batch status card
  (count + current file name + Cancel all) in place of the single in-flight
  view. Keep `currentTranscription` showing the most recently completed file so
  the tab isn't empty; the canonical destination is **Library**.
- **Library** already refreshes via `loadTranscriptions()` after each file
  (called inside `presentCompletedTranscription`), so it fills up live — no new
  Library work.
- No per-row queue list, no reorder, no per-item controls.

### Feature flag

Not required: batch is a strict superset of existing behavior and the
single-file path is unchanged. (Optional `AppFeatures.batchTranscriptionEnabled`
kill-switch only if the owner wants one — note as a decision, default no flag.)

Files: `MacParakeetViewModels/TranscriptionViewModel.swift`,
`MacParakeet/Views/Transcription/TranscribeView.swift`,
`MacParakeet/App/MenuBarCoordinator.swift`,
`MacParakeet/Views/MainWindowView.swift`, a new `AudioFileEnumerator` helper in
Core.

## Phase C — CLI batch

- `TranscribeCommand`: change `@Argument var input: String` →
  `@Argument var inputs: [String]` (variadic; shell globs like `*.m4a` expand to
  multiple args natively). Add `@Option var outputDir: String?`
  (`--output-dir`).
- Refactor the single-input body of `run()` into
  `transcribeOne(input:service:...) -> Transcription`, then loop over `inputs`
  sequentially.
- **Output rules** (preserve back-compat):
  - 1 input, no `--output-dir` → identical to today (stdout in the chosen
    `--format`, progress on stderr).
  - multiple inputs **or** `--output-dir` set → write each transcript to
    `outputDir/<basename>.<format-ext>` (default `outputDir` = cwd if multiple
    inputs and flag omitted); print a per-file progress line to stderr
    ("Transcribing 3/40: lecture03.m4a").
- A directory argument expands to its supported files (mirrors GUI folder
  support).
- **Continue-on-error:** a failed input logs to stderr and increments a failure
  count; the batch continues. Exit 0 if all succeeded, non-zero if any failed;
  print a final summary ("38 ok, 2 failed"). Document exit semantics.
- Mixed local-file + YouTube inputs are allowed (each routed as today).
- `cliTelemetryMetadata`: derive `inputKind` from the first input; optionally add
  an input-count bucket — keep allowlist-safe (no paths/URLs).
- **Public contract:** bump the CLI minor version and update
  `Sources/CLI/CHANGELOG.md`.

Files: `Sources/CLI/Commands/TranscribeCommand.swift`,
`Sources/CLI/CHANGELOG.md`, `Sources/CLI/Commands/CLITelemetry.swift`.

## Testing

- **ViewModel batch (mock `TranscriptionServiceProtocol`):** enqueue 3 URLs →
  assert sequential completion order, `batchCompletedCount`/`batchFailedCount`,
  Library refresh per file; a thrown mid-batch error advances rather than
  aborts; `cancelBatch()` mid-batch stops advancing and cancels the in-flight
  job.
- **Folder/glob expansion:** directory with mixed extensions →
  supported-only; nested dirs; hidden files skipped; >200-file cap surfaces the
  dropped count.
- **Notification gating:** pure `shouldBanner`/`shouldChime` truth-table tests
  (app active vs. background, setting on/off, single vs. last-in-batch).
- **CLI (CLITests):** parses multiple inputs and `--output-dir`; single-input
  stdout unchanged; output files written with correct extension/format;
  continue-on-error exit code; directory-arg expansion.
- Run focused tests, then `swift test` before merge.

## Docs / spec hygiene

- `spec/kernel/requirements.yaml`: add `REQ-TRANS-0XX` "Batch local-file
  transcription (multi-select + folder drop, sequential, results in Library)",
  `REQ-UI-0XX` / `REQ-TRANS-0XX` "Transcription completion sound + banner
  (opt-out)", `REQ-CLI-0XX` "CLI batch transcription with --output-dir,
  continue-on-error". (status `proposed` → `implemented` on merge.)
- `spec/kernel/traceability.md`: map new source/tests.
- `spec/02-features.md` + `spec/06-stt-engine.md`: note batch ingestion is the
  realized form of the ADR-016 batch note (still sequential, non-interruptible).
- Light ADR-016 amendment cross-reference (no decision change).
- `Sources/CLI/CHANGELOG.md`: Phase C entry + semver bump.
- `CLAUDE.md`: file picker is now multi-select + folder; completion
  notification exists.

## Risks / watch-items

- **Single-file regression risk** — the most-used path. `count <= 1` must route
  exactly as today; cover with a test asserting the single path is unchanged.
- **macOS UN `.sound` nuance avoided by design** — sound comes from
  `SoundManager` (in-app, backgrounded-safe, respects the system sound pref),
  banner from UN `.alert` only. We do not request `.sound` authorization.
- **Folder recursion** — bound it (cap + no silent truncation; skip symlink
  loops/hidden).
- **Telemetry is a two-repo change** — any new `TelemetryEventName` (e.g.
  `batch_transcription_completed`) must also be added to `ALLOWED_EVENTS` in
  `macparakeet-website/functions/api/telemetry.ts`, or the Worker drops the whole
  batch. (Telemetry for batch is optional; if added, do both repos.)
- **Notification permission denial** — degrade gracefully: the in-app chime +
  menu-bar/bottom-bar still signal completion even if banners are denied.

## Sequencing

1. **Phase A** first — independently shippable, small, universal; de-risks B by
   providing the completion signal.
2. **Phase B** — depends on A's signal.
3. **Phase C** — independent; can land alongside or after B (shared
   transcription path, mostly arg-parsing + output-dir + a loop).
