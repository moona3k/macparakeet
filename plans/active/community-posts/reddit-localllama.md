# Reddit — r/LocalLLaMA

> **Status:** drafted, not posted. Needs Reddit account + flair selection.

## Why r/LocalLLaMA

The audience overlaps heavily with our target persona: local-first
AI/ML tinkerers, Mac Studio + Mac mini agent operators, people who
care about owning their compute and not paying for cloud STT.

## Subreddit conventions to honor

- Posts are usually descriptive titles (no clickbait).
- Self-posts (text posts) tend to do better than bare links.
- Code blocks render. Markdown is supported.
- Cross-posts welcomed if useful, but better to write a fresh post.

## Suggested flair

Likely options: `Resources`, `Tutorial`, `Discussion`, `New Model`.
**`Resources`** fits best (we're sharing a tool, not a model).

## Title (pick one)

Primary:
```
macparakeet-cli 1.0 — local Parakeet TDT speech-to-text on Apple Silicon, for AI agents (GPL-3.0)
```

Alternatives if 100-char limit is tight:
- `macparakeet-cli 1.0 — local Parakeet STT on Apple Silicon ANE, for agent use (GPL-3.0)`
- `Local Parakeet TDT CLI for Apple Silicon agents — macparakeet-cli 1.0 (GPL-3.0)`

## Post body

````markdown
TL;DR: I just tagged `macparakeet-cli 1.0`, a Swift-native CLI that runs NVIDIA's Parakeet TDT 0.6B v3 on the Apple Neural Engine via FluidAudio. ~155x realtime, ~2.5% WER, ~66 MB memory per inference slot. Free + open-source (GPL-3.0). `brew install moona3k/tap/macparakeet-cli`.

## Why I'm posting it here

Voice/STT is the documented gap in the local-agent stack on Mac:

- Whisper.cpp doesn't use the Neural Engine, so it's measurably slower on Apple Silicon than what the hardware can do.
- The OpenAI Whisper API is fast but cloud-only, paid, and breaks the local-first posture this subreddit is built around.
- `parakeet-mlx` (Python) is the closest thing in spirit, but doesn't carry persistence, prompts, or speaker diarization.

`macparakeet-cli` is the slot between those: Apple Silicon native, ANE-accelerated, persistent SQLite memory, prompt library, semver-stable JSON output. The CLI has existed since v0.1 of the MacParakeet macOS app and powered AI-assisted testing through v0.4–v0.6 — the 1.0.0 tag is the commitment to a stable public surface, not a feature release.

## What you can do with it

```bash
brew install moona3k/tap/macparakeet-cli

macparakeet-cli health --json
macparakeet-cli transcribe ~/Downloads/podcast.mp3 --format json
macparakeet-cli transcribe "https://www.youtube.com/watch?v=..." --format json
macparakeet-cli history search-transcriptions "design review" --json
macparakeet-cli prompts run "Action items" --transcription <id> \
  --provider anthropic --api-key "$KEY" --model claude-sonnet-4-6
```

JSON output everywhere with stable schemas (semver, [CHANGELOG](https://github.com/moona3k/macparakeet/blob/main/Sources/CLI/CHANGELOG.md)). UUID-or-name lookups with `.notFound`/`.ambiguous` error classes. All STT runs on the Neural Engine; no audio leaves the device. Optional cloud LLM provider only if you explicitly pass one.

## Why Apple Silicon specifically

Parakeet TDT runs on the ANE via CoreML. That's the entire performance story. On VPS deployments without Apple Silicon, fallback to CPU is competitive with Whisper.cpp and you might as well use that. **The compelling deployment is a Mac mini (M1+) running headless** — unified memory, ANE, ~8 W idle, silent.

## Pointers

- Repo + docs: <https://github.com/moona3k/macparakeet>
- For agent operators (OpenClaw, Hermes, Codex, Claude Code): <https://macparakeet.com/agents>
- Launch post with the architecture story: <https://macparakeet.com/blog/macparakeet-cli-1-0/>
- Compatibility policy: <https://github.com/moona3k/macparakeet/blob/main/Sources/CLI/CHANGELOG.md>

I'm the maintainer (Daniel, [@moona3k](https://github.com/moona3k)) — happy to answer questions and take feature requests. Issues filed on the repo get a real human response.
````

## Self-comment to add (optional, after a few hours)

If discussion picks up, drop a follow-up comment with a recipe people often ask about, e.g.:

```
For anyone wiring this into an agent (OpenClaw / Hermes / a custom shell loop), the integration vocabulary lives at <https://github.com/moona3k/macparakeet/tree/main/integrations>. The thin per-ecosystem scaffolds are at integrations/openclaw/ and integrations/hermes/.

If you want to set up a Mac mini as a personal STT box and call it from another machine, the CLI is fine over SSH (just JSON over stdout). The DB lives at `~/Library/Application Support/MacParakeet/macparakeet.db` so you can rsync that for backups.
```

## Things to monitor after posting

- Genuine bug reports → file as macparakeet GitHub issues with `bug` label.
- Feature requests → assess against the "simplicity is the product" north star; not all asks should ship.
- Questions about FluidAudio / Parakeet TDT internals → defer to FluidAudio docs.
- Negative comments about closed competitors → don't engage; let the spec numbers speak.
