---
name: macparakeet-stt
description: Use when the user asks to transcribe audio or video, search MacParakeet's local speech library, retrieve cited transcript segments or knowledge cards, or inspect and manage saved meeting artifacts on macOS Apple Silicon.
---

# MacParakeet STT

Use `macparakeet-cli`, not a second transcription implementation. Read the
[canonical integration guide](../../README.md) for command examples, installed
version differences, JSON/errors, privacy, and isolation. If packaging this
skill alone, use the [published guide](https://github.com/moona3k/macparakeet/blob/main/integrations/README.md)
and prefer the installed binary's contract when versions differ. Coding agents
modifying MacParakeet itself should use [AGENTS.md](../../../AGENTS.md).

## Discover before acting

```bash
macparakeet-cli --version
macparakeet-cli spec --json
macparakeet-cli health --json
```

Inspect catalog `jsonMode`, arguments/options, and `readOnly` before composing
a command. Treat `health` as a component report, not a universal pass/fail gate:
missing optional models do not block database retrieval. Without repair flags
the probe does not create directories, migrate the database, or download/repair.
For `database.status: schema_skew`, use a compatible newer CLI; never reset or
replace the user's database. Ask before any repair or model download.

## Retrieve evidence, then generate only when asked

- Use `cards list` to route across saved recordings, `search` for exact topics
  or phrases, and `transcript --around-seq` for cited context. Use `history
  search` separately for dictations.
- Cite the recording ID/title and segment sequence, adding timestamps when
  available. Verify card decisions/actions against transcript segments; cards
  are derived hints, not authoritative facts.
- Use `meetings show`/`transcript` for saved meeting reads. Treat `meetings
  artifact` as a write: it refreshes generated files from SQLite. Preserve
  user-authored notes; put generated results in `meetings results add` only
  when requested. An absent capture report means unknown; partial audio can
  still have a completed transcript.
- Do not call `cards generate`, prompts, or other LLM-backed operations unless
  the user requests generated output and has chosen a provider. Configured
  providers and CLI subprocesses may send text outside the Mac.

## Preserve data and parse the actual contract

- Branch on exit code first. Parse the documented JSON stdout mode; parse-time
  misuse can use plain stderr. Do not replay a write merely because its error
  appears transient: check for partial results first.
- Resolve ambiguity with a full UUID or a sufficiently specific identifier;
  never pick an arbitrary match for a write.
- Do not delete, clear, retranscribe, reindex, change shared defaults, enable
  hooks, or regenerate artifacts without authorization for that operation.
- Follow the guide's **Safe automation and isolation** section. `--database`
  does not isolate referenced files or shared preferences, and the DEBUG state
  root is ignored by release binaries. Do not run destructive smoke work on
  user state, including copied rows that still reference original artifacts.
- Keep keys in environment variables, not command-line literals. Use explicit
  per-run flags for reproducibility; `config set` changes shared app defaults.
  `--no-history` is not a no-I/O or no-network switch. Disable per-process CLI
  telemetry with `MACPARAKEET_TELEMETRY=0` when required; this does not disable
  media, model, provider, or other requested network operations.
