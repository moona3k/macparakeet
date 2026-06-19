# Library Multi-Select Bulk Delete

**Status:** ACTIVE PLAN — not started
**Date:** 2026-06-18
**ADRs:** none new (UI/data-flow change within existing Library architecture)
**Requirement:** REQ-LIB-002 (proposed — extends REQ-LIB-001 "Transcription library with thumbnail grid, filters, search")
**Issues:** #498
**Decision (owner, 2026-06-18):** Reuse the existing Dictation History
"Select Multiple" pattern **plus keyboard support** (Delete key, ⌘A). Not
Finder-style modifier-click selection (keeps the app internally consistent).

## What this plan closes out

The Library has no way to remove more than one item at a time — every delete is a
context-menu → alert → confirm, one row at a time. #498 ("selecting multiple
items in Library to bulk delete") is the literal ask, and it compounds with the
#462 storage-management theme: users accumulating meetings/files need to prune in
bulk.

The good news: **Dictation History already implements a complete, shipped
bulk-select pattern** (selection state, mode toggle, an action bar with
count / Select All / Clear / Delete, batched deletion). This plan ports that
proven pattern into the Library (both the thumbnail grid and the meetings list)
rather than inventing a new interaction — and layers on keyboard affordances
Dictation does not yet have. (No undo in v1 — see Out of scope for why a row-only
undo would be a data-loss trap here.)

This plan also creates the selection substrate that the **auto-title backlog**
follow-up (`2026-06-18-meeting-auto-title-followups.md`) rides on: once rows are
multi-selectable, "Generate titles" becomes a natural bulk action.

## Scope boundaries

### In scope
- Multi-select + bulk delete in **both** Library surfaces:
  the thumbnail grid (`TranscriptionLibraryView` grid mode) and the date-grouped
  meetings list (`TranscriptionLibraryView` meetings-list mode + `MeetingsView`
  "Recent Meetings").
- Selection state + batch-delete operations on `TranscriptionLibraryViewModel`,
  mirroring `DictationHistoryViewModel`'s API shape.
- An action bar (count, Select All, Clear, Cancel, Delete) consistent with the
  Dictation History bar.
- Keyboard: `⌫`/`Delete` triggers the bulk-delete confirmation when items are
  selected; `⌘A` selects all currently-filtered items; `Esc` exits select mode.
- A single confirmation alert stating the count and permanence; copy adapts when
  the selection includes meetings (audio **and** AI summaries/chats are
  unrecoverable — see Invariants).
- The batch delete runs off the main thread (`Task.detached`), mirroring
  `DictationHistoryViewModel.deleteTargets`, so deleting many items never
  beachballs the UI. [Gemini]

### Out of scope
- Bulk delete in Dictation History (already exists).
- **Undo / trash for bulk delete.** Deferred for v1 by design: `delete(id:)`
  cascade-deletes a transcription's `prompt_results`, `chat_conversations`, and
  LLM-run rows (`foreignKeysEnabled` + `onDelete: .cascade`,
  `DatabaseManager.swift:227-229, 404-406, 807-810`), so a row-only undo would
  silently lose every AI summary and Ask-tab chat — strictly worse than no undo.
  A real undo needs a full-object-graph snapshot/restore or a soft-delete trash;
  both are a separate future feature. v1 relies on a precise confirmation instead.
- Bulk **audio-only detach** (the single-item "Delete Audio" stays single-item;
  bulk = full delete). Revisit if requested.
- Bulk operations other than delete (move, export, favorite) — selection
  substrate enables them later, but only delete (+ the auto-title follow-up's
  "Generate titles") ships here.
- Repository-level batch SQL — loop the existing single deletes in the ViewModel
  (volumes are small; correctness + asset cleanup parity matter more than a new
  batch query). Revisit only if perf demands it.

### Invariants
- **Asset cleanup parity.** Each delete in the batch runs the *same*
  `TranscriptionDeletionCleanup.removeOwnedAssets()` + repo `delete(id:)` as the
  single-item path — no shortcut that skips on-disk cleanup.
- **No partial-silent failure.** If one item in the batch fails to delete, the
  batch continues and the result surfaces (count succeeded / failed), never a
  silent drop.
- **Deletion is permanent and total.** A delete removes the transcript, its
  on-disk audio, **and** its cascaded `prompt_results` / `chat_conversations` /
  LLM-run rows. There is no undo (see Out of scope), so the confirmation must
  state this plainly — especially that meeting audio and AI summaries can't be
  recovered.
- **Filter-aware Select All.** `⌘A` / "Select All" selects only the currently
  filtered + searched set, never hidden rows.
- **Accessibility parity.** The action bar and selection controls carry VoiceOver
  labels (count, selected state, actions), consistent with the active a11y sprint.
- Idle hygiene: selection state is torn down on mode exit and on filter change.

## Verified current state (file:line)

- Reusable pattern (source of truth to mirror):
  `Sources/MacParakeetViewModels/DictationHistoryViewModel.swift`
  — `selectedDictationIDs: Set<UUID>` + `isBulkSelectionModeEnabled` (~104-111),
  `beginBulkSelection`/`exitBulkSelection` (~237-246),
  `requestDeleteSelectedDictations`/`confirmDeleteSelectedDictations` (~248-268),
  shared `deleteDictations(_:using:)` (~280-301), count-aware alert copy (~303-312).
- Action bar UI to mirror: `Sources/MacParakeet/Views/History/DictationHistoryView.swift`
  — `selectedActionsBar` (~173-220), Delete button (~208-214), bar shown when mode on (~83-89).
- Library views to modify:
  `Sources/MacParakeet/Views/Transcription/TranscriptionLibraryView.swift`
  — grid vs meetings-list routing (~75-79), filter chips (~44-57),
  `thumbnailGrid` (~137-160), `meetingsList` (~162-185),
  single-delete (context menu → `pendingDelete`, alert ~85-105 → `deleteTranscription`),
  meeting audio-only detach (~106-121 → `deleteMeetingAudio`).
- `Sources/MacParakeet/Views/Meetings/MeetingsView.swift` — "Recent Meetings"
  list reuses `MeetingRowCard` (~406-449).
- Library ViewModel to extend:
  `Sources/MacParakeetViewModels/TranscriptionLibraryViewModel.swift`
  — `transcriptions` / `filteredTranscriptions` / `groupedTranscriptions`,
  `deleteTranscription(_:)` (~152-165) calling
  `TranscriptionDeletionCleanup.removeOwnedAssets()` + repo `delete(id:)`;
  `deleteMeetingAudio(_:)` (~167-188). No selection state today.
- `MeetingsWorkspaceViewModel` delegates recents to a `TranscriptionLibraryViewModel`
  (`recentMeetingsViewModel`) — selection lives in that VM so both surfaces share it.
- Delete cascade: `TranscriptionRepository.delete(id:)` (~357) is a bare
  `Transcription.deleteOne` and the DB has `foreignKeysEnabled = true` with
  `prompt_results`, `chat_conversations`, and the LLM-run table all
  `references("transcriptions", onDelete: .cascade)`
  (`DatabaseManager.swift:31, 227-229, 404-406, 807-810`) — so a delete takes the
  AI content with it. This is why undo is out of scope.
- No undo anywhere today (deletes are permanent).

## Design

### ViewModel (mirror Dictation, adapt to Transcription)
On `TranscriptionLibraryViewModel`:
```swift
public private(set) var isBulkSelectionModeEnabled: Bool
public private(set) var selectedTranscriptionIDs: Set<UUID>
public var pendingBulkDelete: [Transcription]      // drives the alert
func beginBulkSelection(startingWith: Transcription?)
func toggleSelection(_ id: UUID)
func selectAllVisible()                              // filtered + searched only
func clearSelection()
func exitBulkSelection()
func requestDeleteSelected()
func confirmDeleteSelected() async -> BulkDeleteResult   // {succeeded, failed}
```
- `confirmDeleteSelected` runs the per-item cleanup+delete in a `Task.detached`
  loop (off the main actor), accumulates a `{succeeded, failed}` result, and exits
  mode. No snapshot (no undo in v1).

### Interaction
- **Entry:** a row context-menu item "Select Multiple…" (matches Dictation),
  plus a toolbar "Select" affordance on the Library header.
- **Selection:** tapping a row toggles its checkmark while in mode; grid cards
  show a selection overlay, list rows a leading checkbox.
- **Action bar:** appears at the bottom while in mode — `N selected ·
  Select All · Clear · Cancel · Delete`.
- **Keyboard:** `⌘A` select-all-visible, `⌫`/`Delete` → confirmation,
  `Esc` → exit. (Use SwiftUI `.onKeyPress` / commands on the focused Library
  view; verify focus behavior in the dev app.)
- **Confirmation copy (no undo, so it must be precise):**
  - files only: *"Delete N items? This permanently deletes them and their files."*
  - includes meetings: *"Delete N items, including M meetings? Audio and AI
    summaries can't be recovered."*

## Phases
1. **ViewModel selection + batch delete + tests** — port the Dictation API onto
   `TranscriptionLibraryViewModel`; off-main-thread (`Task.detached`) batch
   delete; unit tests for select-all-visible (respects filter/search), batch
   success/partial-failure result, mode teardown.
2. **Grid + list UI** — selection overlays/checkboxes, action bar (with VoiceOver
   labels); both surfaces.
3. **Keyboard** — ⌘A / Delete / Esc; dev-app verification of focus + that Delete
   doesn't fire when not in select mode.
4. **Docs** — `spec/04-ui-patterns.md` (Library multi-select), `spec/02-features.md`,
   register REQ-LIB-002.

## Testing
- ViewModel unit tests: selection toggling, `selectAllVisible` excludes
  filtered-out/searched-out rows, batch delete returns correct succeeded/failed,
  off-main-thread execution, mode teardown clears state.
- Asset-cleanup parity test: a batch delete invokes the same cleanup as the
  single-item path (no orphaned files; meeting folders removed).
- `swift test` before merge. (SwiftUI views themselves untested per repo policy —
  logic lives in the ViewModel.)

## Open questions (resolve in Phase 1)
1. **Favorites in Select All:** include favorited rows in `⌘A` (simplest) vs.
   warn/exclude. Lean: include, but the confirmation count makes scale visible.
2. **Toolbar "Select" vs. context-menu-only entry:** ship both for discoverability,
   or context-menu-only to match Dictation exactly? Lean: both.

(Resolved during PR #556 review: no undo/trash in v1 — a row-only undo would lose
cascade-deleted AI summaries/chats; rely on a precise confirmation. The batch
delete runs off the main thread.)

## Docs to update on completion
`spec/04-ui-patterns.md`, `spec/02-features.md`, `spec/README.md`,
`spec/kernel/requirements.yaml` (REQ-LIB-002), and an issue reply on #498.
