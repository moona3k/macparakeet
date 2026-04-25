# Plan: CLI prompts subsystem + structured output

> Status: **ACTIVE**
> Branch: `feat/cli-prompts-and-json`
> Owner: agent (Claude)
> Related: `MEMORY.md` decision *"CLI stays as internal dev tool"*

## Why

The CLI was last meaningfully expanded around v0.4. Two GUI table groups added since
have **no CLI access at all**:

- `prompts` (added v0.5, ADR-013)
- `summaries` aka `PromptResult` (added v0.5, ADR-013)

That makes those features the *only* parts of the data model an agent or CI run cannot
touch headlessly. We hit the friction every time we want to verify a prompt-library
migration, seed test prompts, or smoke-test the multi-summary write path.

Separately, every CLI query command except `transcribe` and `calendar upcoming` emits
human-formatted text only, so anything an agent or script wants to consume requires
fragile output-parsing.

This plan addresses both. It is **scoped deliberately small** — we are not pursuing
parity for parity's sake. Each addition has a concrete dev/CI/agent use case.

## What's in scope

### 1. `prompts` subcommand (new)

```text
prompts list [--visible | --auto-run | --all] [--json]
prompts show <id-or-name> [--json]
prompts add --name "X" [--content "..." | --from-file path]
            [--auto-run]
            (if both --content and --from-file are omitted, body is read from stdin)
prompts set <id-or-name> [--visible|--hidden] [--auto-run|--no-auto-run]
prompts delete <id-or-name>
prompts restore-defaults
prompts run <id-or-name> --transcription <id> [--no-store] [--stream]
            [--extra "additional instructions"]
            (LLM provider options: --provider --api-key --model --base-url --command)
```

**Lookup**: `<id-or-name>` accepts UUID exact, UUID prefix, or case-insensitive name.
Mirrors the `findTranscription` / `findDictation` resolve-and-error pattern. Ambiguity
is surfaced.

**Set semantics**: respects the repo's invariants — hidden implies not auto-run; auto-run
implies visible. Implemented via fetch + mutate + `repo.save()` (GRDB upsert).

**Delete**: refuses built-ins (matches `PromptRepository.delete` returning `false`).
CLI surfaces a clear error.

**Run**: defaults to `--store true` because the whole point of this command is to
exercise the persistence path. `--no-store` opts out (handy for "preview only" runs).

### 2. `--json` sweep on query commands

Add `--json` to:

- `history dictations`
- `history transcriptions`
- `history search`
- `history search-transcriptions`
- `history favorites`
- `stats`
- `flow words list`
- `flow snippets list`
- `health`
- `models status`

Encoder convention: `JSONEncoder` with `.iso8601`, `[.prettyPrinted, .sortedKeys]`,
matching `CalendarCommand`. Top level is an array for list commands, an object for
single-record / status commands.

**NOT swept** (intentional): `transcribe` (already has `--format json`), `export`
(`--format` is the export-format selector, different concept), `flow process`
(returns processed text — JSON wrapping has no value), every side-effect command
(`delete-*`, `favorite`, `unfavorite`, `flow words add`, etc. — they print one
confirmation line; JSON would be noise).

### 3. `--source` filter on `flow words list`

```text
flow words list [--source manual|learned|all] [--json]
```

Default: `all`. Closes a real GUI/CLI gap — the source column exists and is meaningful
(manual = user-typed, learned = vocabulary anchor) but invisible to the CLI today.

## What's explicitly out of scope

- **`meetings` subcommand.** Real value, but parking it until we feel the friction
  (next time we debug a meeting-pipeline regression). Recovery is also nicer to design
  *after* ADR-019 lands.
- **`settings get/set`.** Punt until we have a clear use case beyond `defaults write`.
- **`llm config show` reading from Keychain.** Keychain ACLs depend on code-signing
  identity; the dev CLI binary signs differently than the bundled app, so this would
  need careful entitlement + signing work for marginal gain. Current
  `--provider --api-key` flow is fine.
- **Chat conversation persistence.** `llm chat` is a one-shot — no need for
  multi-conversation persistence in the CLI.
- **Diarization speaker rename.** GUI-only; no agent use case yet.
- **Hotkey config from CLI.** Format is complex, GUI is fine.

## Design decisions

| Decision | Choice | Why |
|---|---|---|
| Prompt set semantics | `--visible`/`--hidden` and `--auto-run`/`--no-auto-run` mutually-exclusive flag pairs | Idempotent; agents want "set to X," not "flip" |
| Prompt delete on built-in | Error with clear message | Matches repo behavior; `restore-defaults` handles re-show case |
| `prompts run` default | `--store true` (use `--no-store` to opt out) | The verb implies the action; opt-out preserves preview workflow |
| JSON encoder | iso8601 dates, pretty-printed, sorted keys | Matches `CalendarCommand`; single convention is easier to remember |
| Lookup helper location | `Sources/CLI/Commands/CLIHelpers.swift` | Already houses `findTranscription`/`findDictation` — same shape |
| Should `prompts run` accept extra instructions? | Yes, via `--extra "..."` | Mirrors GUI's regenerate-with-extra flow; stored on `PromptResult.extraInstructions` |

## Tests

- `Tests/CLITests/PromptsCommandTests.swift`
  - `findPrompt` resolution: by UUID, by prefix, by name (case-insensitive), not-found, ambiguous.
  - That's it for now — full integration of `prompts run` requires a live LLM and is exercised manually.
- One smoke test asserting `history dictations --json` emits parseable JSON for a seeded record.

Aim: ~6-8 new test cases. We have 1521+ tests; we are not trying to add a hundred more.

## Files touched

**New:**
- `Sources/CLI/Commands/PromptsCommand.swift`
- `Tests/CLITests/PromptsCommandTests.swift`

**Modified:**
- `Sources/CLI/MacParakeetCLI.swift` — register PromptsCommand
- `Sources/CLI/Commands/CLIHelpers.swift` — add `findPrompt`
- `Sources/CLI/Commands/HistoryCommand.swift` — `--json` x5
- `Sources/CLI/Commands/StatsCommand.swift` — `--json`
- `Sources/CLI/Commands/FlowWordsCommand.swift` — `--source`, `--json`
- `Sources/CLI/Commands/FlowSnippetsCommand.swift` — `--json`
- `Sources/CLI/Commands/HealthCommand.swift` — `--json`
- `Sources/CLI/Commands/ModelsCommand.swift` — `--json` (status only)
- `docs/cli-testing.md` — add prompts section, document `--json`, document `--source`

## Acceptance

- `swift build` passes.
- `swift test` shows green for new + existing CLI tests.
- `swift run macparakeet-cli prompts list` emits the 6 built-ins after a fresh DB.
- `swift run macparakeet-cli history dictations --json | jq .` parses cleanly.
- `swift run macparakeet-cli prompts add --name "Test" --content "Hi" && \
  swift run macparakeet-cli prompts list | grep Test` works end-to-end.

## Risks / things to watch

- **GRDB upsert via `save`**: `Prompt` has `id: UUID` as primary key and is
  `PersistableRecord`. Calling `save` on an existing prompt updates it in place —
  this is what we want for `set`. Verified by reading repo code.
- **Built-in deletion**: silently returns `false` from repo. CLI must check the
  return value and emit a clear error (don't print "Deleted" on a no-op).
- **Empty `summaries` after `prompts run --no-store`**: confirm we don't accidentally
  call `repo.save` when storage is opted out.
