# Submission notes — `openclaw/clawhub`

> **Status:** **PROPOSAL.** ClawHub submission requires the OpenClaw
> CLI installed locally and a SKILL.md package; the submission flow
> is non-trivial and needs verification of the current SKILL.md
> frontmatter schema before attempting.

## What ClawHub actually is (corrected)

ClawHub is the **official skill registry for OpenClaw** at
<https://clawhub.ai>. Skills are submitted via the OpenClaw CLI:

```bash
clawhub skill publish <path-to-skill-dir>
```

Skills are packaged as a directory containing a `SKILL.md` file with
frontmatter metadata, plus supporting files. ClawHub renders the
SKILL.md content and indexes it for search.

## Critical correction: SKILL.md, not SOUL.md

When this work began, the handoff document conflated `SOUL.md` with
the OpenClaw skill format. **It is not.** Reconnaissance against the
ClawHub README confirms:

- **ClawHub uses `SKILL.md`** (with frontmatter metadata)
- **`SOUL.md` belongs to a different agent registry** (onlycrabs.ai)

The `integrations/openclaw/SOUL.md` file in the macparakeet repo was
therefore misnamed. **Resolved** in [PR #146](https://github.com/moona3k/macparakeet/pull/146)
(merged 2026-04-25): renamed to `integrations/openclaw/README.md`
for consistency with the Hermes-flavored entry point, and updated the
content to reference the SKILL.md format.

## What's needed to actually submit

1. **Install OpenClaw CLI** locally (`npm install -g openclaw` or per
   their canonical install path).
2. **Verify SKILL.md frontmatter spec** at <https://docs.openclaw.ai/tools/clawhub>
   — what fields are required (`name`, `version`, `author`, `tags`,
   `requires`, etc.) and what they validate against.
3. **Create a properly-formed skill package** — directory with
   `SKILL.md` (frontmatter + body), `install.sh` (installs the
   `macparakeet-cli` host binary), and possibly `examples/` with
   illustrative invocations.
4. **Run `clawhub skill publish <path>`** and capture the resulting
   ClawHub URL.

## Likely SKILL.md skeleton

```markdown
---
name: macparakeet-stt
version: 1.0.0
author: moona3k
description: Local Parakeet TDT speech-to-text for Apple Silicon. Wraps macparakeet-cli (GPL-3.0-or-later).
tags: [stt, transcription, voice, apple-silicon, local, parakeet]
requires:
  - platform: darwin
  - arch: arm64
  - macos: ">=14.2"
license: GPL-3.0-or-later
---

# macparakeet-stt

Local speech-to-text and transcription for an OpenClaw agent running
on Apple Silicon. Wraps `macparakeet-cli` so an OpenClaw skill can
transcribe local audio/video files, transcribe YouTube URLs, search
the user's prior dictation/transcription history, and run a prompt
against a transcription. All execution is local on the Apple Neural
Engine; no cloud STT.

## Install

```bash
brew install moona3k/tap/macparakeet-cli
```

## Capabilities

(table of capabilities → CLI invocations — see
`integrations/openclaw/` in the macparakeet repo for the canonical
list)

## Privacy

All STT runs on the ANE. No audio leaves the device. Optional cloud
LLM provider only when the user explicitly passes `--provider <cloud>`.
```

**This skeleton is illustrative.** The actual SKILL.md frontmatter
fields must be verified against the current OpenClaw documentation
before publishing.

## Why we're deferring

- **Untrusted schema**: SKILL.md frontmatter validation rules aren't
  fully documented here. Submitting an invalid manifest could be
  rejected — or worse, accepted in a degraded form that misrepresents
  the skill.
- **Untested install path**: The skill's `install.sh` wrapper around
  `brew install moona3k/tap/macparakeet-cli` needs to be tested in
  ClawHub's runtime environment.
- **Post-acquisition uncertainty**: OpenClaw was acquired by OpenAI
  in February 2026; the registry tooling and submission flow may
  evolve. Better to consult current docs immediately before
  publishing rather than relying on possibly-stale information.

## Recommended next action

When ready to pursue:

1. Read <https://docs.openclaw.ai/tools/clawhub> end-to-end.
2. Read `openclaw/clawhub`'s CONTRIBUTING.md.
3. Read `docs/quickstart.md` and `docs/cli.md` referenced in the
   ClawHub README.
4. Pick or build a sandbox environment to test `clawhub skill publish`
   before publishing to the live registry.
5. Confirm the `integrations/openclaw/README.md` scaffold still
   matches the verified ClawHub schema before publishing.

## Downstream dependency

`VoltAgent/awesome-openclaw-skills` only accepts entries for skills
already published in `github.com/openclaw/skills` (the ClawHub mirror
repo). So any submission to `awesome-openclaw-skills` depends on
this ClawHub publication succeeding first.

## Submission checklist (for the future)

- [x] Brew tap live and `brew install moona3k/tap/macparakeet-cli` verified
- [ ] OpenClaw CLI installed locally
- [ ] SKILL.md frontmatter schema verified against current docs
- [ ] Sandbox test of `clawhub skill publish` succeeded
- [x] `integrations/openclaw/SOUL.md` renamed or otherwise corrected (PR #146)
- [ ] User has confirmed go-ahead
- [ ] `clawhub skill publish` run for live registry
- [ ] ClawHub URL captured in this file
