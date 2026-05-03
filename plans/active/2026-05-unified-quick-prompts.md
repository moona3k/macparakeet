# Unified Quick Prompts - pin-to-strip mechanic

> Status: **ACTIVE** - 2026-05-03
> Ship target: **app v0.7.x** (post-v0.7.0)
> Branch: `feat/unified-quick-prompts`
> Related: ADR-018 (live meeting Ask), ADR-013 (prompt library pattern), `plans/active/cli-as-canonical-parakeet-surface.md`

## Current Shape

Ask quick prompts are one unified library. `isPinned: Bool` controls whether a
visible prompt appears in the after-response strip; every visible prompt also
appears in the empty Ask state and sparkle popover, grouped by `groupLabel`.

Pinning is unbounded. The strip is a horizontal `ScrollView` with edge-fade
overflow, so there is no hard cap, swap picker, or cap-exceeded error.

Quick prompts are still prerelease. There is no public `kind` schema to
support, and no compatibility migration or bundle fallback is retained.

## Data Model

`quick_prompts` is created in its final prerelease shape:

```sql
CREATE TABLE quick_prompts (
    id TEXT PRIMARY KEY,
    label TEXT NOT NULL,
    prompt TEXT NOT NULL,
    groupLabel TEXT,
    sortOrder INTEGER NOT NULL DEFAULT 0,
    isVisible INTEGER NOT NULL DEFAULT 1,
    isPinned INTEGER NOT NULL DEFAULT 0,
    isBuiltIn INTEGER NOT NULL DEFAULT 0,
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL
);

CREATE INDEX idx_quick_prompts_pinned_sort
ON quick_prompts(isPinned, sortOrder);
```

Repository writes normalize invalid hidden+pinned rows to hidden+unpinned.
Hiding a pinned row auto-unpins it; pinning a hidden row auto-shows it.

## CLI And Bundle

`macparakeet-cli quick-prompts` supports `list`, `show`, `add`, `set`,
`delete`, `pin`, `unpin`, `restore-defaults`, `export`, and `import`.
`--pinned <true|false>` filters `list` and `export`; `add --pinned` creates a
pinned custom row.

The import/export bundle is `macparakeet.quick_prompts` version 1 and emits
`isPinned: Bool` per prompt. `kind` is not part of the schema.

## Acceptance Criteria

| # | Criterion | How verified |
|---|---|---|
| AC1 | Fresh migrations create the final `quick_prompts` schema with `isPinned` and no `kind` column | Database/repository tests |
| AC2 | After-response strip renders all visible pinned prompts by `sortOrder` | VM tests + manual smoke |
| AC3 | Empty Ask state and sparkle popover render all visible prompts grouped by `groupLabel` | VM tests |
| AC4 | Pinning is unbounded and never returns cap-exceeded state | Repository + CLI tests |
| AC5 | Hidden rows cannot remain pinned through save/import/CLI hide/pin flows | Repository + CLI tests |
| AC6 | Bundle v1 with `isPinned` round-trips and rejects malformed required fields | Bundle tests |
| AC7 | `--kind` is rejected by quick-prompts parsers | CLI test |

## Test Plan

- `Tests/MacParakeetTests/Database/QuickPromptRepositoryTests.swift`
- `Tests/MacParakeetTests/ViewModels/QuickPromptsViewModelTests.swift`
- `Tests/MacParakeetTests/QuickPromptBundleTests.swift`
- `Tests/CLITests/QuickPromptsCommandTests.swift`

Final verification: focused quick-prompt tests first, then full `swift test`
before merge.
