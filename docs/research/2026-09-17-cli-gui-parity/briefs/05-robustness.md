# Brief 05 — CLI robustness and catalog correctness

One concern: find correctness/robustness issues in the public CLI contract: catalog drift, JSON/envelope gaps, exit codes, lookup helpers, tests.

## Settled

- Adding a command requires SpecCommand catalog + CHANGELOG + tests (`Sources/CLI/README.md`).
- `SpecCommandTests` fail if a documented path no longer resolves, but cannot detect a *new* command omitted from the catalog.
- JSON object keys are camelCase except frozen `transforms` snake_case.

## Investigate

1. Diff ArgumentParser command tree vs `SpecCommand` catalog (every path).
2. Commands that mutate without `--json` while siblings have it.
3. Meeting-only vs all-transcription surfaces that should be generic (`transcript`, `export`, corrections).
4. `--database` isolation warnings vs actual isolation (preferences/keychain still shared).
5. Known issue #883 (app + brew CLI install conflict) — is it still true in docs/code?
6. Test coverage holes in `Tests/CLITests/` relative to command families.
7. Hidden commands (`meeting-vad-sim`) and deprecated `flow` alias status vs CHANGELOG removal promise.

## Fences

- Read-only. Write only: `docs/research/2026-09-17-cli-gui-parity/05-robustness.md`
- Use `swift run macparakeet-cli spec --json` only if a build already exists; do not start a full `swift test`. Reading SpecCommand.swift is enough if build is heavy.

## Done

Ranked findings with file:line, user-visible impact, and whether they are merge-worthy now vs later.
