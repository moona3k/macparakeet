# Label management and prompt-list follow-up

## User feedback

- Creating a label with existing assigned labels leaves excessive vertical space in the editor.
- Existing labels cannot be renamed or recolored in the app.
- The Result badge is redundant, including in All prompts.
- Dictation history shows an expand chevron for text that already fits; expansion must follow actual truncation, including after resizing.

## Accepted direction

Keep assignment quick: search, create, and select labels in the recording popover. Short contents should determine its height; long contents should scroll within a bounded viewport. Assigned labels remain reachable while searching.

Expose one reusable Manage labels sheet from the recording editor and the library filter. Provide search, rename, a compact color palette including Automatic, and archive/restore. Renaming or recoloring preserves the label identity and its existing assignments. Archive hides a label from new choices without deleting recordings or existing assignments. Do not introduce permanent deletion in this change.

Present management from a stable parent view, so dismissing its launching popover cannot dismiss or constrain the sheet. Show validation or persistence failures instead of reporting a successful edit. Refresh loaded label presentations after a successful global change.

Keep the existing CLI rename and archive commands compatible; add explicit metadata editing and color reset for agent parity, with documented JSON behavior and validation.

Do not show a Result badge. In mixed lists, mark Transform rows to distinguish them from the default transcript prompts. Preserve type metadata and filtering behavior.

## Verification targets

- Compact recording editor with assigned chips and an unmatched query/create action.
- Empty, short, long, and changing label lists; all options remain reachable.
- Rename and color updates preserve identity and assignments across recordings.
- Blank/duplicate names and failed writes remain visible without false success.
- Archive/restore and Automatic color work from management and the CLI.
- Result badges are absent from all active lists; Transform badges distinguish Transform rows in mixed lists.
- Dictation expansion appears only when the three-line preview hides text; expanded rows retain a collapse action.
- Native popover tests run reliably; investigate the observed signal-11 crashes before treating CI as green.

## Release status

This follow-up changes the source after candidate `a82ae130`. That candidate's signed artifacts do not certify these changes. Final source checks, a rebuilt app, and fresh release preparation are required before publication.

## Local verification

The combined focused gate passed 72 tests: 10 dictation presentation, 3 label sizing, 18 classification view-model, 25 meeting CLI, and 16 CLI spec tests. Independent review found and verified a deferred refresh fix for label edits during assignment saves. The native sizing tests now use NSHostingView without creating private AppKit popover windows. Full-suite verification remains owned by CI.
