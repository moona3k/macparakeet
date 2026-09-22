# Brief 01 — CLI vs GUI command/feature matrix

One concern: produce a complete, source-cited matrix of MacParakeet GUI capabilities vs `macparakeet-cli` commands on this checkout (`origin/main` at HEAD).

## Settled

- The CLI is a first-class automation surface, **not a GUI mirror**. See `integrations/README.md` "Out of scope (by design)".
- Do not recommend adding live mic dictation, live meeting UI, onboarding, overlays, or sounds.
- Classify every gap as: `by-design` | `meaningful-automation-gap` | `robustness-bug` | `docs-drift` | `not-worth-it`.

## Investigate

Walk `spec/02-features.md`, Settings UI (`Sources/MacParakeet/Views/Settings/`, `SettingsViewModel.swift`), Library/Meetings/Prompts/Transforms, and `Sources/CLI/` (MacParakeetCLI.swift + Commands/).

Cover at least: dictation, file/URL/podcast transcription, meetings (record/import/split/notes/results/labels/corrections), library (search, rename, favorite, delete, export), prompts/quick-prompts/transforms, vocab, models/engines, calendar auto-start, share links, cards/search/transcript, config, health, LLM.

## Fences

- Read-only. Do not edit product code, tests, git, or other agents' output files.
- Write only: `docs/research/2026-09-17-cli-gui-parity/01-command-matrix.md`
- Do not use Unblocked MCP.

## Done

File exists with:
1. Matrix table: GUI surface | CLI command | classification | evidence (`path:line`)
2. Top 10 candidate improvements, ranked by agent usefulness vs implementation cost
3. Explicit "do not build" list with reasons
4. Doubts / things you could not verify
