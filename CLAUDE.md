# CLAUDE.md

> Context for AI coding assistants working on MacParakeet.

## What is MacParakeet?

A **fast, private, local-first voice app** for macOS with three co-equal modes: system-wide dictation, file transcription, and meeting recording. Powered by NVIDIA's Parakeet TDT via FluidAudio CoreML on the Neural Engine.

**North Star:** Fast, local-first voice app for Mac.

**Domain:** [macparakeet.com](https://macparakeet.com)

**Pricing:** Free and open-source (GPL-3.0)

## Quick Navigation

| Need | Go To |
|------|-------|
| What are we building? | `spec/README.md` -> spec index and roadmap |
| Product vision | `spec/00-vision.md` |
| Data model | `spec/01-data-model.md` |
| Feature details | `spec/02-features.md` |
| Architecture | `spec/03-architecture.md` |
| UI patterns | `spec/04-ui-patterns.md` |
| Audio pipeline | `spec/05-audio-pipeline.md` |
| STT engine | `spec/06-stt-engine.md` |
| Text processing | `spec/07-text-processing.md` |
| Error handling | `spec/08-error-handling.md` |
| Testing strategy | `spec/09-testing.md` |
| AI coding methodology | `spec/10-ai-coding-method.md` |
| LLM integration | `spec/11-llm-integration.md` |
| Processing layer (prompts, actions, workflows) | `spec/12-processing-layer.md` |
| ADRs (locked decisions) | `spec/adr/` -> individual decision records |
| CLI testing guide | `docs/cli-testing.md` |
| Brand identity | `docs/brand-identity.md` |
| UI/UX design overhaul | `docs/design-overhaul.md` |
| Distribution, signing & auto-updates | `docs/distribution.md` |
| Telemetry system | `docs/telemetry.md` |
| Commit message format | `docs/commit-guidelines.md` |
| Implementation plans | `plans/` -> active and completed plans |

## Tech Stack (Locked Decisions)

| Layer | Choice | Notes |
|-------|--------|-------|
| Platform | macOS 14.2+ | Apple Silicon only |
| Language | Swift 6.0 | SwiftUI for UI |
| Database | SQLite | GRDB (single file, dictation history + transcriptions + meeting recordings) |
| STT | Parakeet TDT 0.6B-v3 | Via FluidAudio CoreML/ANE (~2.5% WER, 155x realtime, 25 European languages) |
| Audio | AVAudioEngine + Core Audio + Core Audio Taps | Mic capture for dictation; Core Audio Taps for system audio (meeting recording); FFmpeg (bundled) for video file conversion |
| YouTube | yt-dlp | Standalone macOS binary, weekly non-blocking auto-update via `--update` |
| Auto-Update | Sparkle 2 | In-app updates via EdDSA-signed appcast (non-App Store) |

## Product Context

MacParakeet is extracted from the OatFlow feature in Oatmeal but is maintained independently -- no shared packages, no monorepo dependencies.

| | MacParakeet | Oatmeal |
|---|-------------|---------|
| **Focus** | Voice dictation + file transcription + meeting recording | Meeting memory + calendar |
| **Complexity** | Simple, focused | Complex, powerful |
| **Pricing** | Free (GPL-3.0) | Freemium + Pro |
| **Value prop** | "Fast local transcription" | "Remembers everything" |

## Product Decisions (Settled)

These decisions were made during spec review and are locked:

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Empty transcript UX | Silently dismiss | Short hold-to-talk with no speech = user changed their mind. No error card. |
| Audio retention | On/off toggle | Simpler than 3-tier (all/7d/never). Users who care about storage can manually delete. |
| Processing mode scope | Global default only | Set once in Vocabulary, applies to all dictations. No per-dictation picker on overlay. |
| Context awareness | Aspirational future | No version commitment. Don't promise what doesn't exist. Build post-launch. |

## Architecture Decisions (ADRs)

All ADRs are in `spec/adr/`. These are locked decisions -- don't second-guess them.

| ADR | Decision | File |
|-----|----------|------|
| ADR-001 | Parakeet TDT 0.6B-v3 as primary STT | `spec/adr/001-parakeet-stt.md` |
| ADR-002 | Local-first processing (amended: opt-in LLM providers, telemetry) | `spec/adr/002-local-only.md` |
| ADR-004 | Deterministic text processing pipeline | `spec/adr/004-deterministic-pipeline.md` |
| ADR-005 | First-run onboarding flow | `spec/adr/005-onboarding-first-run.md` |
| ADR-007 | FluidAudio CoreML migration (Python elimination) | `spec/adr/007-fluidaudio-coreml-migration.md` |
| ADR-009 | Custom hotkey support (any single key + chord combos) | `spec/adr/009-custom-hotkey.md` |
| ADR-010 | Speaker diarization via FluidAudio offline pipeline | `spec/adr/010-speaker-diarization.md` |
| ADR-011 | LLM via cloud API keys + optional local providers | `spec/adr/011-llm-cloud-and-local-providers.md` |
| ADR-012 | Self-hosted telemetry via Cloudflare (Worker + D1) | `spec/adr/012-telemetry-system.md` |
| ADR-013 | Prompt Library + multi-summary architecture | `spec/adr/013-prompt-library-multi-summary.md` |
| ADR-014 | Meeting recording via Core Audio Taps | `spec/adr/014-meeting-recording.md` |
| ADR-015 | Concurrent dictation and meeting recording | `spec/adr/015-concurrent-dictation-meeting.md` |
| ADR-016 | Centralized STT runtime and scheduler | `spec/adr/016-centralized-stt-runtime-scheduler.md` |

> Historical ADRs (still in `spec/adr/`, kept for context): ADR-003 (one-time purchase pricing), ADR-006 (trial + license activation), ADR-008 (local LLM runtime). The app is now free/GPL-3.0.

## Current Phase

**v0.6 In Progress** -- ~166 source files, ~87 test files, 1268 tests passing (`swift test` green)

- **v0.1** MVP -- System-wide dictation, file transcription, overlay, history, export, SQLite, CLI, STT engine
- **v0.2** Clean Pipeline -- Text processing (filler removal, custom words, snippets), Vocabulary UI, feedback form
- **v0.3** YouTube & Export -- YouTube URL transcription, DOCX/PDF/JSON export, drag-and-drop enhancements
- **v0.4** Polish + Launch -- Diarization, custom hotkeys, Sparkle updates, LLM providers, voice stats, distribution
- **v0.5** Data, UI & Prompts -- Private dictation, multi-conversation chat, favorites, video player, split-pane detail, library grid, prompt library, multi-summary, open-source release
- **v0.6** Meeting Recording (in progress) -- System audio + mic capture via Core Audio Taps, concurrent with dictation (ADR-015), centralized STT runtime + scheduler (ADR-016), sacred-geometry recording pill + meeting panel, library integration, prompt/summary/chat support (ADR-014)

## Key Patterns

### Three Co-Equal Modes

MacParakeet has three primary modes that are equal in importance:

1. **System-wide dictation** -- Press hotkey anywhere on macOS, speak, text is pasted (WisprFlow-style)
2. **File transcription** -- Drag-drop audio/video files for full transcription (MacWhisper-style)
3. **Meeting recording** -- Capture system audio + mic simultaneously, transcribe locally (simple Granola-style)

All three modes share the same Parakeet STT backend but have different UI flows, audio sources, and data models. **Dictation and meeting recording run concurrently** (ADR-015) -- a user can dictate freely during a meeting recording. Each flow owns its own AVAudioEngine; macOS HAL handles mic multiplexing. All STT work routes through one process-wide runtime and scheduler (ADR-016), with dictation prioritized over meeting live preview and batch file work.

### STT Integration (Parakeet via FluidAudio)

- Native Swift SDK via FluidAudio (CoreML on the Neural Engine)
- Parakeet TDT 0.6B-v3 returns word-level timestamps + confidence scores
- ~155x realtime on Apple Silicon (60 min audio in ~23 seconds)
- ~2.5% Word Error Rate
- ~66 MB working memory during inference (vs ~2 GB+ on GPU/MLX)
- ~6 GB CoreML model bundle downloaded during onboarding
- One process-wide STT runtime owns `AsrManager`
- One scheduler owns priorities, backpressure, and job-scoped progress

**Swift API:**
```swift
let models = try await AsrModels.downloadAndLoad(version: .v3)
let manager = AsrManager(config: .default)
try await manager.initialize(models: models)

let result = try await manager.transcribe(audioSamples, source: .system)
// result.text contains the transcription
// result.words contains word-level timestamps + confidence
```

**Two-chip architecture:**
```
CPU:  MacParakeet app (UI, hotkeys, clipboard, history)
ANE:  Parakeet STT (via FluidAudio/CoreML) -- dedicated ML chip
```

### Database

- `macparakeet.db` (GRDB): Dictation history + transcription records in a single file
- No vector search or embeddings needed (unlike Oatmeal)
- One repository per table (GRDB pattern)

### Audio Capture

- **Dictation**: AVAudioEngine tap on input node (microphone)
- **File transcription**: FluidAudio's `AudioConverter` resamples audio; FFmpeg (bundled) demuxes video files
- **Meeting recording**: Core Audio Taps for system audio + AVAudioEngine for mic (dual-stream, ported from Oatmeal)

### GUI Structure

MacParakeet is a **menu bar app** with these UI surfaces:

```
Menu Bar Icon (always visible)
    |
    +-- Main Window (file transcription)
    |   +-- Drop zone / file browser
    |   +-- Transcript display
    |   +-- Export controls
    |   +-- Recent transcriptions list
    |
    +-- Idle Pill (persistent floating indicator)
    |   +-- Always visible when not dictating
    |   +-- Click or hover to start dictating
    |   +-- Hides during active dictation
    |
    +-- Dictation Overlay (compact dark pill)
    |   +-- Recording state indicator
    |   +-- Waveform visualization
    |   +-- Cancel/stop controls
    |
    +-- Vocabulary Panel
    |   +-- Processing mode (raw/clean)
    |   +-- Pipeline guide + tips
    |   +-- Custom words management (sheet)
    |   +-- Text snippets management (sheet)
    |
    +-- Feedback Panel
    |   +-- Category selection (bug report, feature request, other)
    |   +-- Message form with optional email + screenshot
    |
    +-- Settings Window
    |   +-- Hotkey configuration
    |   +-- LLM provider settings
    |   +-- Storage management
    |   +-- Permissions
    |   +-- Auto-update preferences
    |
    +-- Meetings Panel
    |   +-- Start Meeting Recording button
    |   +-- Past meeting recordings list
    |
    +-- Meeting Recording Pill (floating indicator)
    |   +-- Red dot + elapsed timer
    |   +-- Stop button
    |   +-- Transcribing state
    |
    +-- Library Panel
    |   +-- Transcription thumbnail grid
    |   +-- Filter bar (All/YouTube/Local/Meetings/Favorites)
    |   +-- Search and sort
    |
    +-- History Panel
        +-- Dictation history with search
        +-- Audio playback
        +-- Re-copy / re-process
```

View files organized by feature in `Sources/MacParakeet/Views/`:
- `Transcription/` -- Main window, drop zone, transcript display, export
- `Dictation/` -- Overlay, waveform, recording state
- `MeetingRecording/` -- Meeting recording pill, meetings view, dual audio levels
- `Discover/` -- Discover sidebar, curated content cards
- `Vocabulary/` -- Processing mode, custom words, text snippets
- `Feedback/` -- Feedback form, category selection, community link
- `Onboarding/` -- First-run onboarding flow
- `Settings/` -- Hotkey, LLM providers, storage, permissions
- `History/` -- Dictation history, search, playback
- `Components/` -- Reusable components (status badge, waveform view)

## Folder Structure

```
macparakeet/
├── CLAUDE.md           # This file (AI assistant context)
├── README.md           # Public-facing readme
├── Package.swift       # Swift package manifest
├── spec/               # THE SPEC (authoritative, prescriptive)
│   ├── README.md       # Spec index + roadmap
│   ├── 00-vision.md through 12-processing-layer.md
│   └── adr/            # Architecture Decision Records (locked)
├── docs/               # Research, explorations (informative)
│   ├── brand-identity.md   # Logo, colors, typography, brand voice
│   ├── cli-testing.md      # CLI testing guide
│   ├── commit-guidelines.md # Rich commit message format
│   ├── design-overhaul.md  # UI/UX redesign spec (warm magical direction)
│   ├── distribution.md     # Signing, notarization, auto-updates (Sparkle)
│   ├── telemetry.md        # Telemetry system
│   └── research/           # Deep dives on competitors, user sentiment
├── plans/              # Implementation plans (version controlled)
│   ├── active/         # Currently being implemented
│   └── completed/      # Done plans (archived, not deleted)
├── Sources/
│   ├── MacParakeet/            # GUI app (SwiftUI, imports MacParakeetCore + ViewModels)
│   ├── CLI/                    # CLI tool (ArgumentParser, imports MacParakeetCore)
│   ├── MacParakeetCore/        # Shared library (no UI deps)
│   └── MacParakeetViewModels/  # ViewModels (testable, depends on Core)
├── Tests/
│   └── MacParakeetTests/   # Unit, database, and integration tests
├── Assets/             # App icon (.icns + source PNG) and SVG logos
└── scripts/            # Build, test, and release scripts
```

### Related Repos

- [macparakeet-website](https://github.com/moona3k/macparakeet-website) -- Marketing website (Astro + Tailwind), macparakeet.com
- [macparakeet-community](https://github.com/moona3k/macparakeet-community) -- Archived; all issues now on moona3k/macparakeet
- [oatmeal](https://github.com/moona3k/oatmeal) -- Sibling product (meeting memory app); some meeting audio capture code was ported and adapted into MacParakeet

### Feedback & Community

In-app feedback creates GitHub Issues via a Cloudflare Pages Function. User emails are **never** posted in public issues.

**Responding to issues:**
- Be concise, genuine, no fluff
- If a feature request is already shipped, say so and close the issue
- If partially addressed, explain what's done and what's still open
- Cross-reference related issues

## Implementation Guidelines

1. **Specs are the source of truth** -- Follow `spec/10-ai-coding-method.md` precedence: kernel artifacts (`spec/kernel/*`) first, then ADRs, then narrative docs. If code and spec disagree, update code to match the highest-precedence spec (or update the spec if it is wrong).
2. **ADRs are locked** -- Don't second-guess architectural decisions in `spec/adr/`.
3. **Never lose user data** -- Graceful degradation for dictation history and transcriptions.
4. **UI philosophy** -- Minimal during dictation, rich for transcription results.
5. **Local-first** -- Speech recognition stays on-device by default. Optional network surfaces only run when the user enables or triggers them (for example YouTube downloads, telemetry, licensing, updates, or optional provider flows).
6. **Simplicity is the product** -- Resist feature creep. MacParakeet does three things well.
7. **Fast feedback loops for agents** -- Design everything so the agent can verify its own work: tests for logic, CLI for headless smoke-testing, build errors that surface immediately.
8. **Bounded agent discretion** -- Agents should choose the simplest process that works, but behavior changes must follow `spec/10-ai-coding-method.md` kernel workflow.
9. **Protect the context zone** -- For behavior changes, explicitly define in-scope requirements, out-of-scope behavior, and invariants before coding.

## Documentation Hygiene

**Keep docs aligned with code.** Stale documentation is worse than no documentation.

After completing work: update spec progress in `spec/README.md` and `spec/02-features.md`, update test counts in `README.md` and this file, archive completed plans to `plans/completed/`, mark outdated docs with `> Status: **HISTORICAL**` header.

Document status headers: `**ACTIVE**` (authoritative), `**IMPLEMENTED**` (done, still accurate), `**HISTORICAL**` (superseded), `**PROPOSAL**` (under discussion).

Source-of-truth precedence: kernel > ADR > narrative spec > code/comments.

## Working with Plans

Plans live in `plans/` and are version-controlled. Create a plan for multi-file changes, new features, architectural changes, or complex refactoring. Skip plans for bug fixes, typos, single-file changes. See existing plans in `plans/completed/` for format examples.

## Common Tasks

### Add a new feature

1. Read relevant spec (e.g., `spec/02-features.md`) and `spec/10-ai-coding-method.md`
2. Identify requirement IDs (or add them in `spec/kernel/requirements.yaml`)
3. Create a plan in `plans/active/` if multi-file
4. Implement in `Sources/MacParakeetCore/` (logic) and `Sources/MacParakeet/` (UI)
5. Add/update tests in `Tests/MacParakeetTests/` mapped to requirement IDs
6. Update `spec/kernel/traceability.md`
7. Run focused tests, then `swift test` before merge
8. Update spec progress markers

### Add a new database table

1. Update `spec/01-data-model.md` with schema
2. Add migration in `Sources/MacParakeetCore/Database/DatabaseManager.swift` (inline migrations)
3. Add model in `Sources/MacParakeetCore/Models/`
4. Add repository in `Sources/MacParakeetCore/Database/{Name}Repository.swift`
5. Run `swift test` to verify migrations

### Fix a bug

1. Write a test that reproduces the bug
2. Run focused tests (should fail)
3. Fix the bug
4. Run focused tests (should pass), then run `swift test` before merge
5. Commit with test + fix together

### Release a new build

Full guide: `docs/distribution.md`. Quick steps:

0. **Pre-flight:** Run `swift test` (all must pass). Check current version: `curl -s "https://macparakeet.com/appcast.xml" | grep sparkle:shortVersionString`. Decide version bump -- patch (0.1.x) for fixes, minor (0.x.0) for features.
1. **Build:** `VERSION=X.Y.Z scripts/dist/build_app_bundle.sh`
2. **Sign + notarize:** `scripts/dist/sign_notarize.sh`
3. **Upload DMG to R2:** `npx wrangler r2 object put macparakeet-downloads/MacParakeet.dmg --file dist/MacParakeet.dmg --content-type "application/x-apple-diskimage" --remote`
4. **Verify R2 file size matches local:** `curl -sI "https://downloads.macparakeet.com/MacParakeet.dmg?ts=$(date +%s)" | grep content-length` -- must equal `stat -f%z dist/MacParakeet.dmg`
5. **Sign for Sparkle:** `.build/artifacts/sparkle/Sparkle/bin/sign_update dist/MacParakeet.dmg`
6. **Update appcast:** Edit `~/code/macparakeet-website/public/appcast.xml` -- **prepend** new `<item>` (keep all previous items). Include build number, version, signature, length, `pubDate` (`date -R`), release notes.
7. **Deploy website:** `cd ~/code/macparakeet-website && git add public/appcast.xml && git commit && git push && npx astro build && npx wrangler pages deploy dist --project-name macparakeet-website --branch main`
8. **Verify:** `curl -s "https://macparakeet.com/appcast.xml?ts=$(date +%s)" | grep sparkle:version`

**Critical:** The DMG uploaded to R2 must be the **exact same file** you ran `sign_update` on. If sizes don't match, Sparkle rejects the update.

## Testing

**Philosophy:** "Write tests. Not too many. Mostly integration."

See `spec/09-testing.md` for full strategy. Key points:

| Category | What | How |
|----------|------|-----|
| Unit | Pure logic, models, text processing | XCTest, fast |
| Database | CRUD, queries, migrations | In-memory SQLite |
| Integration | Service boundaries, STT pipeline | Protocol mocks |

### Running Tests

```bash
swift test              # Fast feedback (unit + database tests)
swift test --parallel   # Full suite in parallel
```

### AI Agent Testing Loop

1. **Before coding:** `swift test` to establish baseline
2. **After changes:** `swift test` to verify no regressions
3. **Bug fix:** Write test that reproduces bug, then fix
4. Tests must be: **deterministic**, **fast** (<30s), **clear errors**

### What We Skip

- SwiftUI view tests (test ViewModels instead)
- Audio capture tests (test processing logic with fixtures)
- Third-party library internals (trust GRDB, FluidAudio)

## Building

```bash
# Build, code-sign, and launch the dev app
scripts/dev/run_app.sh

# Build and run CLI
swift build --target CLI
swift run macparakeet-cli --help
swift run macparakeet-cli transcribe /path/to/audio.mp3
swift run macparakeet-cli health

# Run tests
swift test

# Open in Xcode
open Package.swift  # Select MacParakeet scheme
```

## File Locations (Runtime)

| Item | Path |
|------|------|
| App bundle | `/Applications/MacParakeet.app` |
| Database | `~/Library/Application Support/MacParakeet/macparakeet.db` |
| STT models | `~/Library/Application Support/MacParakeet/models/stt/` (CoreML, ~6 GB) |
| yt-dlp binary | `~/Library/Application Support/MacParakeet/bin/yt-dlp` |
| FFmpeg binary | `~/Library/Application Support/MacParakeet/bin/ffmpeg` |
| Settings | `~/Library/Preferences/com.macparakeet.plist` |
| Temp audio | `$TMPDIR/macparakeet/` |
| Logs | `~/Library/Logs/MacParakeet/` |

## Security and Privacy

| Permission | Reason | When Requested |
|------------|--------|----------------|
| Microphone | Dictation + meeting recording | First dictation use |
| Accessibility | Global hotkey, paste simulation | First dictation use |
| Screen & System Audio Recording | System audio capture for meeting recording (Core Audio Taps) | First meeting recording use |

1. **Offline-first** -- Dictation and file transcription work fully offline. Network used only for YouTube downloads and anonymous telemetry.
2. **Temp files deleted** -- Audio removed after transcription (unless user saves)
3. **Non-identifying telemetry** -- Anonymous, session-scoped, opt-out in Settings. No persistent IDs, no IP storage, no content. See `docs/telemetry.md` and ADR-012.
4. **No accounts** -- No login, no email, no tracking

---

## Good Patterns to Follow

### Code Patterns

| Pattern | Why | Example |
|---------|-----|---------|
| In-memory SQLite for tests | Fast, isolated, no cleanup needed | Use GRDB's `DatabaseQueue(configuration:)` with in-memory config |
| Protocol-based services | Makes mocking easy for tests | Define `TranscriptionServiceProtocol`, implement concrete + mock |
| GRDB repositories (one per table) | Clean separation, consistent CRUD | `DictationRepository`, `TranscriptionRepository` |
| KeylessPanel for non-activating overlays | NSPanel that never steals focus | Subclass with `canBecomeKey -> false` for dictation overlay |
| Timer in .common run-loop mode | `.default` mode pauses during UI tracking (slider drag) | `RunLoop.main.add(timer, forMode: .common)` |
| DesignSystem tokens | Consistent styling, easy to change globally | Centralize spacing, typography, colors in `DesignSystem.swift` |
| TextProcessingPipeline as pure function | No side effects, easy to test | Input text -> output text, no state mutation |
| Cache computed values with signature check | Avoid O(n) work every frame | Check record ID + word count + timestamps before rebuilding |

### Architecture Patterns

| Pattern | Description |
|---------|-------------|
| Manual NSApplication.run() | No SwiftUI `App` protocol -- manual `NSApplication.shared.run()` for reliable CLI execution without .app bundle. Same pattern as Oatmeal. |
| NSStatusItem for menu bar | Menu bar via `NSStatusBar.system.statusItem()`, not SwiftUI `MenuBarExtra` |
| NSWindow + NSHostingView | Main window created programmatically, SwiftUI content hosted via `NSHostingView` |
| Core library has no UI deps | `MacParakeetCore` imports Foundation + GRDB + FluidAudio, never SwiftUI. **Exception:** `ExportService` imports AppKit for PDF/DOCX generation -- no Foundation-only alternative on macOS. |
| ViewModels in separate target | `MacParakeetViewModels/` -- testable without GUI, depends only on Core |
| Views organized by feature | `Views/Dictation/`, `Views/Transcription/`, not flat |
| Observable ViewModels | `@MainActor @Observable` on all ViewModels |
| Async/await for all I/O | No completion handlers, no Combine for new code |

---

## Known Pitfalls (from OatFlow Experience)

These are hard-won lessons. Don't repeat them.

### Swift Language Gotchas

- **`??` with `try await` does not work** -- Swift's `??` uses an autoclosure for the RHS, which doesn't support async/throwing. Use `if let ... else` instead of `title ?? (try await getTitle())`.
- **Fire-and-forget `Task` for async side-effects loses results** -- Don't use `Task { try await ... }` inside a sync function if the caller needs the result. Make the function `async` and `await` directly.
- **Force-unwrap `UTType(filenameExtension:)` can be nil** -- Unregistered extensions return nil. Always use `if let`.
- **`nonisolated` + existential protocol types conflict** -- Changing an actor's stored property from a concrete type to `any Protocol` breaks `nonisolated` access. Either drop `nonisolated` or keep the concrete type.

### UI/AppKit Gotchas

- **Don't block @MainActor with long-running work** -- Use `Task.detached` for heavy work, hop back to MainActor for UI updates.
- **Tooltips on non-activating NSPanel need AppKit-level NSTrackingArea** -- `.help()`, `.onHover`, and `NSViewRepresentable` with `.activeInActiveApp` all fail on `.nonactivatingPanel`. Only `NSTrackingArea` with `.activeAlways` works.
- **Segmented Picker `.labelsHidden()`** -- SwiftUI `Picker` with `.segmented` style shows its label string unless `.labelsHidden()` is applied.
- **Segmented Picker label truncation** -- 5+ segments in a sidebar-width picker will truncate. Use shorter labels.

### Database Gotchas

- **Raw SQL UPDATE with UUID -- use GRDB's `fetchOne(key:)` + `update()` pattern** -- GRDB stores UUID values via Codable encoding, which may differ from `id.uuidString`. Never use raw SQL `WHERE id = ?` with `uuidString`.
- **`PermissionService` is not a singleton** -- Instantiate it (`PermissionService()`), don't use `.shared`.

### General

- **Dead code from iterating on approaches** -- When switching approaches, delete old code entirely. Don't leave `_ = unusedVar` artifacts.
- **Review agents catch real bugs** -- Running a review agent on critical flows catches P0 issues. Worth the 60 seconds.
- **CI duplicates without workflow concurrency** -- Add `concurrency` with `cancel-in-progress: true` and a stable group key to avoid duplicate pipelines.

---

## Commit Message Guidelines

This project uses **rich commit messages** with `## What Changed`, `## Root Intent`, `## Prompt That Would Produce This Diff`, `## ADRs Applied`, and `## Files Changed` sections. See `docs/commit-guidelines.md` for full format and examples. Use for significant changes; optional for trivial fixes.

---

## Quick Checklist for AI Agents

### Before Starting Work

- [ ] Read this file (CLAUDE.md)
- [ ] Read `spec/10-ai-coding-method.md` for kernel workflow and precedence
- [ ] Check `spec/README.md` for current version progress
- [ ] Identify requirement IDs for the change (`spec/kernel/requirements.yaml`)
- [ ] Define the context zone: in-scope behavior, must-not-change invariants, and out-of-scope behavior
- [ ] Check `plans/active/` for any in-progress plans
- [ ] Run `swift test` to establish baseline

### After Completing Work

- [ ] Run required focused tests and `swift test` -- all tests should pass
- [ ] Update `spec/kernel/traceability.md` for changed requirement mappings
- [ ] Update docs if behavior changed (specs, README, this file)
- [ ] Archive completed plans to `plans/completed/`
- [ ] Commit with rich message (see `docs/commit-guidelines.md`)
- [ ] Keep it simple -- resist feature creep

---

*This file helps AI assistants understand the project quickly. Update it as the project evolves.*
