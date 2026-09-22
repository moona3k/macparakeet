# Coding Agent Instruction Strategy - 2026-06

> Status: **ACTIVE REFERENCE** - Rationale for the June 2026 agent-doc cleanup.

## Summary

MacParakeet should keep always-loaded agent instructions short, concrete, and
verification-oriented. Durable startup context should explain how to build,
test, navigate, and avoid known project hazards. Volatile feature catalogs,
release deltas, long plans, and historical requirement indexes should live in
linked docs that agents load only when relevant.

The operating policy for memory and instruction placement lives in
[`../agent-memory-governance.md`](../agent-memory-governance.md).

This supports the current split:

- `AGENTS.md` is the canonical cross-agent startup guide.
- `CLAUDE.md` is a small Claude-specific overlay.
- `spec/10-ai-coding-method.md` describes the working method.
- Historical `REQ-*` IDs are archived, not part of normal workflow.

## Official Tool Guidance

### Anthropic Claude Code

Anthropic describes `CLAUDE.md` and auto memory as context loaded at session
start, not enforced configuration. Their guidance says concise, specific
instructions are followed more consistently, recommends keeping each
`CLAUDE.md` under 200 lines, and notes that imported files still enter startup
context. Claude loads `CLAUDE.md`, not `AGENTS.md`, so an `@AGENTS.md` import
is the intended bridge for repos that already have a cross-agent guide.

Auto memory is a separate machine-local layer. Claude loads only the first 200
lines or 25 KB of `MEMORY.md` at startup; topic files are read on demand. The
settings docs also make the tradeoff explicit: disabling auto memory via
`autoMemoryEnabled`, `/memory`, or `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` disables
both reading and writing.

Anthropic's recommended escape hatches are path-scoped `.claude/rules/`, skills
for reusable procedures, subagents for context-isolated work, and hooks or
settings when behavior must be enforced rather than suggested.

Sources:

- https://docs.anthropic.com/en/docs/claude-code/memory
- https://docs.anthropic.com/en/docs/claude-code/settings
- https://docs.anthropic.com/en/docs/claude-code/skills
- https://docs.anthropic.com/en/docs/claude-code/sub-agents

### OpenAI Codex

OpenAI's Codex best-practices guidance recommends using `AGENTS.md` for durable
repo guidance: layout, commands, conventions, PR expectations, constraints, and
definition of done. It explicitly favors a short, accurate `AGENTS.md` over a
long file of vague rules, and recommends linking task-specific docs when the
main file grows too large. It also recommends planning first for complex tasks
and validating changes with tests/review rather than stopping at code
generation.

Source: https://developers.openai.com/codex/learn/best-practices

### AGENTS.md Format

The public AGENTS.md format frames the file as a README for agents: a predictable
place for setup commands, test commands, and project conventions that would
clutter a human README.

Source: https://agents.md/

## Research Evidence

### Long Context Is Not Free

`Lost in the Middle` shows that long-context models can fail to use information
robustly depending on where it appears in the prompt. For agent instruction
files, the practical implication is not "never use long context"; it is "do not
make every session pay for information that only matters occasionally." Keep
high-priority rules short and near startup, and link to deeper docs by task.

Source: https://arxiv.org/abs/2307.03172

### Agent Interfaces Matter

`SWE-agent` argues that language-model agents are end users of software tools
and benefit from purpose-built agent-computer interfaces. The MacParakeet
translation is that instructions should emphasize actionable interfaces:
commands, file locations, test loops, worktree rules, and verification paths.
A giant prose encyclopedia is a weaker interface than a concise guide plus
discoverable docs.

Source: https://arxiv.org/abs/2405.15793

### Reasoning Plus Action Beats Static Reasoning

`ReAct` supports interleaving reasoning with actions against external tools and
environments. For coding agents, that favors instructions that tell the agent
how to inspect, run, test, and verify, rather than instructions that try to
preload every possible fact.

Source: https://arxiv.org/abs/2210.03629

### Reflection Helps When It Captures Real Feedback

`Reflexion` shows value in agents learning from feedback through persistent
natural-language reflections. For repo docs, the useful version is not a large
up-front rulebook; it is updating agent guidance after repeated mistakes,
review findings, or recurring clarifications.

Source: https://arxiv.org/abs/2303.11366

### Benchmarks Do Not Replace Local Verification

Work on SWE-bench contamination/memorization argues that benchmark gains can
overstate generalizable coding ability. For MacParakeet, this reinforces the
need for local verification: current code, focused tests, full tests when
appropriate, CI, and review. Do not assume a frontier model will infer every
repo-specific invariant from broad coding ability.

Source: https://arxiv.org/html/2506.12286v1

## MacParakeet Decisions

1. Keep root startup docs under roughly one screen of essential guidance per
   file when possible.
2. Put commands, worktree rules, product constraints, and verification defaults
   in `AGENTS.md`.
3. Keep `CLAUDE.md` real but narrow: Claude-specific memory behavior,
   local-state cautions, and links to current sources.
4. Link to specs and ADRs for feature state instead of duplicating release
   flags in startup context.
5. Treat plans as useful agent working memory for substantial tasks, not a
   mandatory ceremony.
6. Retire the manual `REQ-*`/traceability workflow. Use specs, tests, code
   search, and `git` history for current implementation discovery.
7. Use independent review and convergence for substantial changes, but keep the
   review loop proportional to risk.
8. Treat auto memory as a stale-prone hint store, not a source of truth for
   release, PR, CI, deploy, analytics, or current product state.
9. Promote single-subsystem lessons out of global memory into subsystem READMEs,
   specs, tests, workflow docs, or skills.
