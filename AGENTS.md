# AGENTS.md -- MacParakeet

> Read by coding agents (Claude Code, Codex CLI, Hermes, OpenClaw, etc.) working
> *in this repo*. This is the single source of truth for how to work here; the
> spec under [`spec/`](./spec/) is the source of truth for product and
> architecture depth. (Claude Code imports this file from `CLAUDE.md`.)
> If your agent runs *outside* this repo and wants to *call* `macparakeet-cli`,
> see [`integrations/README.md`](./integrations/README.md) instead.

## What this project is

MacParakeet is a fast, private, local-first voice app for macOS. The v0.6
release has three co-equal capture modes: system-wide dictation, file
transcription, and meeting recording, plus productized Transforms on `main`
for selected-text rewrites. Parakeet TDT 0.6B v3 via FluidAudio CoreML on the
Apple Neural Engine is the default STT engine. WhisperKit is also available as
an optional local multilingual engine for languages Parakeet does not cover.

**Release status:** v0.6 ships system-wide dictation, file/URL transcription,
meeting recording, optional WhisperKit multilingual STT, and productized
Transforms on `main`. Calendar reminders and auto-start are
implemented and enabled on `main` (`AppFeatures.calendarEnabled = true`);
calendar auto-start defaults to mode `.off`, so it is strictly opt-in. Calendar-
driven auto-stop was removed (ADR-017 amendment) — recordings stop manually.

Free and open-source (GPL-3.0). Apple Silicon only. Requires macOS 14.2+.

The repo ships two products:

- **`macparakeet-cli`** -- versioned public surface
  ([`Sources/CLI/`](./Sources/CLI/), semver tracked in
  [`Sources/CLI/CHANGELOG.md`](./Sources/CLI/CHANGELOG.md)). Treat external-
  facing commands as a stable contract — update the CHANGELOG for any
  compatibility-relevant change.
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
- `MacParakeetCore` has no SwiftUI/view dependencies. It is primarily
  Foundation + GRDB + FluidAudio + optional WhisperKit, with small
  AppKit-backed macOS adapter services where no Foundation-only API exists
  (`ClipboardService`, `PermissionService`, `TelemetryService` termination
  notification, `ExportService`). New AppKit use in Core should stay
  adapter-shaped and must not introduce UI ownership.
- ViewModels live in their own SPM target (`Sources/MacParakeetViewModels/`)
  so they can be tested without the GUI.
- Async/await for all I/O. No completion handlers, no Combine in new code.
- Buttons use `.parakeetAction(.primary / .primaryProminent / .secondary / .destructive / .destructiveProminent / .subtle)` for semantic role + styling. Never apply `.tint(coral)` at NSHostingView roots or sheet wrappers — coral cascades only from `parakeetAction`. See `spec/04-ui-patterns.md` → Buttons.

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
[`spec/adr/`](./spec/adr/). Don't second-guess ADRs. When code and spec
disagree, the higher-precedence source wins: ADR > narrative spec > active plan
> kernel index > code/comments (see
[`spec/10-ai-coding-method.md`](./spec/10-ai-coding-method.md)).

**Subsystem READMEs.** Load-bearing folders inside
[`Sources/MacParakeetCore/`](./Sources/MacParakeetCore/) carry their own
`README.md` capturing non-obvious rules (threading, ordering,
retention) that aren't visible from grep. **When you're about to edit
inside one of these folders, read its README first.** Folders with
READMEs today: `Audio/`, `STT/`, `TextProcessing/`, `Database/`,
`Licensing/`.

## Gotchas That Have Bitten Us

Cross-cutting traps. Subsystem-specific ones live in the subsystem READMEs
(e.g. the GRDB UUID-lookup trap is in `Database/README.md`); release/signing
ones are in [`docs/distribution.md`](./docs/distribution.md).

**Swift**

- `??` with `try await` does not compile — the right-hand side is an autoclosure
  that can't be async/throwing. Use `if let … else`, not `x ?? (try await …)`.
- Fire-and-forget `Task { try await … }` inside a sync function silently drops
  the result. If the caller needs the value, make the function `async` and
  `await` directly.
- `UTType(filenameExtension:)` returns nil for unregistered extensions — never
  force-unwrap it.
- `nonisolated` + an existential (`any Protocol`) stored property conflict.
  Changing a concrete stored type to `any Protocol` breaks `nonisolated` access;
  drop `nonisolated` or keep the concrete type.

**AppKit / SwiftUI**

- Don't block `@MainActor` with long work — do heavy work in `Task.detached` and
  hop back to MainActor only for UI updates.
- Non-activating `NSPanel`s (idle pill, dictation overlay) ignore `.help()`,
  `.onHover`, and SwiftUI tooltips — only an AppKit `NSTrackingArea` with
  `.activeAlways` works. SwiftUI `.popover` inside a `KeylessPanel` clips, steals
  focus, and mis-routes keys; use an in-view ZStack overlay + `.onKeyPress`.
- Segmented `Picker` needs `.labelsHidden()` or it prints its label; 5+ segments
  truncate at sidebar widths — use short segment titles.
- A `Timer` driving UI that must keep ticking during slider drags / menu
  tracking has to be added in `.common` run-loop mode; `.default` pauses during
  tracking.

**Other**

- `PermissionService` is not a singleton — instantiate `PermissionService()`,
  there is no `.shared`.
- When you switch implementation approaches, delete the old path entirely — no
  `_ = unusedVar` artifacts or commented-out blocks.

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
- **Meeting recovery artifacts are user data.** Meeting session folders, lock
  files, and source audio must not be deleted outside the recovery/discard flows
  without explicit user intent.

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

- **Project depth:** the spec index at [`spec/README.md`](./spec/README.md) for
  product and architecture; [`spec/10-ai-coding-method.md`](./spec/10-ai-coding-method.md)
  for spec precedence and lightweight kernel usage; ADRs in
  [`spec/adr/`](./spec/adr/) for locked decisions.
- **Calling macparakeet-cli from another agent (OpenClaw / Hermes / etc.):**
  [`integrations/README.md`](./integrations/README.md) and the CLI changelog
  at [`Sources/CLI/CHANGELOG.md`](./Sources/CLI/CHANGELOG.md).
- **Commit format:** rich-format messages per
  [`docs/commit-guidelines.md`](./docs/commit-guidelines.md) for significant
  changes.
- **Other references:** [`docs/distribution.md`](./docs/distribution.md)
  (signing, notarization, Sparkle), [`docs/telemetry.md`](./docs/telemetry.md)
  (opt-out anonymous telemetry), [`docs/cli-testing.md`](./docs/cli-testing.md)
  (headless verification loop), [`docs/audits/`](./docs/audits/) (codebase
  audits), [`docs/brand-identity.md`](./docs/brand-identity.md) +
  [`brand-assets/README.md`](./brand-assets/README.md) (brand).
