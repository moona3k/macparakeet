# OpenClaw Discord — `#showcase` (or equivalent)

> **Status:** drafted, not posted. Needs Discord with OpenClaw server membership.

## Find the right channel

OpenClaw's official server has a `#showcase` channel (or
similar — verify on join). Drop the post there, NOT in `#general`.
If `#showcase` doesn't exist, alternatives in priority order:

1. `#community-projects`
2. `#integrations`
3. `#tools`
4. `#general` (last resort, with a tag like `[showcase]` in the message)

## Tone

OpenClaw community is technical + project-focused. They appreciate
specifics (commands, JSON examples) over marketing copy. Keep it
short, embed the install command, and let them ask follow-ups.

## Post text

````markdown
hey openclaw folks 👋

just shipped macparakeet-cli 1.0 — a swift-native CLI that runs Parakeet TDT 0.6B v3 on the Apple Neural Engine. ~155x realtime, ~2.5% WER, ~66 MB per inference slot. free + open-source (GPL-3.0).

what it gives an OpenClaw skill author:
• local STT (no cloud, no API keys, no per-minute charges)
• transcribe local audio/video files OR youtube urls
• search past dictations / transcriptions across sessions (persistent SQLite memory)
• run prompts against transcriptions (BYO LLM — OpenAI / Anthropic / Ollama / LM Studio / openai-compatible)
• stable JSON output on every read-only command, semver compatibility policy

requires macOS 14.2+ on Apple Silicon (M1/M2/M3/M4). install:

```bash
brew install moona3k/tap/macparakeet-cli
macparakeet-cli health --json
```

OpenClaw scaffold (capability table + install + conventions): https://github.com/moona3k/macparakeet/tree/main/integrations/openclaw

agent-facing landing: https://macparakeet.com/agents
launch blog: https://macparakeet.com/blog/macparakeet-cli-1-0/

i'm the maintainer (@moona3k on github), happy to answer Qs or take feature requests. ClawHub publication is on the roadmap — open to guidance from anyone who's been through it.
````

## What to avoid

- No `@everyone` or `@here` pings. Ever.
- Don't repost in multiple channels.
- Don't paste the same post in any other Discord server within the
  same week — community moderators talk to each other.
- Don't follow up "any thoughts?" 24h later. The post is the post.
  If it landed it landed; if not, learn and try a different angle next time.

## Engaging in the thread

- Answer questions promptly the first day; less aggressively after.
- If someone wants help wiring it into a specific OpenClaw skill,
  offer to look at their code or help via DM.
- If someone reports a bug, ask them to file it on GitHub with
  `from-discord` label and link the thread.

## Track in the rollout

After posting, capture:
- Discord channel name + message permalink (if accessible)
- Date/time of post
- Substantive responses (filed as GH issues if actionable)

Add the message permalink (or "posted in #showcase on YYYY-MM-DD")
to PR #145's tracking section.
