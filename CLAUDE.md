# CLAUDE.md

> Claude Code auto-loads this file every session. To avoid drift, the shared
> "how to work in this repo" guide lives **once** in
> [`AGENTS.md`](./AGENTS.md) (read by every coding agent) and is imported below.
> The spec under [`spec/`](./spec/) is the source of truth for product and
> architecture depth — neither this file nor `AGENTS.md` duplicates it.

@AGENTS.md

## Claude Code specifics

These apply only to Claude Code and are intentionally not in the cross-agent
guide above.

- **Test loop.** This is a SwiftPM project: use `swift test` (full suite) and
  `swift test --filter <Suite/test>` (focused). Don't reach for the
  swift-development skill's `xcodebuild` flow for the normal build/test loop. Run
  `swift test` before declaring code-change work complete.
- **Review before you commit.** For non-trivial diffs, spawn an `Explore` agent
  to review the changed files — it reliably catches real bugs. For design docs
  and plans, get a second opinion from the `codex` and/or `gemini` agents and
  iterate until findings converge to triviality.
- **Memory and skills are harness-injected.** Project memory (`MEMORY.md` +
  `memory/`) and the available skill list arrive via the harness each session —
  don't restate them here or in `AGENTS.md`. Save durable, non-obvious facts to
  memory rather than inlining them into these always-loaded files.
