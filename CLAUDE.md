# CLAUDE.md

@AGENTS.md

> Claude Code overlay for MacParakeet. Read [`AGENTS.md`](./AGENTS.md) first;
> it is the canonical cross-agent startup guide. This file keeps the
> Claude-specific reminders and high-risk repo lessons that are worth loading
> every session.

## Operating Style

Use judgment. MacParakeet benefits from agents that can plan, verify, and push
back when a proposed path is too heavy or too loose.

- For substantial work, make a short plan, define the scope/invariants, then
  execute. For tiny edits, skip the ceremony and keep momentum.
- Prefer current code, tests, ADRs, and live command output over stale plans or
  old notes.
- If the checkout is dirty or unrelated, preserve it. Use a fresh worktree for
  branch/PR work rather than cleaning up changes you did not make.
- When a task touches user data, privacy, audio capture, persistence,
  telemetry, CLI contracts, or concurrency, slow down and verify with tests or
  runtime evidence.
- Keep product decisions grounded in the trust-first direction: reliable
  capture, recovery, durable local artifacts, polished daily workflows, and
  simple intuitive UX before broader feature sprawl.

## Current Context

MacParakeet is a local-first voice app for Apple Silicon Macs with dictation,
file/media URL transcription, meeting recording, and selected-text Transforms.
The app and CLI share `MacParakeetCore`; the CLI is also a public automation
surface for agents and scripts.

For current feature/release state, use:

- Release channels and feature flags: [`spec/README.md`](./spec/README.md#release-channels-and-feature-flags)
- Spec index and roadmap: [`spec/README.md`](./spec/README.md)
- Accepted decisions: [`spec/adr/`](./spec/adr/)
- Feature behavior: [`spec/02-features.md`](./spec/02-features.md)
- Architecture: [`spec/03-architecture.md`](./spec/03-architecture.md)
- CLI compatibility: [`Sources/CLI/CHANGELOG.md`](./Sources/CLI/CHANGELOG.md)

Do not restate volatile release flags in new docs unless the task is explicitly
about release notes or feature gating. Link to the source instead.

## Source Of Truth

When artifacts conflict:

1. Accepted ADRs in `spec/adr/`
2. Narrative specs listed in `spec/README.md`
3. Active plans, when the task is executing that plan
4. Current code and tests

If a higher-precedence doc is wrong, update it deliberately and explain why.
The old manual requirements/traceability workflow is retired; legacy REQ IDs
are archived at
[`docs/historical/requirements-legacy.yaml`](./docs/historical/requirements-legacy.yaml)
only to make old references understandable.

## Workflows

### Normal Code Work

1. Inspect `git status --short`.
2. Find the governing code, ADR/spec, and tests.
3. Name the scope and must-not-change invariants for behavior changes.
4. Edit narrowly, following existing patterns.
5. Run focused tests, then broader tests proportional to risk.
6. Update docs only when behavior, public contracts, release framing, privacy,
   persistence, or user workflows changed.

Plans are working memory for agents, not a process tax. Create/update a plan
for multi-step or long-running work when it will prevent drift; skip plans for
small fixes.

### PR Review

Use [`docs/pr-review-workflow.md`](./docs/pr-review-workflow.md). Scale the loop
to risk:

- Trivial: direct commit is fine.
- Small: focused tests and one fresh-eye pass are usually enough.
- Substantial: branch from `origin/main`, open a PR, run CI, use independent
  review, and converge on findings rather than obeying every model suggestion.

### Commit Messages

Use [`docs/commit-guidelines.md`](./docs/commit-guidelines.md). Rich commit
messages are for meaningful changes; concise messages are fine when they carry
the future-reader context.

## Hard-Won Pitfalls

- Base new worktrees on `origin/main`, not local `main`.
- Build/test from the worktree that owns the branch.
- Ignore `.build*`, `.claude/worktrees`, `dist`, and
  `journal/x-agent/node_modules` unless intentionally inspecting generated or
  archival output.
- Do not delete the user database, meeting session folders, lock files, or
  source audio outside explicit recovery/discard flows.
- Read subsystem READMEs before editing load-bearing Core areas:
  `Audio/`, `STT/`, `TextProcessing/`, `Database/`, `Licensing/`.
- GRDB UUID storage may not match `uuidString`; prefer repository/fetch-update
  patterns over raw SQL `WHERE id = ?` with string UUIDs.
- `PermissionService` is instantiated; it is not `.shared`.
- Avoid fire-and-forget `Task` when the caller needs the result. Make the
  function async and await it.
- Avoid blocking `@MainActor` with long-running work.
- `UTType(filenameExtension:)` can be nil.
- Tooltips/hover behavior on non-activating panels often needs AppKit-level
  tracking, not only SwiftUI `.help()` or `.onHover`.
- `DictationFlowCoordinatorLoadCaptionTests` has historically had a short
  timing race in CI. Rerun once before treating a single failure as a product
  regression; investigate if it is reproducible or frequent.
- CLI behavior is a public contract for external-facing commands. Update
  `Sources/CLI/CHANGELOG.md` for compatibility-relevant changes.

## Verification Defaults

```bash
swift build
swift test --filter TextProcessingPipelineTests
swift test
scripts/dev/check.sh [TestFilter]
scripts/dev/run_app.sh
swift run macparakeet-cli health
```

Use the smallest command that proves the change while iterating. Before calling
code work complete, run `swift test` unless the user explicitly narrows the
verification scope or the environment blocks it.
