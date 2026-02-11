# CLAUDE.md

> Context for AI coding assistants working on MacParakeet.

## What is MacParakeet?

A **fast, private, local-first voice app** for macOS with two co-equal modes: system-wide dictation and file transcription. Powered by NVIDIA's Parakeet TDT via MLX.

**North Star:** The fastest, most private voice app for Mac. No cloud. No subscriptions.

**Domain:** [macparakeet.com](https://macparakeet.com)

**Pricing:** $49 one-time purchase (Free tier: 15 min/day)

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
| ADRs (locked decisions) | `spec/adr/` -> individual decision records |
| Competitive research | `docs/competitive-analysis.md` |
| Implementation plans | `plans/` -> active and completed plans |

## Tech Stack (Locked Decisions)

| Layer | Choice | Notes |
|-------|--------|-------|
| Platform | macOS 14.2+ | Apple Silicon only |
| Language | Swift 5.9+ | SwiftUI for UI |
| Database | SQLite | GRDB (single file, dictation history + transcriptions) |
| STT | Parakeet TDT 0.6B-v3 | Via parakeet-mlx, Python daemon (~6.3% WER, 300x realtime) |
| Python | uv bootstrap | Bundled uv binary, isolated venv |
| Audio | AVAudioEngine + Core Audio | Mic capture for dictation |
| LLM | MLX-Swift | Qwen3-4B for command mode + AI refinement |

## Product Context

MacParakeet is extracted from the OatFlow feature in Oatmeal but is **fully independent** -- no shared code, no shared packages, no monorepo dependencies.

| | MacParakeet | Oatmeal |
|---|-------------|---------|
| **Focus** | Voice dictation + file transcription | Meeting memory + calendar |
| **Complexity** | Simple, focused | Complex, powerful |
| **Pricing** | $49 one-time | Freemium + Pro |
| **Value prop** | "Fast local transcription" | "Remembers everything" |

### Why Separate Products?

1. **SEO** -- Capture "mac transcription", "macwhisper alternative" searches
2. **Simpler value prop** -- "Fast local transcription" vs complex meeting memory
3. **Lower barrier** -- Entry-level product, potential funnel to Oatmeal
4. **Monetization** -- One-time purchase revenue while Oatmeal matures

## Competitive Landscape

Direct competitors (see `docs/competitive-analysis.md` for full analysis):

| App | Price | Our Advantage |
|-----|-------|---------------|
| WisprFlow | $12-15/mo subscription | 100% local (WisprFlow is cloud-based), one-time purchase |
| MacWhisper | $30 Pro | Parakeet-first (MacWhisper added it as afterthought), simpler UI |
| Superwhisper | $250 lifetime / $5.41/mo | 5x cheaper, faster (Parakeet vs Whisper-only) |
| VoiceInk | $39.99 one-time | More features, Command Mode, AI refinement |
| Spokenly | Free-$8/mo | One-time purchase, no subscription |
| Voibe | $99 lifetime / $4.90/mo | More features, Command Mode, file transcription |

**Our differentiators:**
1. **Parakeet-first** -- Built around fastest local STT model from day one
2. **One-time purchase** -- No subscription fatigue ($49 vs $12-15/mo)
3. **100% local** -- Zero cloud, zero tracking, zero accounts
4. **Two co-equal modes** -- Dictation AND transcription, not bolted-on afterthoughts
5. **Simple** -- Does two things well, no feature bloat

## Architecture Decisions (ADRs)

All ADRs are in `spec/adr/`. These are locked decisions -- don't second-guess them.

| ADR | Decision | File |
|-----|----------|------|
| ADR-001 | Parakeet TDT 0.6B-v3 as primary STT | `spec/adr/001-parakeet-stt.md` |
| ADR-002 | No cloud processing (100% local) | `spec/adr/002-local-only.md` |
| ADR-003 | One-time purchase pricing ($49) | `spec/adr/003-one-time-purchase.md` |
| ADR-004 | Deterministic text processing pipeline | `spec/adr/004-deterministic-pipeline.md` |
| ADR-005 | First-run onboarding flow | `spec/adr/005-onboarding-first-run.md` |

## Current Phase

**v0.2 In Progress** -- Clean pipeline + management UI implemented (292 tests, 32 suites, `swift test` green)

### v0.1 MVP (Implemented)
- [x] System-wide dictation: Fn double-tap (persistent) + hold-to-talk
- [x] File transcription: Drag-drop audio/video files
- [x] Compact dark pill overlay with recording timer + waveform
- [x] Persistent idle pill (always-visible, click-to-dictate)
- [x] Auto-paste with clipboard save/restore
- [x] Settings (hotkey display, silence auto-stop, storage, permissions)
- [x] Dictation history (date-grouped, searchable, flat list with bottom bar player, audio playback)
- [x] Menu bar app with main window + sidebar navigation
- [x] Basic export (plain text .txt, copy to clipboard)
- [x] SQLite database (GRDB, dictations + transcriptions + substring search)
- [x] CLI tool: `macparakeet transcribe`, `history`, `health`
- [x] Python STT daemon (JSON-RPC over stdin/stdout)

### v0.2 Clean Pipeline + AI
- [x] Clean text pipeline (filler removal, custom words, snippets) -- deterministic, no LLM
- [x] Custom words & snippets management UI (Vocabulary sidebar item)
- [x] CLI commands: `macparakeet flow process/words/snippets`
- [ ] Context modes (raw, clean, formal, email, code) -- raw + clean done, AI modes pending
- [ ] AI text refinement via Qwen3-4B

### v0.3 Command Mode + Import
- [ ] Command Mode (highlight text + voice command -> LLM edits in-place, like WisprFlow Pro)
- [x] YouTube URL transcription (yt-dlp + Parakeet, single video)
- [ ] Export formats (TXT, SRT, VTT, DOCX)

### v0.4 Polish + Launch
- [ ] Speaker diarization
- [ ] Batch file processing
- [ ] Whisper Mode (quiet/whispered speech recognition)
- [ ] App Store submission

## Key Patterns

### Two Co-Equal Modes

MacParakeet has two primary modes that are equal in importance:

1. **System-wide dictation** -- Press hotkey anywhere on macOS, speak, text is pasted (WisprFlow-style)
2. **File transcription** -- Drag-drop audio/video files for full transcription (MacWhisper-style)

Both modes share the same Parakeet STT backend but have different UI flows and data models.

### STT Integration (Parakeet)

- Python daemon via JSON-RPC over stdin/stdout
- uv bootstraps Python environment on first run
- Parakeet TDT 0.6B-v3 returns word-level timestamps + confidence scores
- ~300x realtime on Apple Silicon (60 min audio in ~12 seconds)
- ~6.3% Word Error Rate

**JSON-RPC Protocol:**
```json
// Request
{
  "jsonrpc": "2.0",
  "method": "transcribe",
  "params": {
    "audio_path": "/tmp/recording.wav",
    "language": "en"
  },
  "id": 1
}

// Response
{
  "jsonrpc": "2.0",
  "result": {
    "text": "Hello world",
    "words": [
      {"word": "Hello", "start_ms": 0, "end_ms": 500, "confidence": 0.98},
      {"word": "world", "start_ms": 600, "end_ms": 1000, "confidence": 0.97}
    ]
  },
  "id": 1
}
```

### Database

- `macparakeet.db` (GRDB): Dictation history + transcription records in a single file
- No vector search or embeddings needed (unlike Oatmeal)
- One repository per table (GRDB pattern)

### LLM Integration

**Single Qwen3 model for ALL tasks** (no Llama, no Ollama):

| Model | HuggingFace ID |
|-------|----------------|
| Qwen3-4B | `mlx-community/Qwen3-4B-4bit` |

**Dual-mode operation** (same model, different settings):

| Mode | Use Case | Settings |
|------|----------|----------|
| Non-thinking | Text cleanup, formatting | `temp=0.7, topP=0.8` |
| Thinking | Command mode, complex edits | `temp=0.6, topP=0.95` |

### Audio Capture

- **Dictation**: AVAudioEngine tap on input node (microphone)
- **File transcription**: FFmpeg (bundled) converts to 16kHz mono WAV for Parakeet
- No system audio capture needed (that is Oatmeal's meeting recording domain)

### GUI Structure

MacParakeet is a **menu bar app** with four UI surfaces:

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
    +-- Settings Window
    |   +-- License activation
    |   +-- Hotkey configuration
    |   +-- Storage management
    |   +-- Permissions
    |
    +-- History Panel
        +-- Dictation history with search
        +-- Audio playback
        +-- Re-copy / re-process
```

View files organized by feature in `Sources/MacParakeet/Views/`:
- `Transcription/` -- Main window, drop zone, transcript display, export
- `Dictation/` -- Overlay, waveform, recording state
- `Vocabulary/` -- Processing mode, custom words, text snippets
- `Settings/` -- License, dictation prefs, storage, permissions
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
│   ├── 00-vision.md    # Product vision
│   ├── 01-data-model.md    # Database schema
│   ├── 02-features.md      # Feature roadmap
│   ├── 03-architecture.md  # System design
│   ├── 04-ui-patterns.md   # UI components
│   ├── 05-audio-pipeline.md
│   ├── 06-stt-engine.md
│   ├── 07-text-processing.md  # Clean pipeline + command mode
│   ├── 08-error-handling.md
│   ├── 09-testing.md
│   └── adr/            # Architecture Decision Records (locked)
├── docs/               # Research, explorations (informative)
│   ├── competitive-analysis.md
│   ├── distribution.md # Developer ID signing + notarization guide
│   └── research/       # Deep dives on competitors, user sentiment
├── plans/              # Implementation plans (version controlled)
│   ├── active/         # Currently being implemented
│   └── completed/      # Done plans (archived, not deleted)
├── Sources/
│   ├── MacParakeet/            # GUI app (SwiftUI, imports MacParakeetCore + ViewModels)
│   ├── CLI/                    # CLI tool (ArgumentParser, imports MacParakeetCore)
│   ├── MacParakeetCore/        # Shared library (no UI deps)
│   └── MacParakeetViewModels/  # ViewModels (testable, depends on Core)
├── Tests/
│   └── MacParakeetTests/   # Unit, database, and integration tests (292 tests, 32 suites)
├── Assets/             # App icons and images (placeholder)
├── python/             # STT daemon (Parakeet via uv)
│   └── macparakeet_stt/
└── scripts/            # Build, test, and release scripts (placeholder)
```

### Document Hierarchy

```
Vision (spec/00-vision.md)
    |
Architecture (spec/03-architecture.md + spec/adr/)
    |
Specifications (spec/*.md)
    |
Implementation Plans (plans/)
    |
Code (Sources/)
```

### Related Repos

- [macparakeet-website](https://github.com/moona3k/macparakeet-website) -- Marketing website (Astro + Tailwind), macparakeet.com
- [oatmeal](https://github.com/moona3k/oatmeal) -- Sibling product (meeting memory app, shares no code)

## Implementation Guidelines

1. **Specs are the source of truth** -- All code is generated from and must align with the specs in `spec/`. If code and spec disagree, the spec is correct -- fix the code. When specs are updated, code must follow. When code reveals a spec gap, update the spec first, then implement. Specs drive implementation, not the reverse.
2. **ADRs are locked** -- Don't second-guess architectural decisions in `spec/adr/`.
3. **Version order matters** -- v0.1 features first, not v0.3
4. **Never lose user data** -- Graceful degradation for dictation history and transcriptions
5. **UI philosophy** -- Minimal during dictation, rich for transcription results
6. **Local-first** -- Audio never leaves device. Period. No cloud option.
7. **Simplicity is the product** -- Resist feature creep. MacParakeet does two things well.
8. **Fast feedback loops for agents** -- AI agents make mistakes, but they're good at fixing them *if they can detect them*. Design everything so the agent can verify its own work: tests for logic, CLI for headless smoke-testing of core services, build errors that surface immediately. The faster the feedback loop, the faster the agent self-corrects. If an agent can't confirm its own change works, the change is incomplete.

## Documentation Hygiene

**Keep docs aligned with code.** Stale documentation is worse than no documentation.

### After Completing Work

1. **Update spec progress** -- Mark features complete in `spec/README.md` and `spec/02-features.md`
2. **Update test counts** -- If tests changed, update counts in `README.md` and this file
3. **Archive plans** -- Move completed plans from `plans/active/` to `plans/completed/YYYY-MM-name.md`
4. **Mark outdated docs** -- Add `> Status: **HISTORICAL**` header to superseded docs

### Document Lifecycle Headers

Add status headers to documents so future agents know what's current:

```markdown
> Status: **ACTIVE** - Authoritative, current
> Status: **IMPLEMENTED** - Done, still accurate
> Status: **HISTORICAL** - Superseded, kept for context
> Status: **PROPOSAL** - Under discussion
```

### When Reading Docs

1. **Check status headers** -- Skip HISTORICAL docs unless researching past decisions
2. **Verify against code** -- If doc and code disagree, code is truth (then fix doc)
3. **Note discrepancies** -- Flag outdated content for update

### Signs of Stale Docs

- Test counts don't match `swift test` output
- Features marked "planned" that are implemented
- References to technologies not in the locked stack
- Plans in `plans/active/` for completed features

## Working with Plans

Implementation plans live in `plans/` and are version-controlled.

### When to Create a Plan

Create a plan for:
- Multi-file changes
- New features
- Architectural changes
- Complex refactoring

Skip plans for bug fixes, typos, single-file changes.

### Plan Workflow

```
1. Create plan     -> plans/active/feature-name.md
2. Get approval    -> User reviews and approves
3. Implement       -> Follow the plan, update as needed
4. Complete        -> Move to plans/completed/YYYY-MM-feature-name.md
```

### Plan Format

Plans should be **prompt-ready** -- detailed enough that an AI agent could execute them:

```markdown
# [Feature Name] Implementation Plan

> Status: **ACTIVE** | **COMPLETED** - [date]

## Overview
[What and why]

## Design Decisions
[Key choices]

## Implementation Steps
[Detailed, actionable steps]

## Files Changed
[Summary when done]
```

## Common Tasks

Step-by-step guides for frequent development tasks.

### Add a new feature

1. Read relevant spec (e.g., `spec/02-features.md`)
2. Create a plan in `plans/active/` if multi-file
3. Implement in `Sources/MacParakeetCore/` (logic) and `Sources/MacParakeet/` (UI)
4. Add tests in `Tests/MacParakeetTests/`
5. Run `swift test` to verify
6. Update spec progress markers

### Add a new database table

1. Update `spec/01-data-model.md` with schema
2. Add migration in `Sources/MacParakeetCore/Database/DatabaseManager.swift` (inline migrations)
3. Add model in `Sources/MacParakeetCore/Models/`
4. Add repository in `Sources/MacParakeetCore/Database/{Name}Repository.swift`
5. Run `swift test` to verify migrations

### Add a new service

1. Define protocol in `Sources/MacParakeetCore/Services/`
2. Implement service conforming to protocol
3. Add tests in `Tests/MacParakeetTests/`
4. Look at existing services for patterns:
   - Domain services: `Sources/MacParakeetCore/Services/` (TranscriptionService, DictationService, ExportService, ClipboardService, PermissionService)
   - Licensing: `Sources/MacParakeetCore/Licensing/` (EntitlementsService, LemonSqueezyLicenseAPI, KeychainKeyValueStore)

### Fix a bug

1. Write a test that reproduces the bug
2. Run `swift test` (should fail)
3. Fix the bug
4. Run `swift test` (should pass)
5. Commit with test + fix together

### Add a CLI command (if CLI target is added)

1. Read relevant spec
2. Look at existing commands in `Sources/CLI/Commands/` for patterns
3. Create `Sources/CLI/Commands/{Name}Command.swift`
4. Register in the CLI entry point
5. Add tests in `Tests/MacParakeetTests/`
6. Run `swift test` to verify

## Testing

**Philosophy:** "Write tests. Not too many. Mostly integration."

See `spec/09-testing.md` for full strategy. Key points:

### Test Categories

| Category | What | How |
|----------|------|-----|
| Unit | Pure logic, models, text processing | XCTest, fast |
| Database | CRUD, queries, migrations | In-memory SQLite |
| Integration | Service boundaries, STT pipeline | Protocol mocks |

### Running Tests

```bash
# Fast feedback (unit + database tests)
swift test

# Full suite in parallel
swift test --parallel

# With external services (local only)
MLX_TESTS=1 swift test --filter MLXIntegrationTests
```

### AI Agent Testing Loop

1. **Before coding:** `swift test` to establish baseline
2. **After changes:** `swift test` to verify no regressions
3. **Bug fix:** Write test that reproduces bug, then fix
4. Tests must be: **deterministic**, **fast** (<30s), **clear errors**

### What We Skip

- SwiftUI view tests (test ViewModels instead)
- Audio capture tests (test processing logic with fixtures)
- Third-party library internals (trust GRDB, MLX-Swift)
- Python daemon internals (test the Swift STTClient protocol layer)

## Building

### Why xcodebuild?

MLX-Swift requires Metal shaders. **`swift build` cannot compile Metal shaders** -- it will build but crash at runtime with "Failed to load the default metallib".

### Build & Run

```bash
# Build GUI app (uses local .build/xcode for derived data)
# Signing ensures Keychain remembers the app across rebuilds (no repeated password prompts)
xcodebuild build -scheme MacParakeet -destination 'platform=OS X' -derivedDataPath .build/xcode \
  CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=FYAF2ZD7RM

# Run GUI app
.build/xcode/Build/Products/Debug/MacParakeet

# Build and run CLI
swift build --target CLI
swift run macparakeet --help
swift run macparakeet transcribe /path/to/audio.mp3
swift run macparakeet health

# Run tests (swift test works -- tests don't need Metal shaders)
swift test
```

### Xcode IDE

```bash
open Package.swift  # Opens in Xcode, select MacParakeet scheme
```

### Python STT Daemon

Python environment is bootstrapped automatically via uv on first use.

```bash
# Manual test of the Python daemon
cd python/macparakeet_stt
uv run python -m macparakeet_stt.server
```

### Verify It Works

After building, quick smoke test:

```bash
# Run the app
.build/xcode/Build/Products/Debug/MacParakeet

# Run tests
swift test
```

## File Locations (Runtime)

| Item | Path |
|------|------|
| App bundle | `/Applications/MacParakeet.app` |
| Database | `~/Library/Application Support/MacParakeet/macparakeet.db` |
| Python venv | `~/Library/Application Support/MacParakeet/python/` |
| Settings | `~/Library/Preferences/com.macparakeet.plist` |
| Temp audio | `$TMPDIR/macparakeet/` |
| Logs | `~/Library/Logs/MacParakeet/` |
| LLM models | `~/Library/Application Support/MacParakeet/models/` |

## Security and Privacy

### Permissions Required

| Permission | Reason | When Requested |
|------------|--------|----------------|
| Microphone | Dictation recording | First dictation use |
| Accessibility | Global hotkey, paste simulation | First dictation use |

### Privacy Guarantees

1. **No network by default** -- App works fully offline
2. **Temp files deleted** -- Audio removed after transcription (unless user saves)
3. **No analytics** -- Zero telemetry
4. **No accounts** -- No login, no email, no tracking

---

## Good Patterns to Follow

These patterns are proven from OatFlow development in Oatmeal. Apply them here.

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
| Manual NSApplication.run() | No SwiftUI `App` protocol — manual `NSApplication.shared.run()` for reliable CLI execution without .app bundle. Same pattern as Oatmeal. |
| NSStatusItem for menu bar | Menu bar via `NSStatusBar.system.statusItem()`, not SwiftUI `MenuBarExtra` |
| NSWindow + NSHostingView | Main window created programmatically, SwiftUI content hosted via `NSHostingView` |
| Core library has no UI deps | `MacParakeetCore` imports Foundation + GRDB + MLX, never SwiftUI |
| ViewModels in separate target | `MacParakeetViewModels/` — testable without GUI, depends only on Core |
| Views organized by feature | `Views/Dictation/`, `Views/Transcription/`, not flat |
| Observable ViewModels | `@MainActor @Observable` on all ViewModels |
| Async/await for all I/O | No completion handlers, no Combine for new code |

---

## Known Pitfalls (from OatFlow Experience)

These are hard-won lessons. Don't repeat them.

### Swift Language Gotchas

- **`??` with `try await` does not work** -- Swift's `??` uses an autoclosure for the RHS, which doesn't support async/throwing. Use `if let ... else` instead of `title ?? (try await getTitle())`.
- **Fire-and-forget `Task` for async side-effects loses results** -- Don't use `Task { try await ... }` inside a sync function if the caller needs the result. The parent returns before the Task completes. Make the function `async` and `await` directly instead.
- **Force-unwrap `UTType(filenameExtension:)` can be nil** -- Unregistered extensions return nil. Always use `if let` with `UTType` init.
- **`nonisolated` + existential protocol types conflict** -- Changing an actor's stored property from a concrete type to `any Protocol` breaks `nonisolated` access. Either drop `nonisolated` or keep the concrete type.

### UI/AppKit Gotchas

- **Don't block @MainActor with long-running work** -- `await service.transcribe(...)` inside a `@MainActor` function blocks the UI. Use `Task.detached` for heavy work and hop back to MainActor for UI updates.
- **Tooltips on non-activating NSPanel need AppKit-level NSTrackingArea** -- `.help()`, `.onHover`, and `NSViewRepresentable` with `.activeInActiveApp` all fail on `.nonactivatingPanel`. Only `NSTrackingArea` with `.activeAlways` works. Use a `MouseTrackingOverlay` NSView on top with `hitTest -> nil` for click passthrough.
- **Segmented Picker `.labelsHidden()`** -- SwiftUI `Picker` with `.segmented` style shows its label string unless `.labelsHidden()` is applied. Always add it.
- **Segmented Picker label truncation** -- 5+ segments in a sidebar-width picker will truncate. Use shorter labels.

### Database Gotchas

- **Raw SQL UPDATE with UUID -- use GRDB's `fetchOne(key:)` + `update()` pattern** -- GRDB stores UUID values via Codable encoding, which may differ from `id.uuidString`. Never use raw SQL `WHERE id = ?` with `uuidString`.
- **`PermissionService` is not a singleton** -- Instantiate it (`PermissionService()`), don't use `.shared`.

### General

- **Dead code from iterating on approaches** -- When switching from one approach to another, delete the old code entirely. Don't leave `_ = unusedVar` artifacts.
- **Review agents catch real bugs** -- Running a review agent on onboarding or critical flows catches P0 issues. Worth doing for non-trivial UI flows.

---

## Commit Message Guidelines

This project uses **rich commit messages** optimized for AI-assisted development. Each commit should capture enough context that a future agent (or human) can understand the full reasoning.

### Structure

```
<title>: Short summary (imperative mood)

## What Changed
Detailed breakdown of every file/section modified.

## Root Intent
Why this commit exists. The underlying problem or goal.

## Prompt That Would Produce This Diff
A detailed instruction that would recreate this work from scratch.
This is the "recipe" - if you gave this prompt to an AI agent with
access to the codebase, it should produce an equivalent diff.

## ADRs Applied (if any)
Links to architectural decisions that informed the changes.

## Files Changed
Summary with line counts for quick scanning.
```

### Example (Feature)

```
Add dictation overlay with waveform visualization

## What Changed
- Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift: New compact dark pill overlay
  with recording state indicator, waveform, and cancel button
- Sources/MacParakeet/Views/Dictation/WaveformView.swift: Real-time audio level waveform using
  AVAudioEngine tap data
- Sources/MacParakeetCore/Services/DictationService.swift: Added audioLevelPublisher for UI
- Tests/MacParakeetTests/DictationServiceTests.swift: Test audio level callback registration

## Root Intent
Users need visual feedback when dictating -- they need to know the app is recording,
see their voice levels, and have a clear way to cancel. The pill overlay appears over
all apps without stealing focus.

## Prompt That Would Produce This Diff
Implement a dictation overlay for MacParakeet modeled after OatFlow's pill overlay.
Create a compact dark pill that:
1. Appears as a borderless NSPanel over all windows
2. Shows recording state with pulsing indicator
3. Displays real-time waveform from AVAudioEngine audio levels
4. Has a cancel button (Escape key also cancels)
5. Does NOT steal focus from the active app (non-activating panel)

Use KeyablePanel pattern if text input is needed. Add audioLevelPublisher
to DictationService so the view can subscribe to audio levels.

## ADRs Applied
- ADR-004: Parakeet TDT for STT (dictation sends audio to Parakeet daemon)

## Files Changed
- Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift (+145)
- Sources/MacParakeet/Views/Dictation/WaveformView.swift (+62)
- Sources/MacParakeetCore/Services/DictationService.swift (+28, ~12)
- Tests/MacParakeetTests/DictationServiceTests.swift (+34)
```

### Example (Bug Fix)

```
Fix clipboard not restoring after dictation paste

## What Changed
- Sources/MacParakeetCore/Services/DictationService.swift: Save clipboard contents
  before pasting transcription, restore after CGEvent paste completes

## Root Intent
Users complained that dictation overwrites their clipboard. The paste
operation should be transparent -- save what was on the clipboard, paste
the transcription via simulated Cmd+V, then restore the original clipboard.

## Prompt That Would Produce This Diff
Fix the dictation paste flow in DictationService to preserve the user's
clipboard. Before writing the transcription to NSPasteboard, save the
current contents. After the CGEvent Cmd+V is dispatched and a short delay
(100ms), restore the saved clipboard contents.

## Files Changed
- Sources/MacParakeetCore/Services/DictationService.swift (~18)
```

### Why This Matters

1. **Git history becomes documentation** -- Rich context lives in version control, not lost chat logs
2. **Reproducible changes** -- The prompt section is a recipe that could regenerate the diff
3. **Onboarding via archaeology** -- New devs/agents understand decisions by reading commits
4. **Auditable reasoning** -- The "why" is preserved alongside the "what"

### When to Use This Format

- **Always** for significant changes (multi-file, architectural, spec updates)
- **Optional** for trivial fixes (typos, single-line changes)

---

## Quick Checklist for AI Agents

### Before Starting Work

- [ ] Read this file (CLAUDE.md)
- [ ] Check `spec/README.md` for current version progress
- [ ] Check `plans/active/` for any in-progress plans
- [ ] Run `swift test` to establish baseline

### After Completing Work

- [ ] Run `swift test` -- all tests should pass
- [ ] Update docs if behavior changed (specs, README, this file)
- [ ] Archive completed plans to `plans/completed/`
- [ ] Record learnings in `MEMORY.md` (gotchas, patterns, failed approaches)
- [ ] Commit with rich message (see Commit Message Guidelines above)
- [ ] Keep it simple -- resist feature creep

---

## Continuous Learning

This project uses a **self-improving workflow** where AI agents document what they learn as they work. This compounds over time -- each session benefits from all prior sessions.

### How It Works

1. **Auto memory** (`~/.claude/projects/.../memory/MEMORY.md`) -- Claude Code's persistent memory across conversations. Gets loaded into system prompt automatically.
2. **CLAUDE.md itself** -- Update this file when patterns, paths, or conventions change. Don't let it go stale.
3. **Rich commit messages** -- The "Prompt That Would Produce This Diff" section means any future agent can reconstruct the reasoning.

### What to Document

After completing non-trivial work, record:
- **Gotchas discovered** -- Things that wasted time or were surprising
- **Patterns that worked** -- Approaches that were effective for this codebase
- **Codebase quirks** -- Conventions or structures that aren't obvious from reading code
- **Failed approaches** -- What didn't work and why, so future agents don't repeat it

### Where to Document

| What | Where |
|------|-------|
| Cross-session learnings | `MEMORY.md` (auto-loaded, keep concise) |
| Topic-specific notes | `memory/*.md` (linked from MEMORY.md) |
| Codebase conventions | This file (CLAUDE.md) |
| Decision rationale | Commit messages + ADRs |

### Self-Reflection Protocol

Reflection is not optional -- it's how the system improves. Follow these triggers:

**After completing a task:**
1. What surprised me? (unexpected file locations, API quirks, build issues)
2. What took longer than expected? Why?
3. Did I make an incorrect assumption? Record the correction.
4. Did a pattern from MEMORY.md help? If so, is it still accurate?

**After hitting an error or dead end:**
1. What was the root cause?
2. What did I try that didn't work? (Record in "Failed Approaches")
3. What was the fix? Would a future agent hit this same wall?

**After reading MEMORY.md at session start:**
1. Is anything outdated? (test counts, current state, version progress)
2. Has code moved or been renamed since these notes were written?
3. Delete or correct anything that's wrong -- stale memory is worse than none.

**Periodically (every few sessions):**
1. Are topic files in `memory/` still relevant?
2. Is MEMORY.md getting long? Compress or move details to topic files.
3. Should any learnings graduate to CLAUDE.md as permanent conventions?

### Rules

- Keep MEMORY.md under 200 lines (it's loaded into every system prompt)
- Use separate topic files for detailed notes, link from MEMORY.md
- Update or remove learnings that turn out to be wrong -- stale memory is worse than none
- Don't document things already covered in CLAUDE.md -- avoid duplication
- When correcting a prior learning, note what was wrong and why (helps calibrate)

---

*This file helps AI assistants understand the project quickly. Update it as the project evolves.*
