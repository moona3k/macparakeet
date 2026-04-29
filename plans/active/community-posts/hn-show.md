# Hacker News — Show HN

> **Status:** drafted, not posted. Needs an HN account.

## Why HN

Broad reach into the dev / startup / infra audience. People who run
homelabs, build agent stacks, run their own Mac mini for compute,
and care about local-first tooling. HN can be hostile to perceived
self-promotion, so the framing matters more than the content.

## Best practices (from the HN guidelines + observed patterns)

- **Do** lead with what it is in one sentence. No teaser titles.
- **Do** use the `Show HN:` prefix — required for project shares and
  invites a different reader posture.
- **Do** post on a weekday US morning (Pacific time roughly 8–11 a.m.)
  for best initial visibility.
- **Don't** ask for upvotes anywhere (in the post, in followups, in
  Twitter, in Discord). HN auto-flags this hard.
- **Don't** post the same blurb to multiple sites the same hour.
- **Don't** title with hype words. Avoid "fastest," "best,"
  "revolutionary."
- **Be present** in the comment thread for the first few hours. Top
  of the thread is the maintainer's engagement, not just the post.

## Title

```
Show HN: macparakeet-cli – local Parakeet STT on Apple Silicon for AI agents
```

(80 chars; HN soft-limit is 80 in the title field.)

## URL field

```
https://github.com/moona3k/macparakeet
```

(Linking to the repo, not the website. HN audience prefers the repo.)

## First comment to post immediately after

The first-comment-by-the-author pattern works well on HN — it's a
chance to add context without making the title too dense. Post this
**immediately** after submitting:

````markdown
Hi HN — Daniel, maintainer of MacParakeet here.

Quick context: this repo has had a macOS app (system-wide dictation, file transcription) since the start. The CLI was internal-feeling until today. With v1.0 of the CLI I'm committing to it as a versioned public surface — semver, written compatibility policy, stable JSON output on every read-only command, brew install path.

The reason I'm doing the reframe is that Apple Silicon Mac minis are increasingly the home for personal AI agent daemons (OpenClaw, Hermes, custom shell loops). Voice / STT is the documented gap in that stack: Whisper.cpp doesn't use the Neural Engine, the OpenAI Whisper API breaks local-first, parakeet-mlx (Python) doesn't have a memory layer or prompts. `macparakeet-cli` is exactly the slot between those.

Architecture summary:

```text
              Parakeet TDT 0.6B v3   (NeMo, public weights)
                       │
              FluidAudio             (CoreML on the Apple Neural Engine)
                       │
              ┌────────┴────────┐
              │ MacParakeetCore │   Swift library, no UI deps
              │ STT · DB · LLM  │
              └────────┬────────┘
                       │
            ┌──────────┴──────────┐
            ▼                     ▼
    macparakeet-cli         MacParakeet.app
    (semver 1.0.0)          (SwiftUI, GUI consumer)
```

The CLI is the load-bearing surface. The macOS app is one well-crafted client of it. Agent skills (OpenClaw, Hermes, generic shell automation) are other clients.

Everything is GPL-3.0. No accounts, no telemetry by default (opt-in, content-free, see <https://github.com/moona3k/macparakeet/blob/main/docs/telemetry.md>). The launch post with the full story is at <https://macparakeet.com/blog/macparakeet-cli-1-0/>; the agent-facing landing is at <https://macparakeet.com/agents>.

Happy to answer anything. Bug reports / feature requests filed on GitHub get a real human response.
````

## Things to expect in the thread

- **Comparisons to Whisper.cpp / WhisperKit** — be factual: WhisperKit is fine on the ANE; Parakeet TDT happens to be faster + lower-WER for English at the 0.6B size, plus FluidAudio runs both. Both are good.
- **"Why GPL not MIT?"** — link to <https://macparakeet.com/blog/macparakeet-open-source/> which addresses this directly. The short answer is: end-user app, want improvements to flow back. FluidAudio (Apache 2.0) is the embeddable layer.
- **Privacy questions** — answer factually: STT runs on-device ANE, DB local, no audio ever leaves device, optional cloud LLM only when explicitly configured.
- **"Will this work on Linux / x86 Mac?"** — no. Apple Silicon ANE is the entire premise. (For non-Apple-Silicon, parakeet-mlx + Python or Whisper.cpp are appropriate.)
- **Feature requests** — note in the answer if it's roadmap, not-roadmap, or unsure. "Simplicity is the product" is a real constraint.

## Things NOT to do in comments

- Don't pitch competing tools negatively.
- Don't post the same content again in replies.
- Don't paste the launch blog post body into comments — link.
- Don't engage with bait. The "this should be a Rust CLI" type comments are best replied to once with the technical reason and then ignored.

## After the post

- Keep an eye on the thread for ~2-3 hours after posting (peak engagement window).
- File any actionable feedback as GitHub issues with `from-hn` label.
- The HN URL becomes a permanent link to the conversation; it's worth referencing in future blog posts.
