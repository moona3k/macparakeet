# Submission draft — `0xNyk/awesome-hermes-agent`

> **Status:** ✅ submitted as issue [#49](https://github.com/0xNyk/awesome-hermes-agent/issues/49) on 2026-04-25. Awaiting maintainer review.

## Submission flow (per their CONTRIBUTING.md)

> *"Please do not open a PR directly to add a resource. All additions
> are reviewed and added by maintainers to ensure consistent quality
> and editorial voice."*

So: **open an issue**, not a PR. No issue template is published; the
CONTRIBUTING.md spells out the required fields.

## Required fields (from CONTRIBUTING.md)

- Resource name and URL
- Author (GitHub username)
- Brief description
- Category it fits into
- Why it's awesome

## Section to target

**`Tools & Utilities`** — the section description reads *"Applications,
CLIs, and utilities built on top of or alongside Hermes Agent."* That
fits `macparakeet-cli` exactly: it's a CLI that Hermes skills shell
out to. (Not a Hermes skill itself; the scaffold for that lives at
`integrations/hermes/README.md`.)

## Maturity tag

**`stable`** — `macparakeet-cli 1.0.0` ships with a written semver
compatibility policy, brew distribution, signed + notarized binary,
and is the maintainer's daily driver.

## Proposed entry (matching their format precisely)

The list's entry format, observed verbatim:

```
*   **[stable]** [macparakeet-cli](https://github.com/moona3k/macparakeet) by [moona3k](https://github.com/moona3k) - Local Parakeet TDT speech-to-text on the Apple Neural Engine — ~155x realtime, ~2.5% WER, ~66 MB per inference slot. Swift-native CLI for Hermes skills to shell out to: persistent SQLite memory, prompt library, stable JSON output (`--json` everywhere). macOS 14.2+ Apple Silicon, GPL-3.0. Install: `brew install moona3k/tap/macparakeet-cli`. Hermes scaffold at [`integrations/hermes/`](https://github.com/moona3k/macparakeet/tree/main/integrations/hermes).
```

## Issue title

```
Suggest: macparakeet-cli — local Parakeet STT on Apple Silicon (Tools & Utilities)
```

## Issue body

````markdown
**Resource name:** `macparakeet-cli`
**URL:** <https://github.com/moona3k/macparakeet>
**Author:** [@moona3k](https://github.com/moona3k) (Daniel Moon — maintainer)
**Suggested category:** Tools & Utilities
**Suggested maturity tag:** `stable`

## Brief description

Local Parakeet TDT speech-to-text running on the Apple Neural Engine
via FluidAudio. Swift-native CLI for Hermes skills to shell out to,
with a persistent SQLite memory layer, a prompt library, and stable
JSON output on every read-only command.

## Why it's awesome

Voice/STT is the documented gap in the Hermes-on-Mac-mini stack
today: Whisper.cpp doesn't use the Neural Engine and is measurably
slower; the OpenAI Whisper API breaks the local-first posture and
costs per minute; `parakeet-mlx` (Python) doesn't carry a memory
layer or prompt library. `macparakeet-cli` fills that slot.

For a Hermes skill author specifically:
- Stable JSON output (`--json` on every read-only command) with
  ISO-8601 datetimes, sorted keys, top-level array for lists.
- UUID-or-name lookup with `.notFound` / `.ambiguous` error classes.
- Exit codes: 0 success, non-zero failure, errors to stderr only.
- Persistent SQLite at `~/Library/Application Support/MacParakeet/macparakeet.db`
  — a Hermes skill can recall prior dictations / transcriptions /
  prompt outputs across sessions.
- All execution local on the ANE. Optional cloud LLM provider only
  when the agent passes `--provider <cloud>`.

## Why now

- **Versioning event today**: `macparakeet-cli 1.0.0` ships with a
  written compatibility policy ([`Sources/CLI/CHANGELOG.md`](https://github.com/moona3k/macparakeet/blob/main/Sources/CLI/CHANGELOG.md))
  and stable JSON schemas. Skill authors can finally rely on the
  surface.
- **Brew tap live**: `brew install moona3k/tap/macparakeet-cli`.
- **Hermes scaffold**: [`integrations/hermes/`](https://github.com/moona3k/macparakeet/tree/main/integrations/hermes)
  has an illustrative skill-manifest sketch with `when_to_use`
  triggers and command bindings.
- **Persona-framed landing**: <https://macparakeet.com/agents>.

## Quality checklist (per CONTRIBUTING.md)

- **Relevant** — directly addresses the Hermes-on-Mac-mini voice gap.
- **Documented** — full README, AGENTS.md, integrations docs,
  semver-tracked CHANGELOG.
- **Functional** — daily-driven by maintainer; signed + notarized;
  brew install verified end-to-end.
- **Not a duplicate** — no other local-Parakeet-CLI entries on the list.
- **Open source** — GPL-3.0, full source at the linked repo.
- **Maintained** — active development, multiple shipped releases.
- **Why now** — see "Why now" section above.

## Suggested entry (in your format, for editorial reference)

```
*   **[stable]** [macparakeet-cli](https://github.com/moona3k/macparakeet) by [moona3k](https://github.com/moona3k) - Local Parakeet TDT speech-to-text on the Apple Neural Engine — ~155x realtime, ~2.5% WER, ~66 MB per inference slot. Swift-native CLI for Hermes skills to shell out to: persistent SQLite memory, prompt library, stable JSON output (`--json` everywhere). macOS 14.2+ Apple Silicon, GPL-3.0. Install: `brew install moona3k/tap/macparakeet-cli`. Hermes scaffold at [`integrations/hermes/`](https://github.com/moona3k/macparakeet/tree/main/integrations/hermes).
```

## Maintainer disclosure

I am the maintainer of MacParakeet (Daniel Moon, @moona3k).
````

## Submission checklist

- [x] Brew tap live and `brew install moona3k/tap/macparakeet-cli` verified
- [x] Target section identified (Tools & Utilities)
- [x] Entry shape matches existing entries
- [x] Quality criteria addressed (per CONTRIBUTING)
- [x] Maintainer affiliation disclosed
- [x] User has confirmed go-ahead
- [x] Issue opened against `0xNyk/awesome-hermes-agent`
- [x] Issue URL captured in this file
