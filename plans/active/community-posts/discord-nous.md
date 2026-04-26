# Nous Research Discord — `#hermes-agent` (or equivalent)

> **Status:** drafted, not posted. Needs Discord with Nous Research server membership.

## Find the right channel

Nous Research's Discord is the canonical home for Hermes Agent
discussion. Look for:

1. `#hermes-agent` (most likely)
2. `#hermes` or `#agents`
3. `#community-tools` / `#showcase`
4. `#hermes-skills` if a skills-specific channel exists

If unclear, ask in `#general` ("which channel for new tools that
Hermes skills can call?") — that's lower-effort than guessing wrong.

## Tone

Nous community values rigor and specificity. They'll ask about model
internals, evaluation methodology, and reproducibility. Be ready
with the FluidAudio + Parakeet TDT details and the WER claim's
provenance (it's NVIDIA's published number for the model).

## Post text

````markdown
hey nous community 👋

just tagged macparakeet-cli 1.0 — a swift-native CLI for NVIDIA's Parakeet TDT 0.6B v3 running on the Apple Neural Engine via FluidAudio. ~155x realtime, ~2.5% WER, ~66 MB per inference slot. GPL-3.0.

posting because: voice / STT is the documented gap in the Hermes-on-Mac-mini stack, and i think this is the right shape to fill it. concretely, what a Hermes skill author gets:

• local STT (no cloud, ANE-accelerated)
• file + youtube transcription
• persistent SQLite memory layer at ~/Library/Application Support/MacParakeet/macparakeet.db (skill can recall prior runs across sessions)
• prompt library with BYO LLM provider
• stable JSON on every read-only command (semver, written compatibility policy)
• exit codes / stderr / lookup conventions documented for skill use

install on macOS 14.2+ Apple Silicon:

```bash
brew install moona3k/tap/macparakeet-cli
macparakeet-cli health --json
```

hermes-flavored scaffold (illustrative skill manifest sketch + capability table): https://github.com/moona3k/macparakeet/tree/main/integrations/hermes

agent-facing landing: https://macparakeet.com/agents
launch post (with full architecture story): https://macparakeet.com/blog/macparakeet-cli-1-0/

awesome-hermes-agent issue: https://github.com/0xNyk/awesome-hermes-agent/issues/49

i'm the maintainer (@moona3k on github), happy to answer Qs about wiring it into a skill. open to feedback on the integrations/hermes/ scaffold from people who've actually built Hermes skills.
````

## Anticipated questions

- **"Is this a Hermes skill?"** — No, it's a CLI that a Hermes skill calls.
  The scaffold at integrations/hermes/ shows how to wire one up.
- **"How does the WER compare to Whisper-large-v3?"** — Parakeet TDT
  0.6B benchmarks at ~2.5% WER on standard English; Whisper-large-v3
  is similar. The performance edge here is throughput on the ANE,
  not WER.
- **"Why not parakeet-mlx?"** — parakeet-mlx is great for the
  Python ecosystem; macparakeet-cli is Swift-native + has the
  persistence/prompts layer for skill use.
- **"Does it support diarization?"** — Yes, via FluidAudio's offline
  pipeline. Available on file transcription.
- **"Memory footprint when idle?"** — ~0 MB. Models load on demand
  per inference slot.

## Things to avoid

- No `@everyone`, `@here`, or `@<role>` pings.
- Don't post the same text in #hermes-agent and another Nous channel.
- Don't compare unfavorably to Hermes itself or to other Nous
  projects — that's poor form in their server.
- Don't pitch your other tools (the Mac app, the CLI) separately.
  The post is about the CLI.

## Engagement

- Answer questions the first day actively; less so after.
- If someone wants to ship a real Hermes skill that wraps this, offer
  to review their skill manifest or pair on the wiring.
- Negative or skeptical comments → respond once with a technical
  answer; don't escalate.

## Track

After posting, capture:
- Discord channel name + message permalink (if accessible)
- Date/time of post
- Notable responses (filed as GH issues if actionable)

Cross-link into PR #145's tracking section.
