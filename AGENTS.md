# AGENTS.md -- MacParakeet

> Canonical startup guide for coding agents working in this repo. Claude Code
> also reads [`CLAUDE.md`](./CLAUDE.md), which is a small Claude-specific
> overlay. Agents outside this repo that want to call `macparakeet-cli` should
> start with [`integrations/README.md`](./integrations/README.md).

## Project Shape

MacParakeet is a fast, private, local-first voice app for Apple Silicon Macs.
It ships three primary capture modes -- system-wide dictation, file/media URL
transcription, and meeting recording -- plus Transforms for selected-text
rewrites. Speech recognition runs locally by default through Parakeet via
FluidAudio CoreML/ANE, with optional Nemotron, WhisperKit, and Cohere Transcribe
engines.

The repo contains two products:

- `MacParakeet.app`: SwiftUI macOS app.
- `macparakeet-cli`: public automation surface in `Sources/CLI/`; compatibility
  notes live in `Sources/CLI/CHANGELOG.md`.

`main` is development. The notarized DMG is the user-facing stable channel.
For current release/flag state, read
[`spec/README.md`](./spec/README.md#release-channels-and-feature-flags) and the
relevant ADR/spec instead of copying release facts into new docs.

## Commands

```bash
swift build
swift test
swift test --filter TextProcessingPipelineTests
scripts/dev/check.sh [TestFilter]
scripts/dev/format.sh
scripts/dev/ci_local.sh
scripts/dev/run_app.sh
swift run macparakeet-cli --help
swift run macparakeet-cli health
```

Use focused tests while iterating; run `swift test` before declaring code-change
work complete unless the user explicitly scopes verification differently.

## Worktrees

This repo often has many parallel worktrees.

- Base new branches/worktrees on `origin/main`, not local `main`.
- Fetch first: `git fetch origin`.
- Build and test from the worktree that owns the branch. SwiftPM/Xcode state can
  otherwise point at the wrong checkout.
- Treat `.build*`, `.claude/worktrees`, `dist`, and
  `journal/x-agent/node_modules` as generated or archival unless the task
  specifically asks about them.

## Code Boundaries

- Swift package tools-version is 5.9; first-party code is kept Swift 6
  language-mode/concurrency clean.
- `MacParakeetCore` owns shared logic and has no SwiftUI view ownership. Small
  AppKit-backed adapter services are allowed when Foundation has no equivalent.
- `MacParakeetViewModels` contains `@Observable` view models that can be tested
  without the GUI.
- New I/O should use async/await. Avoid new completion-handler or Combine
  patterns.
- Database access uses GRDB repositories, roughly one repository per table.
- UI buttons use `.parakeetAction(...)`; do not tint whole hosting roots coral.

When editing a load-bearing Core subsystem, read its local README before code:
`Audio/`, `STT/`, `TextProcessing/`, `Database/`, and `Licensing/` currently
have subsystem rules.

## Product Rules

- Preserve the local-first posture. Audio/transcripts stay on-device for core
  dictation, transcription, and meeting recording. Cloud LLMs, media downloads,
  model/update flows, and telemetry are explicit product surfaces.
- Treat the user database and meeting artifacts as user data. Do not delete them
  outside explicit product recovery/discard flows.
- Keep the product focused. Prefer reliable capture, recovery, durable local
  artifacts, polished daily workflows, and simple UX over feature sprawl.
- ADRs in `spec/adr/` record accepted decisions. If reality has changed, update
  the relevant ADR/spec deliberately instead of silently coding around it.

## Working Method

- Start by finding the governing code, ADRs/specs, and tests for the task.
- For behavior changes, define the intended scope and must-not-change
  invariants before editing.
- Plans are useful working memory for substantial or long-running tasks, but
  they are optional. Create or update one when it will keep the work coherent.
- Add tests proportional to risk. Shared flows, persistence, CLI contracts,
  privacy/telemetry, and concurrency need stronger coverage than copy edits.
- Update docs when user-visible behavior, public CLI behavior, persistence,
  privacy, or release framing changes.
- Boundary contract changes must update the matching
  [`spec/contracts/`](./spec/contracts/) document and focused tests in the same
  PR.

The old manual requirements/traceability workflow is retired. The legacy
requirements index is archived at
[`docs/historical/requirements-legacy.yaml`](./docs/historical/requirements-legacy.yaml)
for old references only; do not add new REQ IDs as part of normal work.

## Review And Commit

Use [`docs/pr-review-workflow.md`](./docs/pr-review-workflow.md) for substantial
changes. Scale review to risk: trivial edits can go straight in; small contained
fixes need focused verification; substantial changes benefit from branch-first
PRs, CI, and independent review until findings converge.

Commit messages should help a future reader understand the change. The rich
format in [`docs/commit-guidelines.md`](./docs/commit-guidelines.md) is a tool
for significant work, not ceremony for every typo.

## Where To Look

- Spec index and roadmap: [`spec/README.md`](./spec/README.md)
- Architecture and product decisions: [`spec/adr/`](./spec/adr/)
- Feature behavior: [`spec/02-features.md`](./spec/02-features.md)
- System architecture: [`spec/03-architecture.md`](./spec/03-architecture.md)
- UI patterns: [`spec/04-ui-patterns.md`](./spec/04-ui-patterns.md)
- Testing strategy: [`spec/09-testing.md`](./spec/09-testing.md)
- Agent working method: [`spec/10-ai-coding-method.md`](./spec/10-ai-coding-method.md)
- Agent instruction research: [`docs/research/coding-agent-instructions-2026-06.md`](./docs/research/coding-agent-instructions-2026-06.md)
- Active/completed plans: [`plans/README.md`](./plans/README.md)
- Distribution/release steps: [`docs/distribution.md`](./docs/distribution.md)
- CLI automation contract: [`integrations/README.md`](./integrations/README.md)
