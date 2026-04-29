# Registry submission drafts

Drafts of the content + submission bodies for placing `macparakeet-cli`
in the relevant agent skill registries. The Hermes and OpenClaw
awesome-list issues have been submitted; the ClawHub path is deferred
until its CLI and SKILL.md schema are verified.

## Status snapshot (post-2026-04-25 reconnaissance)

The brew tap is live as of 2026-04-25, so install instructions
(`brew install moona3k/tap/macparakeet-cli`) are now valid in any
submission. Reconnaissance against each target's `CONTRIBUTING.md`
sharpened the picture significantly — see per-target notes below.

| # | Registry | Repo | Submission flow | Status (2026-04-25) |
|---|---|---|---|---|
| 1 | Awesome Hermes Agent | [`0xNyk/awesome-hermes-agent`](https://github.com/0xNyk/awesome-hermes-agent) | **Issue first** — direct PRs explicitly forbidden by CONTRIBUTING.md | ✅ **Submitted:** [issue #49](https://github.com/0xNyk/awesome-hermes-agent/issues/49) |
| 2 | Awesome OpenClaw | [`vincentkoc/awesome-openclaw`](https://github.com/vincentkoc/awesome-openclaw) | **Issue first** via `Add Resource Request` template, PR after maintainer approval | ✅ **Submitted:** [issue #71](https://github.com/vincentkoc/awesome-openclaw/issues/71) |
| 3 | OpenClaw skill registry | [`openclaw/clawhub`](https://github.com/openclaw/clawhub) | **CLI-based** (`openclaw clawhub skill publish <path>`); uses `SKILL.md` (NOT `SOUL.md`) | **Deferred** — npm `openclaw@2026.4.24` is the full OpenClaw runtime (36 deps); installing globally to publish a single skill is overkill. Defer until either an isolated install path is set up OR there's a lighter-weight publish flow. |
| 4 | Awesome OpenClaw Skills | [`VoltAgent/awesome-openclaw-skills`](https://github.com/VoltAgent/awesome-openclaw-skills) | Manual PR — but **only accepts skills already published in `github.com/openclaw/skills`** | **Deferred** — depends on (3) succeeding first |

## Critical schema correction

The `SOUL.md` filename in `integrations/openclaw/` was based on a
mistaken belief that ClawHub uses SOUL.md. **It does not.** ClawHub
uses `SKILL.md` with frontmatter metadata. `SOUL.md` is the format
used by a different agent registry (onlycrabs.ai). See `clawhub.md`
for details. PR #146 reframed the OpenClaw entry point as
`integrations/openclaw/README.md` and documents the SKILL.md target.

## Submission order (revised)

The previous "submit all four" plan was incorrect. Updated:

1. **Now**: Monitor the submitted `awesome-hermes-agent` issue #49
   and `awesome-openclaw` issue #71 for maintainer feedback.
2. **Later** (separate, more involved): If pursuing ClawHub publication,
   install the OpenClaw CLI, verify SKILL.md frontmatter spec via
   `docs.openclaw.ai/tools/clawhub`, prepare a real SKILL.md package,
   and run `clawhub skill publish`.
3. **Even later**: After (2) succeeds, the `VoltAgent/awesome-openclaw-skills`
   list may auto-sync, or may accept a manual PR linking to the
   newly-published clawhub entry.

## Per-target drafts

- [`awesome-hermes-agent.md`](./awesome-hermes-agent.md) — issue body draft
- [`awesome-openclaw.md`](./awesome-openclaw.md) — issue template responses
- [`clawhub.md`](./clawhub.md) — deferred submission notes + schema findings

## Cross-posting (after registry placements take)

Once the registry placements have landed, cross-post to:

- **r/LocalLLaMA** — *"Local Whisper alternative for Mac mini AI agents (Parakeet on the Neural Engine)"*
- **Hacker News** — *"Show HN: macparakeet-cli — canonical Parakeet CLI for Apple Silicon agents"*
- **OpenClaw Discord** — `#showcase` or equivalent
- **Nous Research Discord** — `#hermes-agent` or equivalent

Time these to land alongside v0.6.0 release for compounding momentum
(item #6 of the canonical plan). Don't fire community posts before
the brew tap is live AND the registry placements have been accepted.
