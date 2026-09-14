---
title: Make non-interactive final reviews workspace- and SHA-bound
date: 2026-09-13
category: workflow-issues
module: pull-request-review
problem_type: workflow_issue
component: development_workflow
severity: medium
applies_when:
  - Running an exact-head final review through Cursor Agent or Claude Code print mode
  - Requiring a terminal LGTM or changes-required verdict before merge
  - Using external reviewers from a repository with checkout-local CLI configuration
resolution_type: workflow_improvement
tags: [external-review, cursor-cli, claude-code, non-interactive, pr-workflow, agent-orchestration]
---

# Make Non-Interactive Final Reviews Workspace- and SHA-Bound

## Context

The first Cursor Grok 4.6 and Claude Sonnet 5 final-review attempts for
[PR #1029](https://github.com/moona3k/macparakeet/pull/1029) did real analysis,
but neither produced a qualifying terminal verdict. Local project records show
that both [Cursor/Grok](../../qa/2026-09-09-release-readiness.md) and
[Claude/Sonnet](../../research/2026-09-11-issue-895-meeting-split/report.md)
have completed comparable work before. The evidence points to two invocation
exceptions, not evidence that either tool or model is unusable.

Cursor was launched with a temporary brief directory as `--workspace`, the
repository worktree only as `--add-dir`, and `--mode plan`. It verified the
requested HEAD and read much of the implementation, but Git and network access
were blocked. Its first turn stopped after promising a verdict. A resumed
`--mode ask` turn correctly returned `FINAL_VERDICT: CHANGES_REQUIRED` because
it had not completed `git diff origin/main...HEAD`; that described incomplete
review coverage, not a code defect.

The workspace indirection was unnecessary. The dirty primary checkout also
contains a private Cursor project configuration excluded from version control
and absent from this worktree and `origin/main`. Cursor Agent
`2026.09.10-fd3934a` rejects with `permissions.allow: Required` and
`Unrecognized key(s) in object: 'attribution'`. The task worktree has no such
configuration. Do not edit or delete private primary-checkout configuration as part
of a review; use the clean task worktree as the actual workspace.

Claude Code `2.1.270` was launched in print mode with `Task` available and
`--no-session-persistence`. Sonnet 5 delegated two read-only slices to
background Plan agents. The parent then reported:

```text
Background tasks still running after 600s; terminating. Set CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 to wait indefinitely.
```

The receipt recorded two spawned agents, zero completions, and two system
terminations. A later resume failed with `No conversation found with session
ID` because the original command had explicitly disabled persistence.

A corrected Cursor retry was then launched at the same time as a max-effort
Sonnet review. Cursor was killed with exit status 137 before emitting output,
while Sonnet completed. Running Cursor alone from both the task worktree and a
detached linked worktree reproduced the immediate kill, so reviewer concurrency
was not the cause.

The remaining boundary was Cursor-specific. In a fresh independent clone, a
no-tools Grok 4.6 prompt succeeded. An Ask-mode shell probe then reported that
Ask mode blocks the shell, while a Plan-mode probe read the exact Git SHA.
Detailed review briefs still exited 137 in Cursor Agent
`2026.09.10-fd3934a`; a concise Plan-mode contract completed the full diff
review and emitted the required verdict. No OS crash record identified the
internal reason for the prompt-sensitive termination, so the reliable remedy
is the verified invocation shape, not a speculative root-cause claim.

Later exact-head retries exposed a separate output-capture boundary. The
pseudo-terminal run returned only a terminal control sequence, while an
ordinary `--output-format text` run returned only a newline; both exited 0
without a verdict. Resuming the persisted review with `--output-format
stream-json --stream-partial-output` returned the complete assistant response
and a final result event. The PTY was therefore not the root cause. In this
Cursor build, structured streaming output is the verified capture path. The
review is complete only when an assistant response or successful final result
contains both the reviewed SHA and the review contract's exact terminal
verdict token.

## Guidance

Treat an external final review as a SHA-bound merge gate:

1. Finish and push every code and documentation change first. Record
   `git rev-parse HEAD`, confirm the task worktree is clean, and put that exact
   SHA in the review prompt.
2. Run from a clean repository root. `--add-dir` grants access to an additional
   root; it does not make that root the primary workspace. If checkout-local
   Cursor configuration is invalid or execution remains unstable, use a fresh
   independent clone at the pushed SHA; a linked worktree still shares its
   primary repository's Git directory.
3. Use a one-shot, tool-capable read-only mode and require a terminal verdict.
   For Cursor this is Plan mode: Ask mode blocks shell commands and cannot
   verify an exact Git diff. Capture print mode as structured streaming output
   and retain the session so an empty terminal response can be resumed. The
   response is incomplete unless it names the reviewed SHA and emits the agreed
   verdict token in an assistant response or successful result event.
4. For Claude print-mode review, exclude `Task` and other delegation tools.
   Keep normal session persistence so an interrupted run can be resumed.
5. Run independent final reviewers in parallel by default when each uses an
   isolated read-only session against the same pushed SHA. If one reviewer is
   killed, returns no output, or behaves inconsistently, let healthy reviews
   finish and diagnose only the failing reviewer serially. Preserve its exit
   status and change one invocation boundary at a time.
6. If any commit lands after either review, including a documentation-only
   commit, rerun both reviewers on the new pushed HEAD.

For Cursor, use the clean repository as both the current directory and
`--workspace`, use `--mode plan`, explicitly enable the sandbox, and select the
exact installed model ID `cursor-grok-4.6-xhigh`. Keep the prompt concise: name
the diff, read-only boundary, finding threshold, reviewed SHA, and exact verdict
tokens. A large checklist is less reliable in the affected Cursor build and
does not substitute for the model reading the repository instructions. Use
`--output-format stream-json --stream-partial-output`; reconstruct the verdict
from assistant deltas or the final result event rather than relying on plain
text output alone.

For Claude, `--safe-mode` removes custom agents, plugins, hooks, and MCP
configuration, while `--tools "Read,Glob,Grep,Bash"` omits `Task`.
Print mode keeps the run non-interactive, while plan mode, denied permission
prompts, and the explicit review prompt establish the intended read-only
boundary. Do not pass `--no-session-persistence`. Setting
`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` is an alternative only when delegation
is deliberate; retain persistence and require the parent to wait for and
synthesize every child before returning a verdict.

## Why This Matters

Process state is not a passed review gate. Cursor first returned without its
promised verdict and later was killed before returning output, while Claude
returned without a verdict after its child reviews were terminated. Ask mode
also succeeded as a process while explicitly declining the shell operation.
Accepting any of these outcomes would confuse tool execution with review
completion.

Code and tests do not preserve these orchestration constraints. The important
boundaries are the CLI workspace root, the tools available to a print-mode
model, background-agent lifecycle, session resumability, and the exact commit
reviewed. Keeping those boundaries explicit makes an independent LGTM
reproducible and auditable.

## When to Apply

- An external CLI model is a final non-interactive review gate.
- A review process exits without the required verdict.
- Git access is unexpectedly unavailable despite readable repository files.
- Claude print mode launches background agents.
- A reviewer is killed, produces no output, or was co-scheduled with another
  heavyweight review.
- A print-mode review exits successfully but returns only terminal control
  output or a blank plain-text response instead of its verdict.
- The PR head changes after an external review.

The no-delegation rule does not apply to an intentionally coordinated
multi-agent review. In that case, make the unlimited wait an explicit choice,
preserve the session, and require parent synthesis before accepting a verdict.

## Examples

Avoid using a brief directory as Cursor's workspace:

```sh
cursor agent -p --mode plan \
  --workspace /tmp/review-brief \
  --add-dir /absolute/path/to/clean-task-worktree \
  --model cursor-grok-4.6-xhigh \
  "Read the brief and review the PR."
```

Use a clean independent clone when checkout-local configuration or linked
worktree execution is suspect, and keep the final contract concise:

```sh
review_clone=/absolute/path/to/clean-independent-clone
cd "$review_clone"

cursor agent -p \
  --mode plan \
  --model cursor-grok-4.6-xhigh \
  --workspace "$review_clone" \
  --trust \
  --sandbox enabled \
  --output-format stream-json \
  --stream-partial-output \
  "Analyze git diff origin/main...HEAD for material issues. Read AGENTS.md and relevant files. Read only; do not edit, delegate, or run tests. State the SHA, cite actionable findings, and end exactly FINAL_VERDICT: LGTM or FINAL_VERDICT: CHANGES_REQUIRED."
```

If the terminal response is empty, resume the persisted session once with the
same structured output flags and ask it to return the completed review without
more tool work. The resumed result still must name the original SHA and include
the required verdict token.

Avoid combining unrestricted delegation with an unrecoverable Claude print
session:

```sh
claude -p \
  --model claude-sonnet-5 \
  --permission-mode plan \
  --no-session-persistence \
  "Perform the final review."
```

Use a resumable, non-delegating print invocation:

```sh
review_worktree=/absolute/path/to/clean-task-worktree
cd "$review_worktree"

claude -p \
  --model claude-sonnet-5 \
  --effort max \
  --safe-mode \
  --tools "Read,Glob,Grep,Bash" \
  --permission-mode plan \
  --permission-prompts none \
  --output-format text \
  "Review the exact current HEAD against origin/main. Read AGENTS.md and the full diff. Do not modify files, delegate, or change external state. State the reviewed SHA and finish with exactly FINAL_VERDICT: LGTM or FINAL_VERDICT: CHANGES_REQUIRED."
```

If delegation is intentional, use the wait override as an explicit lifecycle
choice and keep the session resumable:

```sh
CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 claude -p \
  --model claude-sonnet-5 \
  --permission-mode plan \
  --permission-prompts none \
  "Perform the review, delegate the named slices, wait for every child, then synthesize one terminal verdict."
```

## Related

- [PR review workflow](../../pr-review-workflow.md)
- [AI coding method](../../../spec/10-ai-coding-method.md)
- [Agent memory governance](../../agent-memory-governance.md)
- [PR #1029](https://github.com/moona3k/macparakeet/pull/1029), the open
  review where these invocation exceptions were observed
