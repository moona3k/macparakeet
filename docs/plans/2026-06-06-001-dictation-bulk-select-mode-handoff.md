---
title: "fix: Gate dictation multi-select behind bulk mode"
type: fix
status: active
date: 2026-06-06
origin: "Issue #425 / PR #445 product review"
---

# Dictation Bulk-Select Mode Handoff

## Context

Current `main` includes PR #445, `[codex] Add multi-select dictation cleanup`,
which implemented issue #425: "Allow multi-select when cleaning up dictations."
The mechanics are sound: selected IDs are tracked in
`DictationHistoryViewModel`, pending multi-delete stores `Dictation` snapshots,
delete work runs off the main actor, and tests cover selection, pruning,
snapshot stability, and batch delete.

The product review found a UX mismatch. The current UI always renders a radio-
style selection circle on every dictation row. That makes ordinary history
browsing feel like a selection workflow, even though bulk selection is only
needed for cleanup.

Desired product direction: selection controls should be hidden by default.
Users should enter a deliberate bulk-selection mode from the row ellipsis menu,
then select/delete multiple dictations from that mode.

## Current Evidence

- Current branch during review: `main` at `5e0b7ad2`.
- Merged PR: https://github.com/moona3k/macparakeet/pull/445
- Source issue: https://github.com/moona3k/macparakeet/issues/425
- Post-merge follow-up: `3a344c45` fixed alert-copy flicker and the fragile
  async test helper.
- Verification already run after review:
  - `swift test --filter DictationHistoryViewModelTests`
  - `swift test`
- Full-suite result: 3306 XCTest tests, 10 hardware-gated skips, 0 failures,
  plus 16 Swift Testing tests passed.

## Problem

The implementation currently has selection state but no explicit selection
mode:

- `Sources/MacParakeetViewModels/DictationHistoryViewModel.swift`
  - `selectedDictationIDs` is the only mode signal.
  - `hasSelectedDictations` controls whether the selected-actions bar appears.
- `Sources/MacParakeet/Views/History/DictationHistoryView.swift`
  - `SelectionToggleButton` is always rendered in `DictationCardRow`.
  - The selected-actions bar appears only after a row has already been selected.
  - `CardMenuButton` only exposes row actions: export audio, AI edit toggle,
    and delete.

This is technically coherent, but it overexposes bulk-cleanup UI in the default
history view.

## Lifecycle Constraint (important)

`historyViewModel` is a **process-lifetime singleton** owned by `AppDelegate`
(`Sources/MacParakeet/AppDelegate.swift`), and the Dictations tab is mounted
conditionally — `case .dictations: DictationHistoryView(viewModel: historyViewModel)`
in `MainWindowView.swift`. There is no `onAppear`/`loadDictations` reset when the
view re-appears.

Consequence: any "selection mode" state on the view model survives the user
navigating away from the Dictations section entirely (to Settings, Transcribe,
etc.) and back. So bulk mode must be exited on **two** boundaries, not one:
the History↔Stats sub-tab switch *and* leaving the Dictations section. Missing
the second leaves the user staring at a stale bulk-selection view on return.

## Desired Behavior

Default history browsing:

- No selection circles on rows.
- Existing row actions remain: play, copy, ellipsis menu.
- Single-row delete remains available from the ellipsis menu.

Entering bulk mode:

- The row ellipsis menu gets a neutral item: `Select Multiple...`.
- Choosing it enters bulk-selection mode and preselects that row.
- Only in bulk-selection mode do row selection circles render.
- The selected-actions bar renders because bulk mode is active, not because the
  selected count is nonzero.
- Once in bulk mode, the per-row `Select Multiple...` item is hidden (it is
  redundant). Single-row delete / export / AI-edit toggle remain available.

Bulk mode action bar:

- Shows `N selected`.
- Includes `Select All`, `Clear`, `Cancel`, and destructive `Delete`.
- `Delete` is disabled when `N == 0`.
- `Clear` is disabled when `N == 0`.
- `Cancel` exits bulk mode and clears selection.
- `Delete` uses the existing confirmation dialog and existing delete semantics.

Leaving bulk mode (all four paths):

- Confirmed delete exits bulk mode and clears selected IDs.
- Canceling the delete confirmation keeps bulk mode and the current selection,
  so the user can adjust the selection.
- Switching from the History sub-tab to Stats exits bulk mode and clears
  selection.
- Navigating away from the Dictations section exits bulk mode and clears
  selection (see Lifecycle Constraint).

## Recommended Implementation

### Unit 1 - Add Explicit Selection Mode to the View Model

File:

- `Sources/MacParakeetViewModels/DictationHistoryViewModel.swift`

Add explicit state:

- `public var isBulkSelectionModeEnabled = false`

Add methods, keeping names local-style and small:

- `beginBulkSelection(startingWith dictation: Dictation)`
  - Sets `isBulkSelectionModeEnabled = true`.
  - Inserts the starting row ID into `selectedDictationIDs`.
- `exitBulkSelection()`
  - Sets `isBulkSelectionModeEnabled = false`.
  - Clears `selectedDictationIDs`.

Leave `clearSelection()` exactly as-is — it empties `selectedDictationIDs` and
must **not** touch mode (so the bulk bar's `Clear` deselects without exiting).
`exitBulkSelection()` is the separate "leave the mode" path. Do not overload
`clearSelection`.

Reuse `hasSelectedDictations` for the bar's disabled states; do not add a new
`canDelete...` computed property — it would just duplicate `hasSelectedDictations`.

Adjust delete flow:

- `requestDeleteSelectedDictations()` keeps its snapshot behavior.
- `confirmDeleteSelectedDictations()` exits bulk mode after the empty-guard
  passes (only when a delete actually happens):

  ```swift
  public func confirmDeleteSelectedDictations() {
      let selectedDictations = pendingDeleteSelectedDictations
      pendingDeleteSelectedDictations = []
      guard !selectedDictations.isEmpty else { return }
      isBulkSelectionModeEnabled = false      // <- exit only on real delete
      deleteDictations(selectedDictations)
  }
  ```

  The mode flip is synchronous; selection is cleared by the existing
  `selectedDictationIDs.subtract(ids)` in the delete path.
- `cancelPendingDelete()` must NOT exit bulk mode and must NOT clear
  `selectedDictationIDs` (it already only clears the pending snapshot) — canceling
  an alert should let the user keep editing the selection. No change needed there.

Adjust tab behavior:

- In the `selectedSubTab` `didSet`, exit bulk selection whenever the tab is no
  longer History (`selectedSubTab != .history`), not specifically `== .stats`.
  Selection is a History-only affordance, and keying off "not History" is robust
  to a future third sub-tab.

Keep existing safeguards:

- Do not remove `pendingDeleteSelectedDictations` snapshot behavior.
- Do not move disk/database delete work back onto the main actor.
- Do not regress playback stop when deleting the currently playing dictation.

No telemetry event is added for entering bulk mode or bulk delete. This is
deliberate scoping: a new `TelemetryEventName` case requires a companion
allowlist update in the website Worker (which rejects the whole batch on unknown
events), and the existing per-row delete already emits `dictationDeleted`. A
usage-signal event can be a follow-up if needed.

### Unit 2 - Hide Row Selectors Until Bulk Mode

File:

- `Sources/MacParakeet/Views/History/DictationHistoryView.swift`

At the call site for `DictationCardRow`, pass a new flag:

- `showsSelectionControls: viewModel.isBulkSelectionModeEnabled`

In `DictationCardRow`:

- Add `var showsSelectionControls: Bool = false` (default keeps the type usable
  without the flag).
- Render `SelectionToggleButton` only when `showsSelectionControls` is true.
- When false, row content starts where it did before PR #445: mandala,
  timestamp metadata, actions, transcript.
- Selected-row tint/stroke (`cardFill`/`cardStroke`) key off `isSelected` and are
  automatically inert outside bulk mode (exiting clears selection), so no extra
  guard is required there.

### Unit 3 - Add Bulk Entry to the Ellipsis Menu

File:

- `Sources/MacParakeet/Views/History/DictationHistoryView.swift`

Extend `CardMenuButton`:

- Add `showsBulkSelectionEntry: Bool` and `onBeginBulkSelection: () -> Void`.
- Add a neutral menu item named `Select Multiple...`, shown only when
  `showsBulkSelectionEntry` is true (i.e. not already in bulk mode).
- Use a non-destructive icon such as `checklist`.
- The menu action only enters mode and preselects the row. It does not delete.

In `DictationCardRow`, pass `showsBulkSelectionEntry: !showsSelectionControls`
and forward an `onBeginBulkSelection` closure (call site wires it to
`viewModel.beginBulkSelection(startingWith: dictation)`).

Recommended menu order:

1. Row-specific non-destructive actions (`Export Audio`, `Undo AI edit` /
   `Re-apply AI edit`).
2. `Select Multiple...` (only when not in bulk mode).
3. Separator.
4. Destructive `Delete`.

Avoid naming the menu item `Bulk Delete...`: it sounds destructive, but the
first action only enters selection mode.

### Unit 4 - Make the Action Bar Mode-Based

File:

- `Sources/MacParakeet/Views/History/DictationHistoryView.swift`

Change the action bar condition:

- From `if viewModel.hasSelectedDictations`
- To `if viewModel.isBulkSelectionModeEnabled`

Also retarget the bar's appear/disappear animation trigger (the
`.animation(..., value:)` modifier on the History content `VStack`) from
`viewModel.hasSelectedDictations` to `viewModel.isBulkSelectionModeEnabled`, so
the bar animates on mode enter/exit (e.g. Cancel after the user has cleared all
rows, where `hasSelectedDictations` would not change).

Update the bar actions:

- `Select All`: calls `selectAllVisibleDictations()`, disabled when all visible
  rows are already selected (unchanged).
- `Clear`: calls `clearSelection()`, disabled when no selected rows.
- `Cancel`: calls `exitBulkSelection()` (subtle/low-emphasis styling).
- `Delete`: calls `requestDeleteSelectedDictations()`, disabled when no
  selected rows.

Keep the selected count visible even at zero, because a zero-selection state is
valid while the user is in bulk mode and has cleared all rows.

### Unit 5 - Exit Bulk Mode When Leaving the Dictations Section

File:

- `Sources/MacParakeet/Views/MainWindowView.swift`

Add `.onChange(of: state.selectedItem)` to the `MainWindowView` body, calling
`historyViewModel.exitBulkSelection()` whenever `newItem != .dictations`. Because
the view model is a long-lived singleton and the Dictations tab is conditionally
mounted (see Lifecycle Constraint), bulk mode would otherwise survive navigating
to another top-level section and back.

Handle this at the navigation boundary in the parent rather than via
`DictationHistoryView.onDisappear`: on macOS, `onDisappear` can fire during
transient view-lifecycle events (window resize, parent re-render) and reset an
active selection while the user is still browsing. `onChange(of: selectedItem)`
fires only on actual navigation. (This also retroactively fixes the pre-existing
wart where a raw selection from PR #445 survived top-level navigation.)

### Unit 6 - Tests

File:

- `Tests/MacParakeetTests/ViewModels/DictationHistoryViewModelTests.swift`

Add focused tests (the mode flips are synchronous, so these assert directly
without `await` except where the async delete pipeline is involved):

- `testBeginBulkSelectionEnablesModeAndPreselectsStartingDictation`
  - Mode is enabled and selected count is 1 with the starting row's ID.
- `testExitBulkSelectionClearsModeAndSelection`
  - Mode false and selected IDs empty.
- `testClearSelectionKeepsBulkSelectionModeActive`
  - Supports the user clearing and reselecting without reopening the menu.
- `testCancelPendingSelectedDeletePreservesBulkSelectionMode`
  - User cancels confirmation, keeps mode and the existing selection.
- `testConfirmDeleteSelectedDictationsExitsBulkSelectionMode`
  - Mode flips false synchronously on confirm (assert before the async delete
    resolves).
- `testSingleRowDeleteFromMenuKeepsBulkSelectionMode`
  - A per-row pending delete (`pendingDeleteDictation` + `confirmDelete()`) inside
    bulk mode does not exit the mode.
- `testSwitchingToStatsExitsBulkSelectionMode`
  - Selection UI is History-only.

Existing tests to preserve:

- Selection toggling.
- Select-all uses current visible/search results.
- Search reload prunes selected IDs.
- Pending selected delete stores row snapshots across search reload.
- Batch delete removes multiple rows and clears selection.
- Deleting the playing dictation stops playback.

## Acceptance Criteria

- Default History list has no left-side selection circles.
- Opening a row ellipsis menu exposes `Select Multiple...`.
- Choosing `Select Multiple...` shows row selection circles, preselects that
  row, and shows the bulk action bar.
- In bulk mode, the per-row ellipsis no longer offers `Select Multiple...`.
- Bulk delete still requires the existing confirmation dialog.
- Canceling the delete confirmation preserves bulk mode and selection.
- Confirming delete exits bulk mode after deletion is accepted.
- Switching to the Stats sub-tab exits bulk mode.
- Navigating away from the Dictations section and back shows the default
  (non-selection) view.
- Single-row delete from the ellipsis menu still works.
- Audio export, copy, playback, and AI edit toggle behavior do not regress.

## Verification

Run:

```bash
swift test --filter DictationHistoryViewModelTests
swift test
git diff --check
```

Manual smoke with the app is recommended because this is a visual/interaction
polish change:

```bash
scripts/dev/run_app.sh
```

Smoke steps:

1. Open Dictations history.
2. Confirm default rows have no selection circles.
3. Open a row ellipsis menu and choose `Select Multiple...`.
4. Confirm the chosen row is selected and selection circles appear.
5. Confirm the ellipsis menu no longer shows `Select Multiple...` while in mode.
6. Select/deselect several rows.
7. Clear selection and confirm bulk mode remains active (bar still visible,
   `0 selected`, Delete/Clear disabled).
8. Cancel bulk mode and confirm circles disappear.
9. Re-enter bulk mode, switch to Stats and back — confirm bulk mode is gone.
10. Re-enter bulk mode, navigate to Settings and back to Dictations — confirm
    bulk mode is gone.
11. Re-enter bulk mode and delete multiple rows through confirmation.

## Suggested Skills For Next Agent

- `compound-engineering:ce-work` for implementation.
- `compound-engineering:ce-code-review` after the change.
- `browser-use` or app screenshot tooling only if visual verification is needed
  beyond `scripts/dev/run_app.sh`.
