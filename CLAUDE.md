# CLAUDE.md

@AGENTS.md

> Claude Code overlay for MacParakeet. Keep this file intentionally small:
> [`AGENTS.md`](./AGENTS.md) is the canonical cross-agent startup guide and is
> imported above.

## Claude-Specific Rules

- Treat Claude auto memory, chat history, old plans, and local notes as leads,
  not truth. Verify release, PR, CI, deploy, analytics, and current code state
  live before relying on them.
- Do not grow this file or auto memory by default. Promote durable lessons to
  the narrowest versioned surface: `AGENTS.md`, a subsystem README, spec/ADR,
  `docs/pr-review-workflow.md`, `docs/distribution.md`,
  `integrations/README.md`, or a skill.
- Use `.claude/rules/` or subdirectory `CLAUDE.md` only for Claude-specific
  path-scoped rules that should not load globally.
- When this file and `AGENTS.md` overlap, edit `AGENTS.md` unless the
  instruction only matters to Claude Code.
- If a rule must be enforced rather than merely suggested, prefer tests,
  scripts, hooks, or product code over another instruction line.

## Local-State Cautions

- Preserve dirty or unrelated worktrees. Fresh PR work belongs on a branch or
  worktree based on `origin/main`.
- Do not delete user databases, meeting session folders, source audio, lock
  files, or ignored private files unless the task explicitly asks for a
  recovery or discard flow.
- Ignored paths such as `.claude/`, `journal/`, `.build*`, `dist/`,
  `diagnostics/`, `logs/`, and local env/key files are not review scope unless
  the task names them.

## References

- Agent memory/instruction governance:
  [`docs/agent-memory-governance.md`](./docs/agent-memory-governance.md)
- Current feature/release state: [`spec/README.md`](./spec/README.md)
- PR workflow: [`docs/pr-review-workflow.md`](./docs/pr-review-workflow.md)
