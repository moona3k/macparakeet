# Community post drafts

Drafts for cross-posting the macparakeet-cli 1.0 launch to the
relevant communities. **None of these have been posted.** Each
needs the maintainer's account on the target platform; the agent
running this rollout doesn't have those credentials.

## Targets and timing

| # | Platform | Audience | Account needed | Draft |
|---|---|---|---|---|
| 1 | r/LocalLLaMA | Local-first LLM/AI hobbyists, Mac Studio / Mac mini agent operators | Reddit | [`reddit-localllama.md`](./reddit-localllama.md) |
| 2 | Hacker News (Show HN) | Broad dev / startup audience | HN account | [`hn-show.md`](./hn-show.md) |
| 3 | OpenClaw Discord — `#showcase` (or equivalent) | OpenClaw skill authors and operators | Discord with OpenClaw server membership | [`discord-openclaw.md`](./discord-openclaw.md) |
| 4 | Nous Research Discord — `#hermes-agent` (or equivalent) | Hermes Agent users + Nous community | Discord with Nous server membership | [`discord-nous.md`](./discord-nous.md) |

## Posting order + timing

The right time is **alongside v0.6.0** (the meeting-recording release)
for compounding momentum — meeting recording is the headline for
existing users, and the agent reframe is the headline for the new
audience. Both are interesting in their own right; together they tell
a fuller story about where MacParakeet is going.

If posting before v0.6.0, lead with the CLI / agent angle and link to
the `/agents` page + the launch blog post. Avoid pre-announcing
v0.6.0.

Suggested cadence:

1. **Day 0 (release day)**: Post to r/LocalLLaMA. Tends to be
   welcoming for local-first AI tools; good first signal.
2. **Day 0 or Day +1**: Post to Hacker News as a Show HN. Pick a
   weekday morning Pacific time. **Don't** ask people to upvote;
   that's a fast-track to flagging.
3. **Day 0–+2**: Drop the Discord posts in OpenClaw and Nous
   community spaces. Be respectful of channel norms — if their
   `#showcase` channel exists, use it.
4. **Track responses** in this directory; capture any high-quality
   feedback / bug reports as GitHub issues on macparakeet.

## Voice + posture

- **First-person honest, not promotional.** Match the tone of the
  open-source-announcement blog post and the macparakeet-cli 1.0
  launch post.
- **Lead with the gap** (voice/STT slot for Apple Silicon agents),
  not with feature lists.
- **Disclose maintainer status.** Skip salesy adjectives ("fastest,"
  "best," "amazing"). Let the spec numbers speak.
- **No AI-attribution boilerplate** in any of these. They're personal
  posts from the maintainer, not auto-generated content.

## What NOT to do

- **Don't ask for upvotes.** HN auto-flags. Reddit downvotes.
- **Don't multi-post the same comment.** Tailor each platform.
- **Don't subtweet competitors.** Whisper.cpp, parakeet-mlx, the
  OpenAI Whisper API are mentioned only as factual contrast, never
  as targets.
- **Don't post before the brew tap, /agents page, and blog post
  are all live.** All three landed on 2026-04-25, so this gate is
  green.
