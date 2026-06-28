# Agent Memory Governance

> Status: **ACTIVE** -- how MacParakeet keeps agent instructions useful without
> turning every session into a long-context tax.

## Verdict

The sensible move is not "delete all memory." It is to stop treating
always-loaded memory as a knowledge base.

MacParakeet should keep a small push layer that loads every session and move
everything else to pull surfaces the agent reads only when relevant. Durable,
single-subsystem lessons belong in code, tests, subsystem READMEs, specs, or
skills. Volatile state belongs behind live commands and canonical sources, not
in startup instructions.

## What Loads

Anthropic's current Claude Code guidance draws the boundary this way:

- `CLAUDE.md` files and auto memory both load at the start of a session as
  context, not enforced configuration.
- Claude follows concise, specific instructions more reliably than long,
  conflicting ones.
- Each `CLAUDE.md` should stay under 200 lines. Imports help organization but
  still load into startup context.
- Auto memory loads only the first 200 lines or 25 KB of `MEMORY.md`, whichever
  comes first. Topic files are pull-only unless Claude reads them.
- Claude reads `CLAUDE.md`, not `AGENTS.md`. A one-line `@AGENTS.md` import is
  the right bridge when the repo already has cross-agent instructions.
- Multi-step or narrow-context procedures should move to skills, path-scoped
  rules, or local subsystem docs instead of root startup files.
- `autoMemoryEnabled: false`, `/memory`, or
  `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` disable both reading and writing auto
  memory.

Use hooks, scripts, tests, permissions, or product code when something must be
enforced. Startup instructions only shape model behavior.

## Repo Policy

Use the smallest durable surface that can carry the lesson:

| Surface | Put here | Do not put here |
| --- | --- | --- |
| `AGENTS.md` | Cross-agent commands, repo invariants, source-of-truth links, worktree rules | Claude-only details or volatile release facts |
| `CLAUDE.md` | `@AGENTS.md` plus Claude-specific memory/rule behavior | Repeated copies of commands, specs, review workflow, or subsystem gotchas |
| Specs/ADRs | Product behavior, accepted decisions, public contracts | One-off agent notes |
| Subsystem READMEs | Local implementation hazards and edit rules | Whole-repo workflow guidance |
| `docs/pr-review-workflow.md` | Review and merge-readiness process | Feature-specific implementation notes |
| Skills | Reusable multi-step workflows or tool recipes | Always-true repo facts |
| Claude auto memory | Machine-local hints that are useful to retrieve on demand | Source of truth for releases, PRs, CI, deploys, analytics, or secrets |

## Audit Buckets

When reviewing `CLAUDE.md`, `AGENTS.md`, or local auto memory, bucket each entry:

1. **Finished-work record**: delete it. Git history, PRs, and plans carry this.
2. **Volatile live state**: replace it with the command or canonical source to
   verify live.
3. **Single-subsystem lesson**: move it to the subsystem README, governing spec,
   a focused test, or a skill.
4. **Reusable workflow**: move it to a skill or workflow doc.
5. **Cross-cutting safety rail**: keep it in `AGENTS.md` or the small
   Claude-specific overlay only if it changes behavior in many tasks.

An entry earns startup context only if it changes a likely next decision in
nearly every session.

## Promotion Map

- Database migrations, GRDB UUID storage, or repository access patterns:
  `Sources/MacParakeetCore/Database/README.md` and `spec/01-data-model.md`.
- STT scheduling, engine routing, and runtime constraints:
  `Sources/MacParakeetCore/STT/README.md`, `spec/06-stt-engine.md`, and focused
  tests.
- Audio capture, meeting artifacts, and recovery:
  `Sources/MacParakeetCore/Audio/README.md`, `spec/05-audio-pipeline.md`,
  `spec/contracts/`, and recovery tests.
- UI hover, panel, and visual interaction rules: `spec/04-ui-patterns.md` or
  local view/controller comments when the behavior is highly localized.
- Permissions, clipboard, Accessibility selection/replacement, focused-app
  context, media control, and launch-at-login:
  `Sources/MacParakeetCore/Services/System/README.md`.
- Public CLI behavior: `integrations/README.md`, `Sources/CLI/README.md`,
  `Sources/CLI/CHANGELOG.md`, and CLI tests.
- Release, signing, notarization, Sparkle, and DMG details:
  `docs/distribution.md` and `spec/README.md`.
- PR review, worktree safety, and merge readiness:
  `AGENTS.md` and `docs/pr-review-workflow.md`.
- Security-sensitive local facts, env vars, and private keys: do not commit.
  Store them outside the repo or in an approved secret manager.

## Maintenance Checklist

Run this check when agent behavior starts drifting or a memory file gets noisy:

```bash
wc -l CLAUDE.md AGENTS.md
git diff -- CLAUDE.md AGENTS.md docs/agent-memory-governance.md
```

For Claude auto memory, inspect it locally with `/memory`. Back it up outside
the auto-loaded directory before pruning, then delete or promote entries using
the buckets above. Do not commit the local memory store.

## Sources

- Anthropic Claude Code memory:
  https://docs.anthropic.com/en/docs/claude-code/memory
- Anthropic Claude Code settings:
  https://docs.anthropic.com/en/docs/claude-code/settings
- Anthropic Claude Code skills:
  https://docs.anthropic.com/en/docs/claude-code/skills
- Anthropic Claude Code subagents:
  https://docs.anthropic.com/en/docs/claude-code/sub-agents
