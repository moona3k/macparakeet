# `macparakeet-cli` — maintainer guide

This directory is the `macparakeet-cli` target: a Swift [ArgumentParser]
CLI that shares all real logic with `MacParakeetCore`. It is a **public
automation contract**, not a GUI mirror — humans, shell scripts, CI, and AI
agents depend on its commands, flags, JSON shapes, and exit codes.

This file is for people **changing** the CLI. If you instead want to *call* it
from an agent, read [`integrations/README.md`](../../integrations/README.md).

## Where things live

```
Sources/CLI/
├── MacParakeetCLI.swift        # @main entry: root command, subcommand list,
│                               #   cliVersion, exit-code normalization
├── CHANGELOG.md                # the public ledger + compatibility policy
└── Commands/
    ├── CLIHelpers.swift        # shared lookups, JSON envelopes, errorType
    │                           #   taxonomy, emitJSONOrRethrow wrappers
    ├── CLITelemetry.swift      # opt-out/CI/DO_NOT_TRACK-gated instrumentation
    ├── SpecCommand.swift       # `spec --json`: the machine-readable catalog
    └── <Feature>Command.swift  # one file per top-level command / family
```

Each command is a `ParsableCommand` / `AsyncParsableCommand`. Command families
(`vocab`, `prompts`, `transforms`, `meetings`, `llm`) nest subcommands through
`CommandConfiguration.subcommands`.

## The contract, in three documents

- **[`CHANGELOG.md`](./CHANGELOG.md)** — what changed and the semver policy. The
  surface is versioned: removing a command/flag/JSON field or changing an
  exit-code meaning is **MAJOR**; additive changes are **MINOR**.
- **[`spec/contracts/cli-json-v1.md`](../../spec/contracts/cli-json-v1.md)** —
  the canonical stdout/stderr, envelope, and exit-code contract.
- **`spec --json`** (from `SpecCommand.swift`) — the same contract as live,
  machine-readable data, plus a hand-maintained catalog of the agent-facing
  command surface.

## Conventions (don't reinvent these)

- **stdout is for machines, stderr is for humans.** Payloads and `--json`
  output go to stdout; progress/status lines go to stderr via `printErr(...)`
  so piping `--json` through `jq` stays clean.
- **Exit codes:** `0` success, `1` runtime failure (work attempted, failed),
  `2` validation/misuse (bad invocation before work started), `130` SIGINT.
  Normalization lives in `MacParakeetCLI.normalizedExitCode(for:)`; validation
  failures map to `2`.
- **JSON output:** use `printJSON(_:)` / `printEnvelope(...)` (both use the
  shared `cliJSONEncoder`: ISO-8601 dates, sorted keys, pretty-printed).
  Field names are camelCase. (`transforms` JSON predates this and emits
  snake_case keys — see the note in `cli-json-v1.md`; do not copy it.)
- **`--json` failures:** wrap a `--json`-aware body in `emitJSONOrRethrow(json:)`
  so post-parse failures emit the `{ ok: false, error, errorType, fix, meta }`
  envelope on stdout and exit non-zero. New error classes get a new stable
  `errorType` string in `CLIErrorType` (and a CHANGELOG note) — never silently
  reuse one.
- **Record lookup:** resolve ids through the shared helpers in `CLIHelpers.swift`
  (`findTranscription`, `findPrompt`, …) or a family's `resolve*`. They accept
  an exact UUID and a ≥4-char UUID prefix; the helpers for named records
  (`findTranscription`, `findMeeting`, `findPrompt`) also accept a
  case-insensitive name. All produce consistent ambiguity/not-found errors.
  Don't hand-roll `hasPrefix` matching.
- **Database access:** open via `DatabaseManager(path: resolvedDatabasePath(database))`
  after `try AppPaths.ensureDirectories()`, then a GRDB repository. Prefer
  repository fetch/update over raw SQL (GRDB UUID storage may not equal
  `uuidString`).
- **Concurrency:** new I/O is async/await; mark the body `async` and `await` it
  rather than spawning a detached `Task` the caller depends on.

## Adding or changing a command

1. **Implement** the command/flag in its `*Command.swift` (follow the nearest
   sibling; reuse the shared helpers and envelope wrappers above).
2. **Catalog** it in `SpecCommand.swift` if it is agent-facing. The catalog
   duplicates the ArgumentParser tree, so it must move in lockstep —
   `SpecCommandTests` fails if a documented path no longer resolves, but it
   cannot detect a *new* command you forgot to add.
3. **Document** the change in [`CHANGELOG.md`](./CHANGELOG.md) under
   `[Unreleased]` with the right Added/Changed/Fixed bucket and semver impact.
4. **Version** at release time: promote `[Unreleased]` to a dated
   `## [x.y.z]` section and bump `CLI.cliVersion` in `MacParakeetCLI.swift` to
   match. `CLIVersionTests` pins the binary version to the latest *released*
   header.
5. **Test** in `Tests/CLITests/`. Lock anything an external caller branches on:
   JSON keys, exit codes, `errorType`, the presence of a command in `spec`.
6. **Contract** — if you touched stdout/stderr shape, envelopes, or exit-code
   meaning, update [`spec/contracts/cli-json-v1.md`](../../spec/contracts/cli-json-v1.md)
   in the same change.

## Testing

```bash
swift build --product macparakeet-cli
swift test --filter CLITests
swift run macparakeet-cli --help
swift run macparakeet-cli spec --json | jq .
```

Manual/QA matrix and provider notes: [`docs/cli-testing.md`](../../docs/cli-testing.md).

[ArgumentParser]: https://github.com/apple/swift-argument-parser
