# Agent Landscape Notes

> Status: **DATED RESEARCH INDEX** — snapshot last updated 2026-05-03. The
> landscape changes quickly; reverify tools and claims before adoption.

Field notes on the AI-agent frontier as it intersects MacParakeet's needs.
Two threads we actively care about:

- **QA agents** — can an agent verify a user flow works end-to-end?
- **Demo agents** — can an agent produce a polished product demo on demand?

Each doc is a point-in-time landscape map plus an opinion on what to do **as of
its review date**
versus what to **watch** over the next 6–12 months. These are living
documents — update them as the frontier moves and as MacParakeet's surfaces
grow.

| Doc | When to read |
|-----|--------------|
| [qa-agents.md](qa-agents.md) | Considering test automation, frontend QA loops, or "AI test runner" pitches |
| [demo-agents.md](demo-agents.md) | Producing demo videos, evaluating screencast tooling, scoping the social-media wing |

## Standing principles

1. **The landscape is hot — these notes go stale fast.** When in doubt, do a
   fresh sweep before adopting a tool. Cite the date in any update.
2. **Curate, don't catalog.** If a tool has no plausible path to MacParakeet
   (e.g. mobile-only, browser-only when we're a Mac app), it doesn't belong
   here.
3. **Bias toward the building blocks we already have.** `macparakeet-cli`,
   ScreenCaptureKit plumbing, ADR-009 custom hotkeys, and `MacParakeetCore`
   tests are levers — most "AI agent" pitches reduce to wrappers around
   these.
