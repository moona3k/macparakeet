# MacParakeet for OpenClaw

A thin packaging entry point for an OpenClaw agent running on macOS 14.2+
with Apple Silicon. MacParakeet provides local speech recognition and access
to saved transcripts, meeting artifacts, and derived knowledge cards.

## Install and discover

```bash
brew install moona3k/tap/macparakeet-cli
macparakeet-cli --version
macparakeet-cli spec --json
macparakeet-cli health --json
```

An installed app also bundles the CLI at
`/Applications/MacParakeet.app/Contents/MacOS/macparakeet-cli`. Inspect that
binary's version and catalog rather than assuming it matches Homebrew or
this checkout's unreleased candidate. Model readiness and optional repairs
are covered by the canonical integration guide; do not download or change
shared defaults merely to initialize a skill.

## Package for ClawHub

- Adapt the existing [`macparakeet-stt` skill directory](../skill/macparakeet-stt/SKILL.md),
  rather than maintaining a second command catalog or prompt here.
- Use `SKILL.md` with frontmatter, not `SOUL.md`. Verify ClawHub's current
  [skill format](https://docs.openclaw.ai/clawhub/skill-format) and publishing
  instructions before registration; this repository does not pin an external
  registry manifest or publication command.
- Declare the macOS/Apple Silicon host requirement and `macparakeet-cli`
  executable dependency. The host binary is available through the
  [`moona3k/tap` Homebrew tap](https://github.com/moona3k/homebrew-tap).
- Preserve the skill's consent, evidence, privacy, and isolation guidance.
  Optional provider credentials are not prerequisites for local speech
  recognition or deterministic transcript retrieval.

## Canonical references

- [Integration guide](../README.md): command recipes, JSON/error handling,
  retrieval citations, shared-state boundaries, and network behavior.
- [Reusable agent skill](../skill/macparakeet-stt/SKILL.md): operating instructions.
- Installed `macparakeet-cli spec --json`: runtime command/option catalog.
- [CLI changelog](../../Sources/CLI/CHANGELOG.md): versioned compatibility.
- [Repository agent guide](../../AGENTS.md): source-development rules only.

## Status

Publication to ClawHub remains pending in this integration record; this
candidate documentation update does not establish registry publication.
Track packaging work under the repository's
[`integration` issues](https://github.com/moona3k/macparakeet/issues?q=is%3Aissue+label%3Aintegration).
