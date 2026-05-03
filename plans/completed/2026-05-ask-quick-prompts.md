# Ask Tab Quick Prompts — Implementation Plan

> Status: **COMPLETED** — 2026-05-02
> Ship target: **app v0.7.0**
> Issue: TBD
> Related: ADR-018 (Ask tab), ADR-013 (Prompt Library — pattern reference, not extension), `plans/active/cli-as-canonical-parakeet-surface.md`
> Touches: `Sources/MacParakeet/Views/MeetingRecording/LiveAskPaneView.swift:311,438`, `Sources/CLI/Commands/`
> Shipped on `feat/ask-quick-prompts` in three commits (data layer → CLI → GUI). 51 new tests; full suite 2160 / 2160 passing.

## Overview

Replace the hardcoded starter and follow-up pill enums in the live meeting Ask tab with a user-customizable, GRDB-backed system. Users can edit, reorder, hide, and create their own starter prompts (CATCH UP / CAPTURE / CHALLENGE) and follow-up prompts (Tell me more / Why? / TL;DR) from a dedicated **Ask Prompts** sheet, reachable via a footer link in the existing sparkle ✨ menu popover.

**Three consumers of one core**: GUI sheet (the polished UI), CLI subcommand (`macparakeet-cli quick-prompts ...`), and JSON export/import (versioned wire format). Building all three in v1 keeps the data layer cleanly decoupled from any single UI and aligns with the CLI-canonical-surface direction. Power users can version-control their pills in git, agents (OpenClaw / Hermes) can read/write them programmatically, and the headless round-trip test path catches regressions the GUI alone wouldn't.

## Why Not Reuse Prompt Library

`Prompt` (in `Sources/MacParakeetCore/Models/Prompt.swift`) models heavyweight, document-producing transforms with `Auto-Run`, `summaries` table caching, and source-agnostic application. Ask pills are lightweight conversational shortcuts with a *display label* and a *richer prompt body* that fires as a chat message. Bolting a scope flag onto `Prompt` would conflate two different mental models. Instead: a parallel, smaller table that follows the same shape so the patterns are familiar and the design language stays consistent.

## Design Decisions (Settled)

1. **Independent table.** New `quick_prompts` table; no changes to `prompts`.
2. **Two kinds in one table** — `starter` and `followUp`. Discriminated by a `kind` column. Single sheet shows both as stacked sections.
3. **Built-ins are editable, not read-only** — divergence from Prompt Library. Users can rename, retune, reorder, and hide built-ins. Cannot delete them. Each built-in row offers per-row "Restore default."
4. **Reset semantics** — per-section "Reset built-ins" restores label/prompt/group/order for built-ins only while preserving visibility; never deletes user-created customs.
5. **No template variables** — pills are plain strings. `TranscriptChatViewModel` already injects transcript + notes via system prompt; adding `{{transcript}}` here would duplicate context and reintroduce the source-scoping hazard from ADR-020.
6. **Manage entry point: sparkle popover footer only.** No Settings entry, no transcript-detail entry. Pills are met in the Ask tab; managed from the Ask tab.
7. **Group label optional, on starter only.** Follow-ups are flat; starters keep optional `groupLabel` so users can preserve CATCH UP / CAPTURE / CHALLENGE clustering.
8. **Reconciler is insert-only.** On launch, INSERT IF NOT EXISTS by canonical UUID. Never UPDATE existing rows (would clobber edits). Hidden via `isVisible=false`.
9. **Fresh UUID block.** Do not reuse the burned `1C5A1B4A-7E2C-4D38-B3EF-5C0F8A7E3E1A` slot from ADR-020.
10. **No engine/AI dependency change.** Pill click still routes through `TranscriptChatViewModel.sendMessage(richPrompt:)` exactly as today.

## New Files

| File | Target | Purpose |
|------|--------|---------|
| `Sources/MacParakeetCore/Models/QuickPrompt.swift` | Core | `QuickPrompt` model, `Kind` enum, built-in seed values |
| `Sources/MacParakeetCore/Models/QuickPromptBundle.swift` | Core | Versioned wire format (`version: 1`), encode/decode + coercion rules |
| `Sources/MacParakeetCore/Database/QuickPromptRepository.swift` | Core | Protocol + GRDB-backed CRUD + reconciler + import-merge logic |
| `Sources/MacParakeetViewModels/QuickPromptsViewModel.swift` | ViewModels | Sheet state, edit/create/reorder/restore-defaults |
| `Sources/MacParakeet/Views/MeetingRecording/AskPromptsSheet.swift` | GUI | The "Ask Prompts" management sheet |
| `Sources/CLI/Commands/QuickPromptsCommand.swift` | CLI | `quick-prompts list/show/add/set/delete/restore-defaults/export/import` |
| `Tests/MacParakeetTests/QuickPromptRepositoryTests.swift` | Tests | CRUD + seeding + reconciler idempotency + import-merge |
| `Tests/MacParakeetTests/QuickPromptBundleTests.swift` | Tests | Round-trip encode/decode, schema version, builtIn coercion |
| `Tests/MacParakeetTests/QuickPromptsViewModelTests.swift` | Tests | Edit, reorder, restore-default, visibility |
| `Tests/CLITests/QuickPromptsCommandTests.swift` | Tests | CLI parsing, JSON envelope, exit codes |

## Modified Files

| File | Change |
|------|--------|
| `Sources/MacParakeetCore/Database/DatabaseManager.swift` | New migration `v0.10-quick-prompts` — create table, seed built-ins from existing enums |
| `Sources/MacParakeet/Views/MeetingRecording/LiveAskPaneView.swift` | Read pills from `viewModel.quickPrompts.starters` / `.followUps` instead of `LiveAskStarterPrompts.groups` / `LiveAskFollowUpPrompts.all`; add "Edit pills…" footer link to `PromptMenuButton` popover; keep enums as built-in seed source only (or move to `QuickPrompt.swift`) |
| `Sources/MacParakeetViewModels/TranscriptChatViewModel.swift` | Hold a `QuickPromptsViewModel` (or just expose `starters` / `followUps` reactive arrays); refresh on sheet dismiss |
| `Sources/MacParakeet/App/AppEnvironment.swift` | Construct `QuickPromptRepository`, run reconciler on app start, inject into ViewModels |
| `Sources/CLI/MacParakeetCLI.swift` | Register `QuickPromptsCommand` in subcommand list |
| `Sources/CLI/CHANGELOG.md` | Add entry to `[Unreleased]` for new `quick-prompts` subcommand surface (minor bump) |

## Data Model

```swift
public struct QuickPrompt: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var kind: Kind                    // .starter | .followUp
    public var label: String                 // Pill display text (short)
    public var prompt: String                // Full prompt body sent to LLM
    public var groupLabel: String?           // Starters only; nil for followUps
    public var sortOrder: Int                // Within (kind, groupLabel) tuple
    public var isVisible: Bool               // Toggle in UI
    public var isBuiltIn: Bool               // Affects "Restore default" + delete affordances
    public var createdAt: Date
    public var updatedAt: Date

    public enum Kind: String, Codable, Sendable {
        case starter
        case followUp = "follow_up"
    }
}
```

Built-in seed values live as a `static let builtIns: [QuickPrompt]` in `QuickPrompt.swift`, copy-paste-mapped 1:1 from the current `LiveAskStarterPrompts.groups` and `LiveAskFollowUpPrompts.all`. Each gets a fresh hardcoded UUID. For "Restore default" lookup we keep an in-memory dictionary `[UUID: QuickPrompt]` keyed off the seed list.

## JSON Wire Format (CLI export/import)

```json
{
  "schema": "macparakeet.quick_prompts",
  "version": 1,
  "exportedAt": "2026-05-02T20:00:00Z",
  "appVersion": "0.7.0",
  "prompts": [
    {
      "id": "B7E1D4F0-XXXX-XXXX-XXXX-XXXXXXXXXXXX",
      "kind": "starter",
      "label": "Summarize so far",
      "prompt": "Give a concise summary...",
      "groupLabel": "CATCH UP",
      "sortOrder": 0,
      "isVisible": true,
      "isBuiltIn": true
    }
  ]
}
```

**Schema rules (locked under CLI semver from v1):**
- Single flat `prompts` array; `kind` discriminates (`"starter"` | `"follow_up"`). Future kinds added in minor bumps.
- Top-level `version: 1`. Bump only on breaking changes; new optional fields don't bump.
- `id` is required and round-trippable. Imports match by id (UPSERT) — enables "edit built-in via export-edit-import."
- `isBuiltIn` advisory: import trusts it only when id matches a known seed UUID; otherwise coerced to `false` (prevents shipping fake "built-ins").
- Unknown fields in input are ignored (forward-compat). Missing optional fields default per model.
- Top-level `appVersion` is informational only — never gates import.

## CLI Surface (locked under `Sources/CLI/CHANGELOG.md` semver)

```
macparakeet-cli quick-prompts list [--kind starter|follow-up] [--visible-only] [--json]
macparakeet-cli quick-prompts show <id> [--json]
macparakeet-cli quick-prompts add --kind <k> --label <s> --prompt <s> [--group <s>] [--hidden] [--json]
macparakeet-cli quick-prompts set <id> [--label <s>] [--prompt <s>] [--group <s>] [--visible|--hidden] [--sort-order <n>] [--json]
macparakeet-cli quick-prompts delete <id> [--json]                # rejects built-ins (errorType: "validation")
macparakeet-cli quick-prompts restore-defaults [--kind <k>] [--id <uuid>] [--json]
macparakeet-cli quick-prompts export [--out <path>] [--kind <k>] [--include-builtins] [--json]
macparakeet-cli quick-prompts import <path> [--mode merge|replace] [--dry-run] [--json]
```

- `import --mode merge` (default): UPSERT by id; rows not in file preserved.
- `import --mode replace`: wipe customs in scope, re-seed built-ins, then apply file. Confirmation prompt unless `--json` (scripted).
- `import --dry-run`: emits `{added, updated, deleted, unchanged}` count summary; no DB writes.
- All mutation commands honor existing `--json` failure envelope (`{ok, error, errorType}`); add new `errorType: "import_schema"` for malformed import files (minor bump).

## Schema

```sql
CREATE TABLE quick_prompts (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,                  -- 'starter' | 'follow_up'
    label TEXT NOT NULL,
    prompt TEXT NOT NULL,
    groupLabel TEXT,                     -- NULL for follow-ups
    sortOrder INTEGER NOT NULL DEFAULT 0,
    isVisible INTEGER NOT NULL DEFAULT 1,
    isBuiltIn INTEGER NOT NULL DEFAULT 0,
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL
);
CREATE INDEX idx_quick_prompts_kind_sort ON quick_prompts(kind, sortOrder);
```

No unique index on label — users can have duplicate labels across customs (e.g. two "Why?" with different bodies for different framings).

## Implementation Steps

### Step 1 — Model + Seeds
- Create `QuickPrompt.swift` with struct, `Kind` enum, GRDB conformances (`FetchableRecord`, `PersistableRecord`, `databaseTableName = "quick_prompts"`, `Columns` enum).
- Define `static let builtIns: [QuickPrompt]` — port every entry from `LiveAskStarterPrompts.groups` and `LiveAskFollowUpPrompts.all`. Each gets a fixed UUID literal.
- Tests: round-trip Codable, built-in count assertions, no UUID collisions.

### Step 2 — Repository
- `QuickPromptRepositoryProtocol` with `fetchVisible(kind:)`, `fetchAll(kind:)`, `fetchAll()`, `fetch(id:)`, `save(_:)`, `delete(id:)`, `reorder(ids:within:)`, `toggleVisibility(id:)`, `seedIfNeeded()`, `restoreBuiltInDefaults(kind:)`, `restoreBuiltInDefault(id:)`, `applyImport(_:mode:)` returning `ImportSummary`.
- `seedIfNeeded()` is the launch-time reconciler: for each built-in seed UUID, INSERT IF NOT EXISTS. Never UPDATE.
- `restoreBuiltInDefaults(kind:)` UPDATEs every built-in row in the kind back to seed values (label/prompt/groupLabel/sortOrder/isVisible).
- `restoreBuiltInDefault(id:)` per-row variant.
- `applyImport(dto, mode:)` performs UPSERT-by-id (merge) or wipe-and-re-seed-then-apply (replace) inside a single GRDB transaction. Returns counts (`added`, `updated`, `deleted`, `unchanged`).
- `delete(id:)` rejects `isBuiltIn == true` and throws — UI prevents the call; CLI surfaces as `errorType: "validation"`.
- Tests: idempotent seeding, delete-built-in error, reorder ordering, restore-defaults preserves customs, merge import upserts, replace import wipes customs but re-seeds built-ins.

### Step 2.5 — Export DTO
- Create `QuickPromptBundle` with `schema`, `version`, `exportedAt`, `appVersion`, `prompts: [ExportedQuickPrompt]`.
- `encode(from: [QuickPrompt])` and `decode(from: Data) throws`.
- `decode` enforces `schema == "macparakeet.quick_prompts"` and `version == 1`; unknown fields ignored (forward-compat); missing required fields throw with clear path (e.g. `prompts[3].label`).
- `isBuiltIn` coerced to `false` on decode unless `id` matches a known seed UUID (defended against forged built-ins).
- Tests: round-trip, schema-version mismatch error, unknown-field tolerance, builtIn coercion.

### Step 3 — Migration
- New migration `v0.10-quick-prompts` in `DatabaseManager.swift` — create table + index + invoke seed insert via the same UUIDs the in-app reconciler uses (so first-launch path matches upgrade-launch path).
- Tests: migration creates table, seeded count matches `QuickPrompt.builtIns.count`.

### Step 4 — ViewModel
- `QuickPromptsViewModel` (`@MainActor @Observable`):
  - `starters: [QuickPrompt]`, `followUps: [QuickPrompt]` (visible-only convenience accessors + full lists for the sheet).
  - `editing: QuickPrompt?` for the inline editor.
  - `creatingKind: Kind?` for the "+ New" affordance.
  - `save()`, `delete()`, `move(_:to:within:)`, `restoreDefaults(kind:)`, `restoreSingleDefault(id:)`, `toggleVisibility(id:)`.
  - `refresh()` reloads from repo; called on sheet dismiss + after every mutation.
- Tests: each public action against an in-memory repository.

### Step 5 — Sheet UI (`AskPromptsSheet.swift`)
- Reuse `PromptLibraryView`'s visual language: dark surface, accent toggles, rounded inset cards, 14pt corner radius.
- Two stacked sections:
  - **Starters** — grouped by `groupLabel` (CATCH UP / CAPTURE / CHALLENGE), each row: drag handle, visibility toggle, label, prompt preview, expand/edit chevron. Built-ins show subtle "default" badge with "Restore" on hover. "+ New starter" footer pinned to section.
  - **Follow-ups** — flat list, same row anatomy, no group header. "+ New follow-up" footer.
- Per-section footer: small "Reset built-ins" link with confirm-on-click.
- Inline editor (sheet-within-sheet or expanded row): label field (short, 60-char cap), prompt body (multiline, 4000-char cap), group picker for starters (free-text combo: existing groups + "New group…").
- "Done" button dismisses; closing without save discards in-progress edits.

### Step 6 — Wire LiveAskPaneView
- `LiveAskPaneView` reads from injected `viewModel.starters` / `viewModel.followUps` (or `quickPromptsVM.starters` / `.followUps`) instead of the hardcoded enums.
- `StarterPromptList` continues to render groups as today; iterates over `Dictionary(grouping: starters, by: \.groupLabel)` with stable group order from first-occurrence.
- Follow-up row iterates over `followUps` directly.
- `PromptMenuButton` popover gets a footer row: small text button "Edit pills…" → presents `AskPromptsSheet`. Footer styled with hairline divider above, 11pt secondary text, accent on hover.
- Delete the static enums `LiveAskStarterPrompts` / `LiveAskFollowUpPrompts` from `LiveAskPaneView.swift` (they live in `QuickPrompt.builtIns` now).

### Step 7 — Environment Wiring
- `AppEnvironment` constructs `QuickPromptRepository` using shared `DatabaseQueue`, calls `seedIfNeeded()` once during start.
- Pass through to `TranscriptChatViewModel` (or its parent meeting-panel VM) so `LiveAskPaneView` can observe.
- Refresh trigger on `AskPromptsSheet` dismiss → `quickPromptsVM.refresh()` → triggers re-render of pill rows.

### Step 8 — CLI surface (`QuickPromptsCommand.swift`)
- Mirror `PromptsCommand` structure: outer `AsyncParsableCommand` with subcommands.
- Each subcommand reuses the same `QuickPromptRepository` instance via shared DB path.
- `list` / `show` / `add` / `set` / `delete` / `restore-defaults` are sync (`ParsableCommand`).
- `export` and `import` are async; honor `--json` envelope per CLI CHANGELOG.md.
- Confirmation prompt for `import --mode replace` unless `--json`.
- `import --dry-run` writes summary JSON, never opens write transaction.
- Register in `MacParakeetCLI.swift` subcommands list.
- Tests in `Tests/CLITests/QuickPromptsCommandTests.swift`: parse all subcommands, verify exit codes, verify `--json` envelope on success and failure paths.

### Step 9 — CLI CHANGELOG
- Add `[Unreleased]` entry under `### Added`:
  ```
  - `quick-prompts` subcommand surface: `list`, `show`, `add`, `set`,
    `delete`, `restore-defaults`, `export`, `import`. Manages live-meeting
    Ask tab pills (starter + follow-up). Stable JSON wire format
    (`schema: "macparakeet.quick_prompts"`, `version: 1`).
  - `errorType: "import_schema"` for malformed import files.
  ```
- Confirm version line in CHANGELOG bumps minor (additive).

### Step 10 — Tests + Polish
- Snapshot the seeded count + UUIDs (regression guard against accidental UUID changes).
- Run `swift test` — full suite must pass; expect ~6–10 new test cases.
- Manual checklist:
  - [ ] Empty Ask tab shows starter pills from DB, grouped correctly.
  - [ ] Mid-conversation: follow-up row + sparkle popover both read from DB.
  - [ ] Edit a built-in's label → sticks across app restart.
  - [ ] "Restore default" on edited built-in reverts label/prompt/group.
  - [ ] Delete a custom → gone after restart.
  - [ ] Hide a built-in → not in pill row, still in management sheet.
  - [ ] "Reset built-ins" preserves user-created customs.
  - [ ] Move up/down reorder persists across restart.
  - [ ] Create starter with brand-new group label → group renders in StarterPromptList.

## Acceptance Criteria

- All `LiveAskStarterPrompts` / `LiveAskFollowUpPrompts` references removed from `LiveAskPaneView.swift`; enums live (renamed) on `QuickPrompt` as built-in seeds.
- `quick_prompts` table seeded with the exact same labels/prompts as today's enums on first launch.
- "Edit pills…" footer link in sparkle popover opens `AskPromptsSheet`.
- Built-in edits, custom creations, reorders, visibility toggles, deletes (customs only), and per-section reset all persist via GRDB.
- 1700+ existing XCTest count holds; new tests bring totals up.
- No regression in pill-click behavior — `richPrompt` still routed through `TranscriptChatViewModel.sendMessage(richPrompt:)`.

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Reconciler accidentally clobbers user edits | INSERT IF NOT EXISTS only; never UPDATE on launch. Tested with idempotency assertion. |
| Schema drift across versions adding new built-ins | New built-ins added later get inserted on next-launch via reconciler with fresh UUIDs; existing user data untouched. |
| Group rename leaves orphan group | UI surfaces "ungroup" affordance; renaming a group in one row only renames that row's `groupLabel` (intentional — users can split groups). Stable display order via first-occurrence. |
| Sheet sprawl in already-busy meeting panel | Sheet is modal, reachable only from sparkle popover footer. No new top-level menu items. |
| Built-in UUID collision with reserved `1C5A1B4A-…` slot | All new UUIDs hand-rolled in a fresh block; documented in `QuickPrompt.swift` reserved-UUID comment. |

## Open Questions

1. Should the "Edit pills…" footer also appear on the empty-state `StarterPromptList` (not just the sparkle popover)? Currently sparkle isn't visible in the empty state. Likely **yes** — surface a small footer link or a tiny pencil icon next to the column.
2. Should `restoreBuiltInDefault(id:)` also un-hide the row, or preserve the visibility toggle? Lean toward **preserve visibility** — restoring text shouldn't override an explicit hide.
3. Should the CLI `export` default include built-ins? Lean toward **no** by default (cleaner customs-only export for sharing); `--include-builtins` opts in.

## Out of Scope

- Sharing prompts across users / cloud sync (export/import via file is the bridge).
- Variable substitution (`{{transcript}}` etc.) in pill bodies.
- Per-pill model override (each pill always uses the active LLM provider).
- Auto-Run for pills (no equivalent concept — pills are user-fired only).
- Integration with Prompt Library (separate systems by design).
- Schema version 2 — design only when a real breaking change shows up.
