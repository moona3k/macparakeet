# AGENTS.md -- MacParakeet

> Read by coding agents (Claude Code, Codex CLI, Hermes, OpenClaw, etc.) working
> *in this repo*. Deeper project context lives in [`CLAUDE.md`](./CLAUDE.md).
> If your agent runs *outside* this repo and wants to *call* `macparakeet-cli`,
> see [`integrations/README.md`](./integrations/README.md) instead.

## What this project is

MacParakeet is a fast, private, local-first voice app for macOS. Stable
releases focus on system-wide dictation and file transcription; the `main`
branch product direction has three co-equal modes: system-wide dictation, file
transcription, and meeting recording. Parakeet TDT 0.6B v3 via FluidAudio
CoreML on the Apple Neural Engine is the default STT engine. WhisperKit is also
available on `main` as an optional local multilingual engine for languages
Parakeet does not cover.

**Release status:** the public DMG is the stable channel and currently ships
dictation + file/URL transcription. Meeting recording and WhisperKit
multilingual STT are Labs/Beta features implemented on `main`, under active
testing, and not in the current public DMG yet.

Free and open-source (GPL-3.0). Apple Silicon only. Requires macOS 14.2+.

The repo ships two products:

- **`macparakeet-cli`** -- versioned public surface
  ([`Sources/CLI/`](./Sources/CLI/), semver tracked in
  [`Sources/CLI/CHANGELOG.md`](./Sources/CLI/CHANGELOG.md)).
- **`MacParakeet.app`** -- SwiftUI macOS app, one consumer of the CLI's
  underlying core library.

## Build & Test

```bash
# Build everything (app + CLI + core + viewmodels + tests)
swift build

# Run the test suite (Swift 6 language mode)
swift test

# Build, codesign, and launch the dev app
scripts/dev/run_app.sh

# Run the CLI against your local DB
swift run macparakeet-cli --help
swift run macparakeet-cli health
```

The full test suite is deterministic and normally finishes in roughly one to
two minutes depending on SwiftPM cache state. Run `swift test` before declaring
code-change work complete.

## Code Style

- Swift 6.0 with SwiftUI for UI and GRDB for SQLite.
- One repository per database table (see
  [`Sources/MacParakeetCore/Database/`](./Sources/MacParakeetCore/Database/)).
- Comments explain *why*, not *what* -- well-named identifiers carry the what.
  Default to writing none.
- `MacParakeetCore` has no UI dependencies (Foundation + GRDB + FluidAudio,
  with optional WhisperKit). One exception: `ExportService` imports AppKit for
  PDF/DOCX. No new AppKit imports in Core.
- ViewModels live in their own SPM target (`Sources/MacParakeetViewModels/`)
  so they can be tested without the GUI.
- Async/await for all I/O. No completion handlers, no Combine in new code.

## Architecture Orientation

```
Sources/
  MacParakeetCore/        -- Pure Swift library: STT, DB, prompts, LLM, audio
  MacParakeetViewModels/  -- @Observable view models, no UI
  MacParakeet/            -- SwiftUI app target
  CLI/                    -- macparakeet-cli; ArgumentParser commands
Tests/
  MacParakeetTests/       -- Unit, database, integration tests
  CLITests/               -- CLI argument-parsing + helper tests
```

Full spec is in [`spec/`](./spec/). Architectural decisions (locked) are in
[`spec/adr/`](./spec/adr/). Don't second-guess ADRs.

## Security & Privacy

- **Local-first speech.** STT runs on the Apple Neural Engine. Audio and
  transcripts stay on-device for core dictation, transcription, and meeting
  recording. Network surfaces are limited to user-triggered LLM providers,
  media downloads, model/update flows, retained purchase activation endpoints
  if explicitly invoked, and opt-out self-hosted telemetry/crash reporting.
  Telemetry never includes audio or transcript content.
- **Retained purchase activation is intentional.** The old
  LemonSqueezy/trial entitlement code is dormant in current free/GPL builds,
  but it is deliberate future-option plumbing. Do not delete or "clean up"
  `EntitlementsService`, `LemonSqueezyLicenseAPI`, entitlement state, or
  trial/license telemetry as dead code unless explicitly requested by the
  project owner and reflected in an ADR/spec update.
- **No accounts, no logins.** No identifying data is sent anywhere.
- **The user database lives at**
  `~/Library/Application Support/MacParakeet/macparakeet.db`. Treat it as user
  data: never delete without explicit user confirmation; write migrations
  rather than dropping tables.

## Important Runtime Locations

| Item | Path |
|------|------|
| App bundle | `/Applications/MacParakeet.app` |
| Database | `~/Library/Application Support/MacParakeet/macparakeet.db` |
| Parakeet CoreML STT models (~6 GB) | FluidAudio default cache |
| WhisperKit STT models | `~/Library/Application Support/MacParakeet/models/stt/whisper/` |
| Settings | `~/Library/Preferences/com.macparakeet.plist` |
| Logs | `~/Library/Logs/MacParakeet/` |

## Where to Look Next

- **Coding-agent context for this repo:** [`CLAUDE.md`](./CLAUDE.md) for deep
  project context; [`spec/10-ai-coding-method.md`](./spec/10-ai-coding-method.md)
  for the kernel workflow; ADRs in [`spec/adr/`](./spec/adr/) for locked
  decisions.
- **Calling macparakeet-cli from another agent (OpenClaw / Hermes / etc.):**
  [`integrations/README.md`](./integrations/README.md) and the CLI changelog
  at [`Sources/CLI/CHANGELOG.md`](./Sources/CLI/CHANGELOG.md).
- **Commit format:** rich-format messages per
  [`docs/commit-guidelines.md`](./docs/commit-guidelines.md) for significant
  changes.
