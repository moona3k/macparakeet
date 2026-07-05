---
title: Local Transcription Title Rename Plan
type: feat
date: 2026-07-04
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: issue-647-live-github-and-origin-main
execution: code
github_issue: https://github.com/moona3k/macparakeet/issues/647
---

# Local Transcription Title Rename Plan

**Status:** IMPLEMENTED in branch - pending PR review/merge
**Issue:** #647 - "[Feature Request] Ability to rename Local Transcription Titles"
**Verified against:** live GitHub issue #647 on 2026-07-04 and `origin/main` at `46c82ed70`.
**Related specs:** `spec/01-data-model.md`, `spec/02-features.md`, `spec/04-ui-patterns.md`, `integrations/README.md`

## Goal Capsule

Issue #647 has two asks: rename Local transcription titles, and optionally copy imported audio or video into MacParakeet so deleting the original source file does not break playback. This plan deliberately focuses on the first ask only.

The goal is to make Local Library transcriptions user-renamable without corrupting source-file metadata. A renamed Local transcription should show the user's title in the Library and detail surfaces, survive app relaunch, participate in search and title sort, and leave `fileName` / `filePath` available as source identity.

The accepted owner direction in the issue is that renaming should be the common-sense default for the next release. Copy-on-import remains a separate retention/import behavior and should not be bundled into this change.

## Product Contract

### Actors

- A1. A MacParakeet user managing imported local file transcriptions in the Library.
- A2. A reviewer validating that the feature is a title/display change, not a file retention or source-file rename change.
- A3. A future CLI or integration user reading saved transcription metadata.

### Requirements

- R1. A Local transcription row in the Library exposes a `Rename...` action from the same card menu and context menu shown in the screenshot attached to #647.
- R2. Rename edits a persisted, user-controlled title override for the transcription. It must not overwrite the original `fileName`, move/rename the source file on disk, or change `filePath`.
- R3. The effective title fallback order is: for meetings, the existing meeting `fileName`; for non-meetings, non-empty user title override, then non-empty `derivedTitle`, otherwise `fileName`.
- R4. Local Library cards, list rows, open detail headers, Library search, and title sort use the same effective title semantics.
- R5. Empty or whitespace-only rename submissions are rejected without writing. Cancel preserves the existing title. Submitting the current effective title is a no-op.
- R6. Existing meeting rename behavior remains unchanged: meeting titles continue to use `fileName`, `updateFileName`, and meeting artifact refresh behavior.
- R7. Existing transcript-derived titles remain intact. Retranscription or derived-field backfill may refresh `derivedTitle`, but must not erase a user title override.
- R8. Export and automation behavior is not silently broadened. The GUI may use the effective title for suggested export filenames where the user expects the visible title, but public CLI exact-name resolution and output changes need explicit contract review before changing `integrations/README.md`.
- R9. Copying imported media into MacParakeet storage is out of scope for this plan. No retention, import-copy, or audio-player fallback behavior changes ship with this title rename.

### Acceptance Examples

- AE1. A Local row titled from transcript content as `Let's start with the Q3...` can be renamed to `Q3 Vendor Notes`; the card immediately shows `Q3 Vendor Notes` and still shows that title after app relaunch.
- AE2. Searching the Library for `vendor notes` finds the renamed Local row even if neither the original filename nor transcript contains that phrase.
- AE3. Sorting by title places the Local row according to `Q3 Vendor Notes`, not according to the original `IMG_1942.m4a` filename.
- AE4. Opening the renamed Local row shows `Q3 Vendor Notes` in the detail header. Any source chip or file metadata still reflects the original local file identity where that metadata is shown.
- AE5. Clearing the dialog, entering only spaces, or pressing Cancel leaves the row unchanged and does not update `updatedAt`.
- AE6. Renaming a meeting still updates the meeting title as it does today and still refreshes meeting markdown/artifacts where the current meeting path requires it.

### Scope Boundaries

In scope:

- A nullable title override on transcription records.
- Library and detail UI support for renaming Local file transcriptions.
- Search, title sort, and display helper updates so all first-party UI reads one title contract.
- Data-model/spec updates for the new persisted field.
- Focused tests around persistence, query semantics, view model behavior, and existing meeting rename invariants.

Out of scope:

- Copy-on-import / media retention for local audio and video.
- Renaming or moving files on disk.
- Changing meeting title storage in this pass.
- Bulk rename.
- Transcript text editing.
- YouTube or podcast rename UI, unless the implementation naturally shares the same display helper without exposing a new command.
- Public CLI output or exact-name lookup changes unless a reviewer explicitly accepts the contract update.

## Verified Current State

- `Sources/MacParakeet/Views/Transcription/TranscriptionLibraryView.swift` builds Library card and context menus in `libraryMenuItems(for:)`. The current menu has `Open`, `Select Many...`, meeting-only audio/artifact actions, favorite, and delete. There is no rename action for Local rows.
- `Sources/MacParakeet/Views/Transcription/TranscriptionThumbnailCard.swift` has a private `displayTitle` helper. Meetings use `fileName`; non-meeting rows use non-empty `derivedTitle`, then `fileName`.
- `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift` has an inline title editor only when `sourceType == .meeting`. The displayed title is effectively the current transcription's `fileName`.
- `Sources/MacParakeetCore/Models/Transcription.swift` stores `fileName`, `filePath`, `derivedTitle`, and `derivedSnippet`. There is no custom or override title field.
- `Sources/MacParakeetCore/Database/TranscriptionRepository.swift` exposes `updateFileName(id:fileName:)`. Its implementation changes both `fileName` and `derivedTitle`, with comments saying this is meeting-only behavior.
- Library search currently checks `fileName`, raw transcript, clean transcript, and channel name. It does not search `derivedTitle` or any user-title concept.
- Library `titleAscending` sort currently orders by `fileName COLLATE NOCASE`.
- `TranscriptionLibraryViewModel` owns Library loading, filtering, deletion, favorites, and bulk selection. It has no rename method.
- `TranscriptionViewModel.renameCurrentTranscription(to:)` currently routes detail title edits through `updateFileName` and mirrors the change into `derivedTitle`; this path should remain meeting-only.

## Planning Contract

### KTD1. Add `titleOverride`; do not repurpose `fileName` or `derivedTitle`

Use a new optional `Transcription.titleOverride` field, stored as nullable `transcriptions.titleOverride TEXT`.

Rationale:

- `fileName` is source identity for Local rows and is already used by CLI/export code as an input-file-oriented name.
- `derivedTitle` is generated display copy from transcript content and can be refreshed by transcription or backfill logic.
- A user rename must be durable across derived-field regeneration and must not make MacParakeet forget the imported file's original identity.

Implementation note: persist trimmed non-empty strings and store `nil` for absent override. Do not store empty strings as meaningful values.

### KTD2. Centralize effective title semantics

Add a shared helper in Core so views, repositories, and tests do not each reconstruct fallback logic. The default target is an extension on `Transcription`, for example:

```swift
public var effectiveDisplayTitle: String
public var normalizedTitleOverride: String?
```

The helper should enforce R3. Views should stop owning their own fallback logic once this helper exists.

### KTD3. Keep meeting rename behavior stable

Meeting title editing can keep using `fileName` and `updateFileName(id:fileName:)` for this release. A future unification can migrate meetings to `titleOverride`, but doing that in this issue would expand risk into artifact naming, meeting markdown refresh, and CLI meeting exports.

### KTD4. Make Library query semantics match visible title

If the UI shows the effective title, Library search and title sort should use that same title. Otherwise users can rename a Local card and then fail to find or sort it by the name they see.

The SQL ordering should use a display-title expression equivalent to:

```sql
COALESCE(
  CASE
    WHEN sourceType = 'meeting' THEN NULL
    ELSE NULLIF(TRIM(titleOverride), '')
  END,
  CASE
    WHEN sourceType = 'meeting' THEN fileName
    ELSE COALESCE(NULLIF(TRIM(derivedTitle), ''), fileName)
  END
)
```

The in-memory fallback in `TranscriptionRepositoryProtocol.fetchLibraryPage(query:)` should use the same Core helper, so mocks and database-backed queries agree.

### KTD5. Detail UI should not stay inconsistent

Although #647's screenshot is the Library menu, a user-visible title rename should carry into the open transcript detail. The implementation should rename the existing `meetingTitleView` concept into a general title view, show the effective title for Local rows, and expose the pencil only for source types supported by this pass: `.meeting` through the existing meeting path and `.file` through the new title override path.

If the implementation team wants the smallest first PR, detail editing can be staged as a follow-up only if detail display still reflects renamed Local titles. Do not ship a state where the Library card says one title and the open detail header says the old filename.

### KTD6. Treat CLI behavior as a contract boundary

The public CLI supports history, export, and exact-name lookup flows. Adding `titleOverride` to the data model is acceptable, but changing CLI display names or resolution behavior can affect automation. For this issue, keep CLI-visible behavior unchanged unless the implementation also updates `integrations/README.md`, `Sources/CLI/CHANGELOG.md`, and focused CLI tests.

## Proposed UX

### Library Menu

For Local rows, insert `Rename...` after `Open` and before `Select Many...`:

- `Open`
- `Rename...`
- `Select Many...`
- `Add to Favorites` / `Remove from Favorites`
- `Delete`

Use SF Symbol `pencil` for the rename action. Do not show the action while bulk selection mode is active if the surrounding menu is meant to focus on selection actions, and do not offer bulk rename.

### Rename Dialog

Use a compact SwiftUI sheet or alert with a text field:

- Title: `Rename Transcription`
- Field label/placeholder: `Title`
- Primary action: `Rename`
- Secondary action: `Cancel`

Prefill the field with the effective display title. The primary action should be disabled or ignored for blank trimmed input. On failure, keep the dialog dismissed only if the local app pattern already does so; otherwise keep the existing `errorMessage` surface consistent with delete/favorite failures.

Clearing a previously saved title override and reverting to the auto-derived title is out of scope for this PR's GUI. The repository accepts `nil`/blank as clear-title behavior so a future reset affordance can reuse the persistence path, but the shipped rename dialog rejects blank titles instead of treating blank as reset.

### Detail Header

Rename the meeting-specific helper names only as much as needed for clarity. The visible detail header should call the Core effective-title helper. For Local rows, the pencil should call a new title-override view model method. For meetings, keep the existing `renameCurrentTranscription(to:)` path or rename it to make meeting-only semantics explicit.

## Implementation Units

### U1. Persist User Title Overrides

Primary files:

- `Sources/MacParakeetCore/Models/Transcription.swift`
- `Sources/MacParakeetCore/Database/DatabaseManager.swift`
- `Sources/MacParakeetCore/Database/TranscriptionRepository.swift`
- `Tests/MacParakeetTests/Database/DatabaseManagerTests.swift`
- `Tests/MacParakeetTests/Database/TranscriptionRepositoryTests.swift`
- `Tests/MacParakeetTests/ViewModels/ViewModelMocks.swift`
- `spec/01-data-model.md`

Work:

- Add `public var titleOverride: String?` to `Transcription`.
- Add the field to the initializer, CodingKeys/Columns, decoding, and GRDB persistence.
- Register a guarded migration after `v0.25-calendar-event-snapshot`, for example `v0.26-transcription-title-override`, that adds nullable `titleOverride`.
- Add `updateTitleOverride(id:titleOverride:)` to `TranscriptionRepositoryProtocol`.
- In the repository implementation, trim input before storing, normalize blank input to `nil` only for explicit clear-title behavior, and update `updatedAt` only on actual change.
- Update test mocks and lightweight protocol defaults.
- Update `spec/01-data-model.md` schema, migration notes, and field table.

Test scenarios:

- A migrated database has a nullable `titleOverride` column.
- Existing rows decode with `titleOverride == nil`.
- Saving and fetching a row preserves `titleOverride`.
- Updating a Local file title override changes `titleOverride` and `updatedAt` without changing `fileName`, `filePath`, or `derivedTitle`; meeting rows stay on the existing meeting title path.
- A blank or whitespace update does not create an empty persisted title.

### U2. Centralize Effective Display Title, Search, and Sort

Primary files:

- `Sources/MacParakeetCore/Models/Transcription.swift`
- `Sources/MacParakeetCore/Database/TranscriptionRepository.swift`
- `Sources/MacParakeet/Views/Transcription/TranscriptionThumbnailCard.swift`
- `Sources/MacParakeet/Views/MeetingRecording/MeetingRowCard.swift`
- `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift`
- `Sources/MacParakeet/Views/Transcription/TranscriptResultActions.swift`
- `Tests/MacParakeetTests/Database/TranscriptionRepositoryTests.swift`
- `Tests/MacParakeetTests/ViewModels/TranscriptionLibraryViewModelTests.swift`

Work:

- Add a Core helper for `effectiveDisplayTitle`.
- Replace private UI fallback logic with the helper where the user-visible title is intended.
- Extend Library search to include `titleOverride` and `derivedTitle`, with the effective title as the easiest mental model for tests.
- Change title-ascending database sort and in-memory protocol sort to use effective-title semantics.
- GUI export default filenames should use `effectiveDisplayTitle` because the user expects the exported file suggestion to match the visible title.
- Leave CLI export and exact-name resolution unchanged unless U6 is explicitly accepted.

Test scenarios:

- A Local row with `titleOverride`, `derivedTitle`, and `fileName` displays the override.
- A Local row without override displays non-empty `derivedTitle`.
- A meeting row ignores `derivedTitle` and displays `fileName`.
- Library search finds a Local row by override text.
- Library search still finds rows by original filename and transcript text.
- Title sort orders by override before file-name fallback.
- Existing meeting title sorting remains sensible and case-insensitive.

### U3. Add Local Rename Flow in the Library

Primary files:

- `Sources/MacParakeet/Views/Transcription/TranscriptionLibraryView.swift`
- `Sources/MacParakeetViewModels/TranscriptionLibraryViewModel.swift`
- `Tests/MacParakeetTests/ViewModels/TranscriptionLibraryViewModelTests.swift`

Work:

- Add view state for the row being renamed and the draft title.
- Add `Rename...` to `libraryMenuItems(for:)` when `transcription.sourceType == .file`.
- Present the rename dialog prefilled with `transcription.effectiveDisplayTitle`.
- Add `TranscriptionLibraryViewModel.renameTranscriptionTitle(_:, to:)` for Local rows.
- The view model should trim input, reject blanks/no-ops, call the repository update method, reload the loaded Library window, and preserve current filter/search/sort state.
- On repository failure, leave the local item unchanged and set `errorMessage` with a user-readable failure.

Test scenarios:

- Renaming a loaded Local row updates the repository and local arrays.
- Renaming a Local row while the Local filter is active keeps the row visible with the new title.
- Renaming a Local row while title sort is active reorders using the new effective title.
- Blank and no-op renames do not call the repository.
- Repository failure sets `errorMessage` and does not mutate the loaded row.
- Meeting, YouTube, and podcast rows do not get routed through the Local rename method in this pass.

### U4. Keep Detail Header Consistent

Primary files:

- `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift`
- `Sources/MacParakeetViewModels/TranscriptionViewModel.swift`
- `Tests/MacParakeetTests/ViewModels/TranscriptionViewModelTests.swift`

Work:

- Rename meeting-specific local state only if needed for clarity, for example `editingTitle`, `titleDraft`, and `displayedTitle`.
- Display `activeTranscription.effectiveDisplayTitle` in the header.
- For Local rows, allow the pencil edit to call a new title-override method on `TranscriptionViewModel`.
- For meeting rows, preserve current behavior through the existing meeting rename method. If renaming the method, keep its implementation semantics meeting-only.
- When a Local title override changes in detail, update `currentTranscription` and matching `transcriptions` entry without calling meeting artifact refresh.

Test scenarios:

- Detail rename for a Local row updates `titleOverride`, not `fileName` or `derivedTitle`.
- Detail rename for a Local row updates `currentTranscription` and the backing list.
- Existing meeting rename tests still pass and still assert `fileName` plus `derivedTitle` mirroring where current export behavior depends on it.
- Blank/no-op detail renames do not write.

### U5. Update Docs and Release Framing

Primary files:

- `spec/01-data-model.md`
- `spec/02-features.md`
- `spec/04-ui-patterns.md`
- `plans/active/2026-07-04-issue-647-local-transcription-title-rename.md`

Work:

- Document `titleOverride` as user-authored display metadata for non-meeting transcription rows.
- Clarify that Local transcription rename is an app metadata change and does not rename source files.
- If GUI export filenames use the effective title, document that as user-facing behavior in the feature spec.
- Leave copy-on-import documented as deferred if it is mentioned at all.
- Move this plan to `plans/completed/` only after implementation and verification land.

Test scenarios:

- Documentation review confirms no copy-on-import behavior is promised by this plan.
- Documentation review confirms Local title rename does not imply source-file retention.

### U6. Optional Follow-Up: CLI Title Contract

This unit is not required for #647's GUI rename acceptance, but it is the correct place to handle automation if product decides user title overrides should be first-class in CLI workflows.

Primary files:

- `Sources/CLI/Commands/ExportCommand.swift`
- `Sources/CLI/Commands/TranscribeCommand.swift`
- `integrations/README.md`
- `Sources/CLI/CHANGELOG.md`
- `Tests/CLITests/*`

Work:

- Decide whether CLI list/show/export surfaces should expose `titleOverride` separately or use effective title as display name.
- Decide whether exact-name lookup should match `titleOverride`, `fileName`, or both.
- Update public docs and focused CLI tests in the same PR if behavior changes.

## Verification Contract

Focused commands for implementation:

```bash
swift test --filter DatabaseManagerTests
swift test --filter TranscriptionRepositoryTests
swift test --filter TranscriptionLibraryViewModelTests
swift test --filter TranscriptionViewModelTests
swift test --filter TranscriptResultActionsTests
git diff --check
```

Run full `swift test` at most once as the final code-change gate if the implementation touches all planned layers. Do not run the full suite repeatedly during iteration.

Manual smoke checklist:

- Import or use an existing Local transcription.
- Rename it from the Library card/context menu.
- Confirm the Library card updates immediately.
- Open the transcription and confirm the detail header shows the renamed title.
- Relaunch the app and confirm the title persists.
- Search by the renamed title.
- Sort by title and confirm ordering follows the renamed title.
- Confirm the original local source file has not been renamed or moved.
- Rename a meeting and confirm existing meeting behavior still works.

## Risks And Mitigations

- Risk: Overwriting `fileName` for Local rows breaks source identity and CLI/export assumptions. Mitigation: add `titleOverride` and tests that assert `fileName` is unchanged.
- Risk: UI shows the new title but search/sort still use `fileName`. Mitigation: centralize effective title and test query behavior.
- Risk: Meeting rename behavior regresses while generalizing title UI. Mitigation: keep meeting storage path unchanged and preserve existing meeting rename tests.
- Risk: Copy-on-import expectations bleed into this issue. Mitigation: keep R9 explicit and avoid changing retention/import storage.
- Risk: CLI behavior changes accidentally because repository search gets broader. Mitigation: treat CLI output/resolution as U6 and run focused CLI tests only if touched.

## Definition Of Done

- R1 through R9 are satisfied or explicitly deferred with reviewer agreement.
- Local transcription title rename works from the Library and persists through relaunch.
- The original local source filename/path remain intact.
- Library search and title sort match the visible effective title.
- Detail header is consistent with the Library title.
- Existing meeting rename behavior remains green.
- `spec/01-data-model.md` is updated for the new field/migration.
- Focused tests pass, `git diff --check` passes, and a final full `swift test` is run at most once if the implementation breadth warrants it.
- The GitHub issue closeout only claims the rename portion of #647; copy-on-import is left as separate follow-up work.

## Source Notes

- Live issue #647 body requests Local title rename and copy-on-import.
- Owner comment on 2026-07-04 accepts rename for next release and frames copy-on-import as a possible separate toggle/menu behavior.
- Current `origin/main` title behavior is split between meeting `fileName` and non-meeting `derivedTitle`.
- Current repository comments already treat `updateFileName` as meeting-only rename behavior.
