# Submission draft — `vincentkoc/awesome-openclaw`

> **Status:** ✅ submitted as issue [#71](https://github.com/vincentkoc/awesome-openclaw/issues/71) on 2026-04-25. Awaiting maintainer triage.

## Submission flow (per their CONTRIBUTING.md)

> *"Open an issue with the `Add Resource Request` template before
> opening a PR. Wait for maintainer approval. Unapproved drive-by PRs
> may be closed."*

So: **open issue first** via the GitHub Issues UI using the
[`Add Resource Request`](https://github.com/vincentkoc/awesome-openclaw/issues/new?template=add-resource-request.yml)
template. PR comes only after maintainer approval and a triage
discussion.

## Issue template fields (from `.github/ISSUE_TEMPLATE/add-resource-request.yml`)

The template enforces the following inputs (all required unless noted):

- **Resource name**
- **Resource URL**
- **Suggested section** (dropdown, fixed options)
- **Why it should be included** (rationale + signal)
- **Your relationship to this resource** (dropdown, fixed options)
- **Public signal** (concrete usage / publicity / traction evidence)
- **Checklist** (4 items, all required)

## Pre-filled responses

### Resource name
```
moona3k/macparakeet
```

### Resource URL
```
https://github.com/moona3k/macparakeet
```

### Suggested section (dropdown)
**`Plugins and Integrations`** — the section description allows
community-maintained tools, and our value to OpenClaw is precisely
as an integration target (an OpenClaw skill shells out to
`macparakeet-cli` for local Parakeet STT on Apple Silicon).

### Why it should be included (rationale)
```markdown
Voice / local speech-to-text is currently unrepresented in
awesome-openclaw, and it's a documented gap in the OpenClaw-on-Mac-mini
stack: Whisper.cpp doesn't use the Apple Neural Engine; the OpenAI
Whisper API breaks the local-first posture; `parakeet-mlx` is
Python-only and has no persistence/prompts.

`macparakeet-cli 1.0.0` is the canonical Swift-native CLI for
Parakeet TDT on the Apple Neural Engine — ~155x realtime, ~2.5% WER,
GPL-3.0, semver-stable with a written compatibility policy. For an
OpenClaw skill author specifically:

- Stable JSON output (`--json` on every read-only command) with
  ISO-8601 datetimes and sorted keys.
- UUID-or-name lookup with `.notFound` / `.ambiguous` error classes.
- Exit codes: 0 success, non-zero failure, errors to stderr only.
- Persistent SQLite memory layer at
  `~/Library/Application Support/MacParakeet/macparakeet.db` — the
  skill can recall prior dictations / transcriptions / prompt outputs
  across sessions without re-transcribing anything.
- All execution local on the ANE; optional cloud LLM provider only
  when the agent passes `--provider <cloud>`.

OpenClaw entry point lives at
[`integrations/openclaw/`](https://github.com/moona3k/macparakeet/tree/main/integrations/openclaw)
in the macparakeet repo. The full integration vocabulary
(install, JSON conventions, command list) is at
[`integrations/README.md`](https://github.com/moona3k/macparakeet/blob/main/integrations/README.md).
The persona-framed landing page lives at
<https://macparakeet.com/agents>.

Install:
`brew tap moona3k/tap && brew install macparakeet-cli`
(macOS 14.2+ Apple Silicon).
```

### Your relationship (dropdown)
**`I am the maintainer, founder, or builder`** — disclosing affiliation
per CONTRIBUTING quality standards.

### Public signal
```markdown
- **Public site + brand**: <https://macparakeet.com> (live, Cloudflare
  Pages), with a dedicated `/agents` landing page at
  <https://macparakeet.com/agents> shipped alongside this submission.
- **Open source for ~1 month**: GPL-3.0 since 2026-03-25
  ([open-source announcement](https://macparakeet.com/blog/macparakeet-open-source/)).
- **Daily-driven by maintainer**: feature-complete for dictation,
  file transcription, and (in v0.6 in progress) meeting recording.
- **Multiple shipped releases**: Sparkle auto-updates from v0.1
  through current v0.5.7. Public appcast at
  <https://macparakeet.com/appcast.xml>.
- **Comprehensive documentation**: spec kernel in `spec/`, ADRs for
  locked architectural decisions, AGENTS.md at repo root, a
  semver-tracked CLI changelog at `Sources/CLI/CHANGELOG.md`.
- **Today**: cut `macparakeet-cli 1.0.0` (first versioned public
  surface), shipped a Homebrew tap with both formula and cask, and
  published [a launch blog post](https://macparakeet.com/blog/macparakeet-cli-1-0/)
  framing the CLI as the canonical Swift-native Parakeet wrapper for
  Apple Silicon AI agents.

The OpenClaw integration story (`integrations/openclaw/` scaffold) is
brand new — shipped in [PR #144](https://github.com/moona3k/macparakeet/pull/144)
on 2026-04-25 — so OpenClaw-specific outside usage is not yet
established. The underlying tool (`macparakeet-cli`) and the broader
project are the established surface this submission is asking you to
list.
```

### Checklist
- [x] I checked that this resource is not already listed.
- [x] I reviewed CONTRIBUTING.md formatting and A-Z ordering rules.
- [x] The resource is public and can be evaluated from the provided link.
- [x] If I am affiliated with the resource, I disclosed that above.

## Proposed entry (for editorial reference, in your format)

```
- [moona3k/macparakeet](https://github.com/moona3k/macparakeet) - Local Parakeet TDT speech-to-text on the Apple Neural Engine. Swift-native CLI for OpenClaw skills to shell out to: persistent SQLite memory, prompt library, stable JSON output. ~155x realtime, ~2.5% WER, ~66 MB per inference slot. macOS 14.2+ Apple Silicon, GPL-3.0. `brew install moona3k/tap/macparakeet-cli`. OpenClaw scaffold at [integrations/openclaw/](https://github.com/moona3k/macparakeet/tree/main/integrations/openclaw).
```

A-Z ordering note: in `## Plugins and Integrations`, entries are
alphabetical by repo path. `moona3k/macparakeet` would slot between
`m1heng/clawdbot-feishu` and `marshallrichards/ClawPhone`.

## Submission checklist

- [x] Brew tap live and `brew install moona3k/tap/macparakeet-cli` verified
- [x] Target section identified (Plugins and Integrations)
- [x] Issue template fields pre-filled
- [x] A-Z ordering location identified
- [x] Maintainer affiliation disclosure prepared
- [x] User has confirmed go-ahead
- [x] Issue opened via `Add Resource Request` template
- [x] Issue URL captured in this file
- [ ] (After approval) PR opened with the exact entry text
- [ ] PR URL captured in this file
