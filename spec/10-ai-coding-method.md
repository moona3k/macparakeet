# 10 - Agent Working Method

> Status: **ACTIVE** - Authoritative, current

## Purpose

This document explains how agents and humans should use MacParakeet's specs,
plans, tests, and review loops without turning process into the product.

The goal is simple: keep changes grounded, verifiable, and easy for the next
person or agent to continue.

Rationale and external references for this approach live in
[`../docs/research/coding-agent-instructions-2026-06.md`](../docs/research/coding-agent-instructions-2026-06.md).

## Principles

1. ADRs record accepted decisions. Do not second-guess them casually.
2. Narrative specs explain product behavior, architecture, and rationale.
3. Plans are working memory for substantial or long-running tasks, not a
   mandatory ceremony for every edit.
4. Tests, current code, and `git` history are the reliable source for
   implementation and coverage discovery.
5. Use the lightest process that still protects correctness, privacy, user
   data, and product quality.

## Source Of Truth

When artifacts conflict, use this order:

1. Accepted ADRs in `spec/adr/`
2. Narrative specs listed in `spec/README.md`
3. Active plans, when the task is executing that plan
4. Current code and tests

If a lower-precedence artifact is stale, update it when it matters to the
change. If a higher-precedence artifact is wrong, update it deliberately and
explain why in the PR/commit.

## Retired Kernel Workflow

The old manual requirements and traceability workflow is retired.
`spec/kernel/traceability.md` was removed, and the legacy requirements index now
lives at [`../docs/historical/requirements-legacy.yaml`](../docs/historical/requirements-legacy.yaml).

That file exists only so old plans, ADRs, audits, and commits that mention
`REQ-*` IDs remain understandable. Do not add new REQ IDs as part of normal
work. For current implementation discovery, use code search, tests, and git
history.

## Context Zone

For behavior changes, define the context zone before editing:

1. What behavior is in scope.
2. What must not change.
3. Which ADRs/specs/code paths govern the work.
4. Which tests or runtime checks will prove the change.

This does not need a long document. A few bullets in a plan, PR, or working
notes are enough when the scope is clear.

## Plans

Use plans when they help the work stay coherent:

- New features
- Multi-file refactors
- Architecture or data-model changes
- Long-running agent tasks
- Work likely to be resumed by another agent

Skip plans for typos, copy edits, simple bug fixes, small internal refactors,
and obvious one-file changes.

Plans should be useful to agents: state the goal, constraints, phases,
verification, and current status. Archive or mark them historical when they stop
representing active work.

## Documentation Updates

Update docs when the change affects:

- User-visible behavior
- Public CLI behavior or JSON/error contracts
- Persistence, migrations, import/export, or retained local artifacts
- Privacy, telemetry, network surfaces, or local-first guarantees
- Release framing, feature flags, onboarding, or support guidance
- ADR/spec decisions

Do not update docs just to satisfy a checklist. Stale mechanical docs are worse
than no docs.

## Testing

During development, run focused tests for the touched area. Before merge or
completion, run broader tests proportional to risk.

Default expectation for code changes:

```bash
swift test
```

Use focused filters for iteration:

```bash
swift test --filter TextProcessingPipelineTests
scripts/dev/check.sh [TestFilter]
```

Higher-risk areas need stronger proof: audio capture, meeting recovery,
database migrations, CLI contracts, telemetry/privacy, concurrency, and shared
runtime scheduling.

## Review

Review rigor should match the risk:

- Trivial changes can go straight in after a quick check.
- Small contained fixes need focused verification and, when useful, one
  fresh-eye review.
- Substantial changes should use the full PR loop in
  [`../docs/pr-review-workflow.md`](../docs/pr-review-workflow.md): branch from
  `origin/main`, run CI, get independent review, address valid findings, and
  stop when findings converge to trivial or duplicative.

Model review is input, not authority. Fix valid issues, decline wrong findings
with evidence, and avoid worse designs just to satisfy a reviewer.

## Agent Discretion

Agents are expected to choose the simplest path that preserves correctness and
quality. Good discretion looks like:

- Reading the local subsystem README before touching a load-bearing subsystem.
- Using the existing architecture instead of inventing a parallel one.
- Adding tests where failure would matter.
- Keeping plans and docs proportional to the work.
- Calling out out-of-scope behavior explicitly.
- Preserving user worktree changes you did not make.

## Anti-Patterns

Avoid:

1. Treating old `REQ-*` IDs as required workflow.
2. Creating plans that only restate obvious steps.
3. Updating release or feature status in multiple places instead of linking to
   the source.
4. Shipping behavior changes without updating the governing ADR/spec when they
   conflict.
5. Running elaborate review loops for trivial edits.
6. Obeying review comments without deciding whether they are correct.
7. Leaving dead code from abandoned approaches.

## Definition Of Done

A change is done when:

1. The implementation matches the governing ADR/spec or deliberately updates it.
2. The relevant tests or runtime checks pass.
3. User-visible/public-contract docs are updated when needed.
4. Plans are updated or archived when they were part of the work.
5. The final explanation names what changed and what was verified.
