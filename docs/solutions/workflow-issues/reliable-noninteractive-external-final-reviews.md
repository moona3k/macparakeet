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
Sonnet review. Cursor was killed with exit status 137 before emitting any
output, while Sonnet completed. No OS memory-pressure or jetsam record was
captured, so the cause is not established. This is execution evidence, not a
review verdict: rerun the reviewer alone instead of inferring anything about
the code or model.

## Guidance

Treat an external final review as a SHA-bound merge gate:

1. Finish and push every code and documentation change first. Record
   `git rev-parse HEAD`, confirm the task worktree is clean, and put that exact
   SHA in the review prompt.
2. Run from the clean task worktree. `--add-dir` grants access to an additional
   root; it does not make that root the primary workspace.
3. Use a one-shot read-only mode and require a terminal verdict. The response
   is incomplete unless it names the reviewed SHA and emits the agreed verdict
   token.
4. For Claude print-mode review, exclude `Task` and other delegation tools.
   Keep normal session persistence so an interrupted run can be resumed.
5. Run heavyweight final reviewers serially. If a process is killed or returns
   no output, preserve the exit status and rerun it alone.
6. If any commit lands after either review, including a documentation-only
   commit, rerun both reviewers on the new pushed HEAD.

For Cursor, use the clean repository as both the current directory and
`--workspace`, use `--mode ask` for the final Q&A-style verdict, explicitly
enable the sandbox, and select the exact installed model ID
`cursor-grok-4.6-xhigh`.

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
returned without a verdict after its child reviews were terminated. Accepting
any of these outcomes would confuse tool execution with review completion.

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

Use the clean task worktree as the real workspace:

```sh
review_worktree=/absolute/path/to/clean-task-worktree
cd "$review_worktree"

cursor agent -p \
  --mode ask \
  --model cursor-grok-4.6-xhigh \
  --workspace "$review_worktree" \
  --trust \
  --sandbox enabled \
  --output-format text \
  "Review the exact current HEAD against origin/main. Read AGENTS.md and the full diff. Do not modify files, delegate, or change external state. State the reviewed SHA and finish with exactly FINAL_VERDICT: LGTM or FINAL_VERDICT: CHANGES_REQUIRED."
```

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
