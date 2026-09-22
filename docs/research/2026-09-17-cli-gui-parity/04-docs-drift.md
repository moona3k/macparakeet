# Brief 04 — Spec / ADR / plan / integration doc drift vs live CLI

Investigated against HEAD `fb186349` (`feat/cli-gui-parity`, based on `origin/main`).
Ground truth used throughout: `CLI.cliVersion = "4.3.0"`
(`Sources/CLI/MacParakeetCLI.swift:11`), `Sources/CLI/CHANGELOG.md`,
`spec/contracts/cli-json-v1.md`, and `Sources/CLI/Commands/*.swift`.

## Method

For each item in the brief's "Investigate" list, I read the doc claim, then
checked it against the command source, `CHANGELOG.md` version headers,
`git log` on the relevant implementation files, and sibling docs
(`spec/README.md`, `integrations/README.md`, `spec/contracts/cli-json-v1.md`).
Several hypotheses from the brief did not survive contact with the code —
those are listed under "Ruled out" so the drift work isn't reopened.

## Findings

| # | File | Stale claim | Current truth (evidence) | Proposed edit |
|---|------|-------------|---------------------------|---------------|
| 1 | `plans/README.md:46` | Row `2026-09-11-issue-895-meeting-split` ("Split accidentally combined saved meetings (#895)") is marked **`TODO — IMPLEMENTATION PLAN READY`**, "no app implementation... Data-integrity, multi-track, recovery and CLI gates remain implementation work." | Fully implemented and shipped: GUI (`Sources/MacParakeet/Views/Meetings/MeetingSplitSheetView.swift`, `Sources/MacParakeetViewModels/MeetingSplitViewModel.swift`), Core (`Sources/MacParakeetCore/Services/MeetingSplit/*`, `MeetingSplitRepository.swift`), CLI (`Sources/CLI/Commands/MeetingSplitCommand.swift`: `meetings split preview\|create\|status\|resume\|discard`), shipped in `Sources/CLI/CHANGELOG.md:150` under `## [4.1.0] — 2026-09-14`. `spec/README.md:345` already states "Meeting import and split, with matching public CLI 4.1+ commands" as shipped in stable 0.8.4; `spec/contracts/cli-json-v1.md:325-343` documents the JSON contract; `integrations/README.md:646-691` and `docs/cli-testing.md:3,7-13` document live usage. `git log` on the plan/command files shows implementation and hardening commits through `e763fb28` (2026-09-12), i.e. 5 days before this HEAD. | Rewrite the row to match the sibling pattern used elsewhere in the same table (e.g. the `2026-09-05-speaker-attribution-editing` row): status `IMPLEMENTED ON MAIN` (or move to `plans/completed/`), citing the shipping commits/PR and CLI 4.1.0, and naming only the genuinely open remainder (if any — a fresh look at #895/#1046 issue threads should confirm whether anything is still open before closing the row outright). |

**This is the one finding that matches the brief's core concern** (a doc that is
factually wrong about CLI/GUI capability): a plan document tells a reader the
feature and its CLI surface don't exist, while `spec/README.md`, the
CHANGELOG, the contract doc, and the integration guide all correctly say it
shipped. An agent or contributor trusting `plans/README.md` here would
duplicate already-shipped work or wrongly tell a user the capability is
missing.

### Optional cleanup (accurate today, but worth tightening in the same pass)

| # | File | Issue | Evidence | Proposed edit |
|---|------|-------|----------|---------------|
| 2 | `docs/cli-testing.md:55-57` | "`flow` is a deprecated compatibility alias for `vocab` and remains accepted in CLI 3.x." | The `flow`→`vocab` rename shipped in `## [2.3.0] -- 2026-05-16` (`Sources/CLI/CHANGELOG.md:935-940`), a **minor** release that kept `flow` as a deprecated alias "for this minor release... and will be removed at the next major CLI version." Two major bumps have since passed (`3.0.0`, `4.0.0`) and `flow` is still registered as an alias today (`Sources/CLI/Commands/VocabCommand.swift:17`, `aliases: ["flow"]`). The doc's "in CLI 3.x" phrasing is now two majors behind and could read as if `flow` stopped working after 3.x, which is false — it still works on 4.3.0. | Reword to something version-agnostic, e.g. "`flow` is a deprecated compatibility alias for `vocab`; it has survived the 3.0.0 and 4.0.0 major bumps and remains accepted. Use `vocab` in new scripts — removal requires a future major-version contract change and a matching changelog entry." Not urgent: no one is misled about a *missing* capability, only about which major versions accept the alias. |
| 3 | `docs/cli-testing.md` `## Meetings` section (lines 478-500) | The worked examples list `meetings list/show/transcript/notes/results/export` but never demonstrate `meetings split` or `meetings import`, even though both are fully shipped (see finding #1) and are documented with full examples in `integrations/README.md:639-691`. | The only mentions of split/import in this file are the terse test-filter note at the very top (lines 3-13), which has no example invocations. A reader skimming the `## Meetings` section for "what can I test" would miss two shipped command trees. | Add a short subsection (or a couple of example lines) for `meetings split preview/create/status/resume/discard` and `meetings import` under `## Meetings`, mirroring the intro note's pointer to `--help`/`spec --json`. This is a coverage gap, not a false statement — the intro paragraph is accurate — so it can ride along with finding #1's PR rather than blocking it. |

## Ruled out (checked, not stale)

- **`spec/README.md` release-table CLI version vs `CLI.cliVersion`** — both say
  `4.3.0` (`spec/README.md:84-85` vs `MacParakeetCLI.swift:11`). Consistent.
- **`spec/README.md:345`** ("Meeting import and split, with matching public
  CLI 4.1+ commands") — verified against `CHANGELOG.md`: both `meetings split`
  and `meetings import <path>` shipped under `## [4.1.0] — 2026-09-14`.
  Accurate.
- **`integrations/README.md` vs actual commands** — read in full (942 lines).
  Split/import, transforms, prompts, quick-prompts, cards, search, transcript,
  calendar, and safety/isolation sections all match current command surfaces
  and JSON conventions in `spec/contracts/cli-json-v1.md`. No "not yet
  implemented" / "planned" / "TODO" language found that contradicts shipped
  code (grepped for `not yet|planned|coming soon|does not support|TODO`).
- **ADR-022 (Transforms) CLI claims** — "CLI parity via `macparakeet-cli
  transforms` subcommand tree" (line 106) matches
  `Sources/CLI/Commands/TransformsCommand.swift` and the `## Transforms`
  section of `docs/cli-testing.md:676-701`. Accurate.
- **ADR-020 (notepad/memo) CLI claims** — "`prompts set <prompt>
  --include-meeting-notes` / `--no-include-meeting-notes`" (line 55) matches
  `Sources/CLI/Commands/PromptsCommand.swift:651`. Accurate.
- **ADR-031 (timed transcript corrections) CLI claims** — "the app, search, AI
  context, shares, exports, meeting artifacts, and CLI must consume that
  projection" and "Implemented surfaces... CLI meeting JSON" (lines 43, 124-128)
  are hedged design statements, not falsifiable version/command claims, and
  match the shipped correction-aware export/JSON code. No drift.
- **`spec/contracts/cli-json-v1.md`** — already documents `meetings import
  --json` (line 274) and the split operation payloads (lines 325-343) in
  full. Not stale.
- **REQ-CLI comments claiming missing features now shipped** — only two
  `REQ-CLI-*` IDs exist repo-wide (`docs/historical/requirements-legacy.yaml:369,374`,
  plus a reference in `spec/02-features.md:464`). Both are explicitly marked
  `status: implemented` already; the legacy file is intentionally frozen per
  `AGENTS.md` ("do not add new REQ IDs... for old references only"). No drift
  to fix.
- **`integrations/skill/macparakeet-stt/SKILL.md`** (the in-repo
  website/integrations skill) — generic, defers to `spec --json` and the
  canonical guide rather than hardcoding a command list or version number. No
  stale claims.
- **`plans/README.md:22`** (Audio Speaker Timeline #836) — says "app/CLI
  implementation... remain pending." Verified no matching code exists
  (`grep -rl "SpeakerTimeline"` under `Sources/CLI`, `Sources/MacParakeetCore`
  returns nothing). Claim is still true; not drift.
- **Meeting import (#906) plans-board row** — no such row exists in
  `plans/README.md`; the feature shipped directly (CHANGELOG 4.1.0,
  `MeetingImportCommand.swift`, commit `eb89658d`) without ever being tracked
  as a stale board entry. Nothing to fix.

## Must-fix vs optional

- **Must-fix in the same PR:** #1 (`plans/README.md:46`). This is the only
  claim that actively tells a reader a shipped CLI/GUI capability doesn't
  exist, which is exactly the failure mode the brief is guarding against.
- **Optional cleanup (can ride along, not blocking):** #2 and #3
  (`docs/cli-testing.md`) — both are about precision/coverage of an already-
  accurate document, not a false capability claim.
