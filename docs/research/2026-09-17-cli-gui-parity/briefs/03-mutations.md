# Brief 03 — Mutation parity: corrections, rename, export

One concern: verify which Core mutation APIs the GUI uses that the public CLI still cannot invoke, and which of those are cheap/safe to expose.

## Settled

- Timed-text CLI already exists: `meetings corrections edit-line|merge-lines|undo|redo|reset` (revision-checked).
- `SpeakerCorrectionCommand` also has rename/add/assign/split/removeSplit/merge/remove.
- `ExportService` already has `@MainActor exportToPDF` and `exportToDocx`. CLI `ExportFormat` currently omits pdf/docx (`Tests/CLITests/ExportCommandTests.swift` asserts nil).
- `TranscriptionRepository.updateTitleOverride` exists.

## Investigate

1. Are speaker attribution writes GUI-only? Is there any CLI path? Would wrapping the existing `runMeetingCorrection` helper be sufficient, or do file/URL transcriptions also need a command (GUI can correct those too)?
2. Title rename: GUI path vs CLI. Meetings vs files vs dictations.
3. PDF/DOCX CLI: any reason they were omitted (MainActor, AppKit in CLI process, size, contract)? Is exposing them additive-safe?
4. Calendar skip/unskip: GUI mutates `CalendarAutoStartPreferences`; CLI `calendar upcoming` only annotates.
5. Share snapshots: GUI-only? Flag-gated? Do not recommend shipping if still default-off / incomplete.
6. Favorite/unfavorite `--json` completeness vs other mutators.

## Fences

- Read-only. Write only: `docs/research/2026-09-17-cli-gui-parity/03-mutations.md`
- Recommend the smallest command shapes that reuse Core. No new services.

## Done

For each candidate: Core API, GUI call site, CLI gap, contract impact (minor CLI bump?), test seams, recommendation ship/skip with why.
