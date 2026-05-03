# Unified Quick Prompts — pin-to-strip mechanic

> Status: **ACTIVE** — 2026-05-03
> Ship target: **app v0.7.x** (post-v0.7.0)
> Branch: `feat/unified-quick-prompts`
> Predecessor: `plans/completed/2026-05-ask-quick-prompts.md` (shipped 2026-05-02)
> Related: ADR-018 (live meeting Ask), ADR-013 (prompt library — pattern reference), `plans/active/cli-as-canonical-parakeet-surface.md`
> Touches: `Sources/MacParakeetCore/Models/QuickPrompt.swift`, `Sources/MacParakeetCore/Database/{QuickPromptRepository,DatabaseManager}.swift`, `Sources/MacParakeetCore/Models/QuickPromptBundle.swift`, `Sources/MacParakeetViewModels/QuickPromptsViewModel.swift`, `Sources/MacParakeet/Views/MeetingRecording/{AskPromptsSheet,LiveAskPaneView}.swift`, `Sources/CLI/Commands/QuickPromptsCommand.swift`, `Sources/CLI/CHANGELOG.md`, four test files, ADR-018.

## Overview

Collapse the artificial Starter / Follow-up distinction in Ask quick prompts into **one unified library** rendered in two presentation modes, with a **pin** mechanic controlling which prompts appear in the after-response strip.

**Before** (shipped 2026-05-02): two `kind` values (`.starter`, `.followUp`) drive separate model paths, separate VM properties, separate sheet sections, separate CLI flags, and separate empty-state vs strip render filters. Both kinds are "prebuilt prompts to inspire" — the categorical split was load-bearing only for placement, not semantics.

**After**: one prompt entity with `isPinned: Bool`. Empty state / sparkle popover renders all enabled prompts grouped by user-provided `groupLabel`. After-response strip renders only pinned prompts (cap of 5). One library, one editor, one mental model.

## Why now

- The two-kind model created papercut friction in the editor (two sections, two "Add" affordances, two restore-defaults menus, awkward CLI `--kind` everywhere) for what users perceive as one feature.
- Dropping `kind` from the public CLI surface removes a flag from every relevant subcommand and an enum from JSON output, simplifying agent integrations (OpenClaw / Hermes).
- The codebase is fresh — predecessor plan shipped one day ago — so there's minimal sediment of `kind`-aware code that would resist refactoring.

## Design decisions (settled)

1. **Drop `QuickPrompt.Kind` entirely.** No vestigial computed property, no compatibility shim on the model. Conversion is lossless: `kind == .followUp` ↔ `isPinned == true`.
2. **Cap pinned at 5.** Matches today's strip count and the Apple-platform "favorites strip" idiom (iOS Dock = 4, Finder sidebar = 4–6). Hard cap, but enforced through a polite **swap picker** rather than a disabled button.
3. **Swap picker is the cap-overflow UX.** Tapping pin on a 6th prompt opens a small popover listing the 5 currently pinned; selecting one unpins it and pins the new one in a single transaction. Better than silent disabled-button (mysterious) and better than auto-unpin-oldest (loses user choice).
4. **Pin icon is row-level and always visible.** Filled in pinned section, outline in unpinned. First control on the row, sibling to the existing visibility toggle. Matches the toggle's prominence because the two flags answer symmetric questions (active? pinned?).
5. **Editor sheet shows two visual zones in one list.** "PINNED · n/5" header on top, "ALL PROMPTS" header below. One semantic library, two rendered zones — same data shape used at runtime.
6. **`groupLabel` is now available on every prompt**, not just starters. Pinned prompts can carry a group too — it's still presentation-only and only renders in the empty-state grouped layout.
7. **Group matching is case-insensitive.** "CAPTURE" and "Capture" fold into one group; the first existing casing wins so imports and CLI edits do not fork visually identical groups.
8. **Long pinned titles truncate with `…` + `.help()` tooltip.** No `shortLabel` field in v1. Add later if telemetry shows real friction.
9. **Reconciler stays insert-only for built-in identity, but built-in seeds now carry `isPinned`.** The 5 universal moves seed pinned; the 9 starters seed unpinned. `seedIfNeeded()` semantics unchanged: never updates an existing user-edited row.
10. **Bundle schema bumps to v2.** v2 emits `isPinned`. v1 still decodes via fallback (`kind == "follow_up"` → `isPinned: true`). Schema validation accepts both.
11. **CLI takes a MAJOR bump.** Removing `--kind` and changing JSON shape (`kind` field gone) is breaking. No deprecated alias is retained in 2.0.0; parse-time failures keep exit code `2`.

## Migration shape

Single migration `v0.10.1-quick-prompts-pin`:

```sql
ALTER TABLE quick_prompts ADD COLUMN isPinned INTEGER NOT NULL DEFAULT 0;
UPDATE quick_prompts SET isPinned = 1 WHERE kind = 'follow_up';
DROP INDEX idx_quick_prompts_kind_sort;
ALTER TABLE quick_prompts DROP COLUMN kind;
CREATE INDEX idx_quick_prompts_pinned_sort ON quick_prompts(isPinned, sortOrder);
```

SQLite 3.35+ supports `DROP COLUMN`; macOS 14.2 ships 3.41+, so this is safe. The migration is one-way — older binaries opening a migrated DB will see no `kind` column and fail to decode the model. The codebase doesn't support binary downgrade in general, so this is acceptable; documenting it explicitly here for posterity.

**Custom-prompt edge case.** A user who used the CLI to add many `--kind follow-up` customs may end up with >5 pinned post-migration. The migration leaves them all pinned (lossless); on next launch, the strip renders the first 5 by sortOrder, and the rest appear pinned in the editor with the cap at "n/5" where n > 5. The first attempt to pin an additional row triggers the swap picker, which the user can use to unpin the over-cap rows. We do **not** auto-unpin during migration or import — that loses user state.

## CLI semver impact

Bump `macparakeet-cli` to **2.0.0**.

| Change | Type | Notes |
|---|---|---|
| `quick-prompts list --kind` removed | breaking | Use `list --pinned <true\|false>` |
| `quick-prompts list --pinned <true\|false>` added | additive (within MAJOR) | New filter |
| `quick-prompts pin <id>` added | additive | New subcommand |
| `quick-prompts unpin <id>` added | additive | New subcommand |
| `quick-prompts add --kind` removed | breaking | New prompts default unpinned; use `add --pinned` to pin immediately |
| `quick-prompts add --group` no longer starter-only | broadened | Backward-compatible widening |
| `quick-prompts set --group` no longer starter-only | broadened | Backward-compatible widening |
| `quick-prompts restore-defaults --kind` removed | breaking | Restore all built-ins or one built-in via `--id` |
| `quick-prompts export --kind` removed | breaking | Replace with `export --pinned <true\|false>` |
| JSON output: `kind` field removed, `isPinned` field added | breaking | Documented in CHANGELOG |
| Bundle schema bumped 1 → 2 | additive (v1 still decodes) | Decoder fallback preserves v1 round-trip |

`Sources/CLI/CHANGELOG.md` gets a "## [2.0.0]" entry calling out the breaking changes and the one-release deprecation window.

## Acceptance criteria

| # | Criterion | How verified |
|---|---|---|
| AC1 | Existing DB with starter + follow-up rows migrates cleanly; all rows preserved with correct `isPinned` mapping | Migration test against fixture DB |
| AC2 | After-response strip renders exactly the visible+pinned prompts, in their sortOrder | VM test + manual smoke |
| AC3 | Empty-state list and sparkle popover render all visible prompts grouped by `groupLabel`, with first-occurrence group order | VM test (existing test adapted) |
| AC4 | Pinning a 6th prompt opens a swap picker; selecting an entry unpins it and pins the new one atomically | Repository test for atomic swap, VM test for picker state |
| AC5 | Pin icon visible state: filled in pinned section, outline in unpinned section | Manual visual smoke + sheet snapshot via VM properties |
| AC6 | Bundle v1 file imports cleanly into v2 schema; v2 export round-trips | Bundle test for v1 forward, v2 round-trip |
| AC7 | CLI `--kind` is rejected by the 2.0.0 parser with exit code `2` | CLI test |
| AC8 | CLI `pin <id>` and `unpin <id>` work; pinning at cap returns structured error with current pinned list | CLI test |
| AC9 | All previously passing tests pass | `swift test` green |

## Test plan

Adapted (existing files):
- `Tests/MacParakeetTests/Database/QuickPromptRepositoryTests.swift` — replace `kind`-based tests with `isPinned`-based; add `setPinned` cap + atomic swap tests.
- `Tests/MacParakeetTests/ViewModels/QuickPromptsViewModelTests.swift` — replace starter/followup property tests with unified-prompts + pinned subset tests.
- `Tests/MacParakeetTests/QuickPromptBundleTests.swift` — add v1→v2 fallback test, v2 round-trip.
- `Tests/CLITests/QuickPromptsCommandTests.swift` — replace `--kind` tests with `--pinned`; add `pin`/`unpin` tests; add parser-rejection test for `--kind`.

New (within existing files where possible):
- Migration test: insert pre-migration DB shape, run migrator, assert `isPinned` derivation and `kind` column gone.
- Swap-picker happy-path: pinning at cap returns `.capExceeded(currentlyPinned:)` from VM; calling `pinSwap(unpin:pin:)` succeeds atomically.

Target after work: same number of passing tests as before, +~20 new tests.

## Risks + mitigations

1. **Destructive one-way migration.** Mitigation: SQL is well-formed, fixture migration test exercises real pre-state, and SQLite 3.35+ `DROP COLUMN` is widely supported on the target OS floor.
2. **CLI break for downstream agents (OpenClaw / Hermes).** Mitigation: `macparakeet-cli` bumps to 2.0.0, CHANGELOG calls out the cutover, and `integrations/README.md` documents the v2 schema / pin commands. Grep `integrations/openclaw/` and `integrations/hermes/` for any baked-in `--kind` usage before merging.
3. **Custom-prompts >5 pinned post-migration.** Mitigation: documented above. The strip renders the first 5 by sortOrder; user can rebalance via swap picker. No data loss.
4. **Reserved UUID `1C5A1B4A-...` (ADR-020 burned).** Not reused — neither in seeds nor in the migration. Existing built-in UUIDs are preserved verbatim.
5. **Telemetry allowlist drift.** Mitigation: this PR introduces no new telemetry events. If we add pin/unpin events later, the website worker `ALLOWED_EVENTS` needs the same change (per `feedback_telemetry_allowlist.md`).

## Out of scope (explicit)

- No `shortLabel` field for compact-strip rendering. Truncate + tooltip in v1; add later if needed.
- No separate `pinnedSortOrder`. Pinned ordering rides the same `sortOrder` as the editor list.
- No telemetry on pin/unpin actions in this PR.
- No new built-in pinned prompts beyond the 5 already shipped (Tell me more / Why? / Give an example / Counter-argument? / TL;DR).
- No surface flags on prompts ("show in strip" / "show in empty state" toggles). Pin status is the only knob.

## Commit plan

Approximate; may collapse if natural break points shift:

1. **Plan + ADR draft** — this file + ADR-018 amendment paragraph.
2. **Data layer** — model, migration, repository, bundle schema, repository + bundle tests. (Cross-cutting; intermediate states don't compile, so this lands as one commit.)
3. **VM + views** — `QuickPromptsViewModel`, `AskPromptsSheet` rebuild, `LiveAskPaneView` strip update, VM tests.
4. **CLI + CHANGELOG** — `QuickPromptsCommand` updates, CLI tests, CHANGELOG 2.0.0 entry.
5. **Spec sweep** — finalize ADR-018 amendment, update `spec/02-features.md` if needed, update `spec/kernel/requirements.yaml` if `quick_prompts.*` requirements reference `kind`.

Each commit ends with `swift test` green for the layer it touches; the final commit ends with a full-suite green run.
