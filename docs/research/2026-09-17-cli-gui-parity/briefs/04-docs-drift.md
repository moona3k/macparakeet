# Brief 04 — Spec / ADR / plan / integration doc drift vs live CLI

One concern: find documentation that is factually wrong about CLI/GUI parity or CLI version/capabilities on this HEAD (`fb186349` / origin/main).

## Settled

- Canonical CLI contract: `Sources/CLI/CHANGELOG.md`, `spec/contracts/cli-json-v1.md`, `macparakeet-cli spec --json` via `SpecCommand.swift`, `integrations/README.md`.
- CLI version constant: `CLI.cliVersion` in `Sources/CLI/MacParakeetCLI.swift`.
- Do not rewrite history; propose precise edits.

## Investigate

- `spec/README.md` release table CLI version vs `cliVersion`
- `plans/README.md` rows that still say meeting split/import/CLI work is TODO while code exists
- `integrations/README.md` vs actual commands
- ADR-022 / ADR-020 / ADR-031 CLI claims
- `docs/cli-testing.md` stale examples (`flow` vs `vocab`, missing split/import)
- Any REQ-CLI comments that claim missing features now shipped
- Website/integrations skill if in this repo

## Fences

- Read-only. Write only: `docs/research/2026-09-17-cli-gui-parity/04-docs-drift.md`
- List proposed file edits; do not apply them.

## Done

Table: file | stale claim | current truth with evidence | proposed edit. Separate "must-fix in same PR" from "optional cleanup".
