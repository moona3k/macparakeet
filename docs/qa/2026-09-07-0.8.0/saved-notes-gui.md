# Saved notes: completed GUI verification

**PASS: six saved-notes checks on the combined candidate.** Source `250bbe2994a4b60b4ef81ac257f0ee6bb70874d3`, app `0.8.0`, build `20260907232424`. Root exercised an isolated copy of the signed Release app, with the actual open SQLite path verified inside the owned QA home.

The existing public-speech meeting exposed Transcript, Notes and Chat tabs. Its Notes editor opened empty with zero words and Saved state. Root typed distinctive synthetic notes through the real editor, then checked exact persisted values and unchanged raw transcript fields.

| Check | Observed result |
| --- | --- |
| Autosave | Typed notes reached Saved and exact SQLite equality without changing the transcript. |
| Detail navigation | Leaving and reopening the meeting retained the saved notes. |
| Revision then navigation | A newly typed navigation revision remained after reopening. |
| Ordinary quit | The latest typed quit/reopen revision remained persisted after normal termination. |
| Relaunch | Reopening the same meeting displayed the latest notes, including both revision lines. |
| Derived file | `notes.md` contained the latest notes after quit/relaunch; 241 bytes, SHA-256 `a00cbbb9187071235c95377fae277c8ee12ebdeb1ac0dd236dfbdb3bb5459181`. |

The [six-check receipt](evidence/gui-rebuilt/saved-notes-gui-results.json) preserves the exact synthetic note, sidecar result and timing limitations. [Autosaved notes](evidence/gui-rebuilt/notes-autosaved-current.png) and [reopened latest revision](evidence/gui-rebuilt/notes-reopened-current.png) were individually inspected and copied unchanged. The [manifest](evidence/gui-rebuilt/manifest.json) records their candidate and hashes. The earlier [empty Notes screen](evidence/gui-rebuilt/notes-empty-current.png) remains useful initial-state evidence.

## Interrupted attempt and successful rerun

The first navigation attempt was invalidated when unrelated concurrent desktop input reached the editor and autosaved. Root stopped mouse/keyboard actions and preserved that input privately. Its screenshot, raw AX tree and note contents are excluded. Once the user made the desktop available, root reran the synthetic scenario and completed all six checks above. The newly inspected captures replace the interrupted attempt as evidence.

Numeric AX indices from earlier snapshots could target different elements after transient windows or menus changed the tree. Resolving targets by stable attributes inside the same process that performed the action corrected navigation. The initial relaunch check also ran before the actual startup alert appeared; waiting for the observable startup state allowed the final reopen check to complete.

## Reusable method and limits

Use an owned meeting, enter distinctive synthetic notes, wait for Saved and exact SQLite equality, then navigate away and reopen. Repeat after a revision and after ordinary quit/relaunch. Compare `notes.md` and unchanged transcript fields. Resolve action targets immediately from stable attributes, and wait for actual application state after launch.

UI command overhead may allow the debounce to finish before navigation or quit, so this pass does not force a pending-save race or prove crash durability between a keystroke and persistence. The [independent source/merge review](new-main-notes-review.md) and [694 combined focused tests](evidence/merged-notes-focused-summary.log) supply separate ordering/error coverage. Clear-all, two-meeting note isolation, save-failure dialogs and live prompt-context generation were not added to this six-check GUI pass. No external provider was configured or contacted.
