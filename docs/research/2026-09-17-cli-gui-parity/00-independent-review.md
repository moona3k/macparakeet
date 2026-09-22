# Independent review — CLI vs GUI parity (2026-09-17)

Reviewed against `origin/main` (`fb186349`) in `.worktrees/cli-gui-parity`, after six
Sonnet xhigh investigation briefs (`01`–`06`; `01` still running at review time)
plus a first-pass source audit. This file is the gate: what is true, what is
worth shipping, and what we will not build.

## Verdict

The CLI is already a strong, versioned automation surface (4.3.0), **not a GUI
mirror**. Most “missing GUI features” are correctly out of scope (live dictation,
pills, overlays, onboarding, share links behind a default-off flag, voiceprints
gated off). The remaining work that is both **real** and **small** is:

1. A Homebrew/standalone CLI bug: LLM-backed CLI paths construct `LLMService()`
   against `UserDefaults.standard`, so they miss the GUI’s saved provider in the
   shared `com.macparakeet.MacParakeet` suite.
2. Additive agent mutations that already exist in Core and the GUI: speaker
   rename/assign/merge, library title rename, a few JSON/catalog holes.

GUI-lagging-CLI (library FTS, a cards browser) is a documented ADR-027 product
split, not a wiring bug. Skip.

## Confirmed findings (kept)

| Finding | Source | Ship? |
| --- | --- | --- |
| Homebrew `cards generate` / meeting import+split auto-prompts/cards cannot see GUI LLM config | `02-config-llm.md` | **Yes** — two call sites |
| SpeechEngine / runtime prefs already pass `macParakeetAppDefaults()` | `02` | No code |
| Speaker identity mutations (rename/assign/merge/…) have no CLI wrapper | `03`, `05` | **Yes** — rename, assign, merge-speakers only |
| Timed-text CLI is meeting-only; GUI is transcription-scoped | `03`, `05` | **Follow-up** — not this PR (naming/surface decision) |
| No CLI title rename after create | `03` | **Yes** — `history rename` matching GUI gates |
| PDF/DOCX CLI omitted | `03` | **No** — headless WindowServer risk; Core already has the renderers |
| Calendar skip/unskip write | `03` | **No** — #609 explicitly left CLI as inspect-only |
| Share CLI | `03` | **No** — flag off in release |
| `history favorite/unfavorite` lack `--json` | `03` | **Yes** |
| `vocab words/snippets add` never return IDs | `05` | **Yes** |
| `spec --json` omits `transcribe --no-diarize` | `05` | **Yes** |
| `plans/README.md` still says meeting split has no implementation | `04` | **Yes** — docs |
| Library FTS / cards GUI browser | `06` | **No** — by design |
| Config: ~19 extra GUI prefs | `02` | **One key only** — `custom-vocabulary-boosting` (hidden runtime pref; Settings has status, no toggle) |

## Rejected as overengineering for this PR

- Full speaker journal (`add` / `split` / `unsplit` / `remove`) — more flag
  surface than agents need for the common repair.
- Top-level `corrections` family for file/URL — real gap, separate design.
- `prompts run --provider` optional / Keychain reuse — `LLMInlineOptions` is
  documented as stateless; changing it is a behavior call, not a bug.
- Calendar auto-start / AI formatter / mic UID / meeting auto-stop config dump.
- `spec --json` isolation field (prose in `integrations/README.md` is already
  accurate).
- Removing the `flow` alias (promised at the next major, then kept through 3.0
  and 4.0 — product decision, not a silent patch).
- GUI library search rewrite.

## Implementation slice

See `Sources/CLI/CHANGELOG.md` `[Unreleased]`. Keep `CLI.cliVersion` at `4.3.0`
until a dated release promotes the minor.

## Shipped

Implemented on `feat/cli-gui-parity`. The kept slice is in source:

- `makeSharedLLMService` for Homebrew `cards generate` and meeting import/split
  auto-prompts
- `meetings corrections rename|assign|merge-speakers`
- `history rename --title` (meeting `fileName` / file `titleOverride`; URL
  rejected)
- `--json` on `history favorite|unfavorite` and `vocab words/snippets add`
- `config` key `custom-vocabulary-boosting`
- `spec --json` `transcribe --no-diarize`, plus catalog/docs/contract updates
- `plans/README.md` meeting-split row corrected to implemented

Focused CLITests for those commands, plus `SpecCommandTests` and
`ConfigCommandTests`, passed (`swift test --filter CLITests`: 582 tests, 0
failures). A subsequent full `swift test` hung in unrelated
`MeetingRecordingLockFileStoreTests` and was stopped; this PR does not touch
that code. Follow-ups from the rejected list stay out of this PR.
