# MacParakeet skill for Hermes Agent

A thin packaging entry point for Hermes Agent on macOS 14.2+ with Apple
Silicon. MacParakeet provides local speech recognition, saved-transcript and
meeting retrieval, and optional prompt automation; local retrieval does not
require an LLM provider.

## Install and discover

```bash
brew install moona3k/tap/macparakeet-cli
macparakeet-cli --version
macparakeet-cli spec --json
macparakeet-cli health --json
```

An installed app also bundles the CLI at
`/Applications/MacParakeet.app/Contents/MacOS/macparakeet-cli`. Use the
installed binary's catalog and health component statuses; do not assume it
matches this checkout's unreleased candidate or automatically repair missing
optional components.

## Package for Hermes

- Adapt the existing [`macparakeet-stt` skill directory](../skill/macparakeet-stt/SKILL.md)
  instead of maintaining another YAML command catalog or prompt sketch.
- Verify the current Hermes skill format and `awesome-hermes-agent`
  submission requirements at registration time. This entry point does not
  claim a registry-specific manifest is validated.
- Declare the macOS/Apple Silicon host requirement and `macparakeet-cli`
  executable dependency. The Homebrew tap installs the host binary and its
  media-helper dependencies; speech-model setup is described in the canonical
  guide.
- Keep the skill's explicit authorization rules for writes, generated output,
  provider use, and shared preferences. Do not treat `--database` or
  `--no-history` as a complete sandbox.

## Canonical references

- [Integration guide](../README.md): command recipes, JSON/error handling,
  retrieval citations, isolation, and privacy/network boundaries.
- [Reusable agent skill](../skill/macparakeet-stt/SKILL.md): operating instructions.
- Installed `macparakeet-cli spec --json`: runtime command/option catalog.
- [CLI changelog](../../Sources/CLI/CHANGELOG.md): versioned compatibility.
- [Repository agent guide](../../AGENTS.md): source-development rules only.

## Status

This integration record notes a submission to `awesome-hermes-agent`, not
verified acceptance or installation in the current registry. Track packaging
work under the repository's
[`integration` issues](https://github.com/moona3k/macparakeet/issues?q=is%3Aissue+label%3Aintegration).
