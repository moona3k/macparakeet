# 10 - AI Coding Method

> Status: **ACTIVE** - Authoritative, current

## Purpose

This document defines how MacParakeet uses specs to drive implementation with coding agents.

Goal: reduce ambiguity, prevent drift, and make generated code maintainable over time.

## Philosophy

1. ADRs record locked decisions; do not second-guess them without a new ADR.
2. Narrative specs explain product behavior, architecture, and rationale.
3. Plans capture active implementation work and should be reconciled back into specs before merge.
4. The kernel is a lightweight, optional feature/status index, not a parallel contract system or a coverage map.
5. Determinism beats cleverness for core product flows.

## Context Zone (Probability Control)

Coding agents sample actions from context. In practice: weak context spreads probability mass across many plausible edits; strong context concentrates probability mass on valid edits.

The "context zone" is the bounded set of behavior allowed by current ADRs, specs, active plans, and tests.

For every behavior change, define zone boundaries up front:

1. Governing ADRs and spec sections.
2. Target requirement IDs in `spec/kernel/requirements.yaml` when the change maps to an existing notable feature (adding new IDs is optional).
3. "Must not change" invariants for public interfaces, persistence formats, privacy boundaries, and stateful/concurrent flows.
4. Focused tests that verify in-zone behavior and reject out-of-zone drift.

Any out-of-zone behavior change must be explicitly called out and reflected in the highest-precedence artifact it affects.

## External Evidence (Rationale)

The context-zone model is consistent with current research and vendor guidance:

1. Long-context reliability degrades with poor information placement ("lost in the middle").
   - https://arxiv.org/abs/2307.03172
2. Prompt structure and query placement materially affect long-context performance.
   - https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/long-context-tips
3. Simpler, structured SWE workflows can outperform heavier autonomous setups.
   - https://arxiv.org/abs/2407.01489
4. Tool-grounded reasoning loops improve error recovery and reduce hallucination-style failures.
   - https://arxiv.org/abs/2210.03629
5. SWE benchmark results can be inflated by memorization/contamination; eval hygiene matters.
   - https://openai.com/index/introducing-swe-bench-verified/
   - https://arxiv.org/abs/2506.12286

Inference: strong boundary artifacts improve the probability that agent actions remain in-zone. Use heavier artifacts only where they materially reduce ambiguity.

## Decision

Adopt a pragmatic spec model:

1. **Decision layer:** accepted ADRs in `spec/adr/` for locked architectural and product decisions.
2. **Narrative layer:** `spec/00-*` docs for product behavior, architecture, data model, UI, testing, and release status.
3. **Plan layer:** `plans/active/` for in-flight implementation details; completed plans are historical records.
4. **Kernel support layer:** `spec/kernel/requirements.yaml` as an optional, compact feature/status index. (The former manual feature -> source -> test map, `traceability.md`, was retired: it was a write-only hand-index with no machine consumer, and tests plus `git` are the authoritative coverage and history record.)

Optional contracts and state machines may be added for high-risk seams, but they are not required repo-wide.

## Source-of-Truth Order

When artifacts conflict, precedence is:

1. Accepted ADRs in `spec/adr/`
2. Narrative specs in `spec/00-*`
3. Active implementation plans in `plans/active/`
4. Kernel feature/status index (`spec/kernel/requirements.yaml`)
5. Existing code/comments

If conflict is found, update the lower-precedence artifact in the same change. If the higher-precedence artifact is wrong, update it deliberately and explain why.

## Kernel Artifacts

Maintain the artifacts that currently provide value:

- `spec/kernel/requirements.yaml` (optional feature/status index)

### Requirement Index

`requirements.yaml` is a compact feature/status index. Each top-level key is the stable requirement ID. Each entry should include:

- `description`
- `version` or release/train marker
- `status`

Allowed `status` values:

- `status`: `proposed | active | implemented | deprecated | historical`

Requirement ID format:

- `REQ-<area>-<nnn>` where `<area>` is stable (`DICT`, `TRANS`, `MEET`, `CLI`, etc.) and `<nnn>` is zero-padded when practical.

Example:

```yaml
REQ-YT-001:
  description: YouTube URL transcription via yt-dlp
  version: v0.3
  status: implemented
```

Optional fields such as `source`, `priority`, and `acceptance` are allowed when they clarify active or high-risk work, but they are not required for every historical entry.

### Finding Source and Tests

There is no manual requirement -> source -> test map. To find what implements or tests a feature, use `git grep`, test names, and `git log`/`git blame` — all always-accurate and free. An always-green suite is stronger evidence of coverage than a hand-maintained table that merely claims it.

### Optional Contracts

Create `spec/kernel/contracts/*.yaml` only when a stable interface needs machine-checkable clarity, such as:

- CLI JSON envelopes and exit/error contracts
- Import/export bundle schemas
- Database migration compatibility contracts
- Telemetry/privacy event schemas
- External-process invocation boundaries

Each contract should include:

- `name`
- `input`
- `output`
- `errors` (stable error codes)
- `invariants`

Example:

```yaml
name: transcribe_url
input:
  url: string
  onProgress: optional_callback_string
output:
  transcription:
    id: uuid
    status: completed
errors:
  - invalid_url
  - video_not_found
  - download_failed
  - timed_out
invariants:
  - sourceURL must equal request url for URL-based transcriptions
```

### Optional State Machines

Create `spec/kernel/state_machines/*.yaml` only for flows where explicit transitions reduce real risk, such as:

- Dictation lifecycle
- Meeting recording lifecycle and crash recovery
- STT scheduler/lease behavior
- Calendar auto-start
- Destructive import/replace flows

Each state machine should include:

- `name`
- `initial`
- `states`
- `events`
- `transitions`
- `terminal_states`

Example:

```yaml
name: dictation_flow
initial: idle
states: [idle, recording, processing, success, error]
events: [start_recording, stop_recording, stt_ok, stt_fail]
transitions:
  - { from: idle, event: start_recording, to: recording }
  - { from: recording, event: stop_recording, to: processing }
  - { from: processing, event: stt_ok, to: success }
  - { from: processing, event: stt_fail, to: error }
terminal_states: [success, error]
```

## Implementation Workflow

For any behavior change:

1. Read the governing ADRs, spec sections, and active plans.
2. Identify existing requirement IDs to anchor the change; adding a new ID is optional and reserved for naming a genuinely new user-visible capability, persistence format, or CLI surface.
3. Define must-not-change invariants before editing.
4. Add/update tests for changed behavior.
5. Add/update optional contracts or state machines only if the change touches a high-risk seam listed above.
6. Run tests per test-scope policy.

Small bug fixes, copy changes, internal refactors, and straightforward UI polish may skip new requirement IDs when the existing specs and tests already bound the work.

## Test-Scope Policy

During development:

1. Run focused tests for touched requirements (fast loop).
2. Run broader local suite when touching shared/core flows.

Before merge:

1. Run `swift test` locally or in CI for full-suite verification.

## Definition of Done

### PR-Ready DoD

A change is PR-ready only when all are true:

1. Governing ADR/spec/plan context was checked.
2. Requirement entries are updated when the change adds or changes a notable feature/public behavior (optional — see Kernel Artifacts).
3. Optional contracts/state machines are updated when they exist for the touched seam.
4. Focused tests pass for affected behavior.
5. Precedence conflicts are reconciled.

### Merge Gate

A change is merge-complete only when all are true:

1. PR-Ready DoD is satisfied.
2. Full test suite (`swift test`) passes in CI.
3. Relevant docs and plan status markers are updated.

## Coding Rules for Agents

1. Do not treat kernel files as higher precedence than ADRs or narrative specs.
2. Do not introduce major user-visible behavior without updating the relevant spec/plan and, when appropriate, `requirements.yaml`.
3. Prefer explicit error codes over free-form strings for public CLI, import/export, and core flow errors.
4. Preserve local-first/privacy ADR constraints unless an ADR changes.
5. Requirement IDs do not need to appear in Swift source or test names unless that improves clarity.

### Agent Discretion (Bounded)

Agents are expected to use judgment, but within explicit constraints:

1. For behavior changes, documentation updates should be proportional to risk and user visibility.
2. For non-behavioral changes (formatting, comments, renames, internal refactors with unchanged behavior), agents may use a lighter process.
3. If a materially better third approach is identified, propose it and update this method before adopting it broadly.
4. Prefer the simplest process that preserves correctness, test coverage, and ADR constraints.

## Anti-Patterns

Avoid:

1. Treating optional contracts/state machines as if they already exist.
2. Claiming CI enforces a process gate (coverage, requirement mapping) unless a CI check actually does.
3. Requirement IDs that change over time.
4. Silent behavior changes not reflected in the relevant ADR/spec/plan/kernel docs.
5. Retrofitting heavy YAML artifacts for low-risk historical features just to satisfy process.

## Rollout Plan

### Current Operating Mode

1. Keep `requirements.yaml` accurate as an optional, compact feature/status index.
2. Add optional contracts/state machines only when they reduce ambiguity at high-risk seams.

Success metric:

- A new agent can quickly find the source and test surface for a shipped feature via `git grep`, test names, and history.
- Kernel docs do not contradict ADRs, narrative specs, or current code.

### Targeted Investment

When repeatedly editing a high-risk flow, add the smallest durable artifact that would have prevented the last ambiguity:

- A contract for stable I/O/error schemas.
- A state machine for tricky lifecycle/concurrency behavior.

Non-goals:

- 100% active-feature kernel coverage.
- CI failure on unmapped requirements without first building and maintaining that check.
- Repo-wide retroactive contracts for simple or historical behavior.

## Relationship to Existing Specs

Narrative docs remain the human-facing product and architecture guide. ADRs remain the locked decision record. The kernel supports implementation discovery and review; it is not the primary implementation authority.

Use each artifact for what it is good at:

- ADRs: decisions and constraints.
- Narrative specs: product behavior and architecture.
- Plans: active implementation detail.
- Kernel requirements: compact, optional status/index.
- Optional contracts/state machines: targeted clarity for high-risk seams.
