# MacParakeet Spec Index

> Status: **ACTIVE** - Authoritative, current
> Migration Note: FluidAudio CoreML migration is the active target architecture. Specs describe target behavior while runtime implementation is in progress.

**MacParakeet** is a local-first voice toolkit for macOS: system-wide dictation and file transcription -- all running on-device with zero cloud dependency.

## Spec Documents

| # | Document | Purpose | Status |
|---|----------|---------|--------|
| 00 | [Vision](00-vision.md) | North star, principles, positioning | Active |
| 01 | [Data Model](01-data-model.md) | Database schema, tables, migrations | Active |
| 02 | [Features](02-features.md) | Feature specifications by version | Active |
| 03 | [Architecture](03-architecture.md) | System architecture, component diagram | Active |
| 04 | [UI Patterns](04-ui-patterns.md) | UI components, overlay, settings | Active |
| 05 | [Audio Pipeline](05-audio-pipeline.md) | Audio capture, processing, storage | Active |
| 06 | [STT Engine](06-stt-engine.md) | Parakeet integration via FluidAudio CoreML/ANE | Active |
| 07 | [Text Processing](07-text-processing.md) | Clean pipeline, custom words, snippets | Active |
| 08 | [Error Handling](08-error-handling.md) | Error philosophy, categories, recovery | Active |
| 09 | [Testing](09-testing.md) | Testing strategy, patterns, guidelines | Active |
| 10 | [AI Coding Method](10-ai-coding-method.md) | Spec-driven coding philosophy and kernel methodology | Active |
| 11 | [LLM Integration](11-llm-integration.md) | Local LLM architecture (historical — removed) | Historical |

## Root Decisions (Locked)

These decisions are final. Do not second-guess them.

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Local STT | Parakeet TDT 0.6B-v3 via FluidAudio CoreML/ANE | 155x realtime, ~2.5% WER, fully local, ~66 MB working RAM |
| Database | SQLite via GRDB | Single file, embedded, zero config |
| Platform | macOS 14.2+ (Apple Silicon only) | FluidAudio requires Apple Silicon; Swift 6.0 |
| Business model | One-time purchase ($49) | Key differentiator vs WisprFlow ($144-180/year subscription) |

## Architecture Decision Records (ADRs)

All ADRs live in `spec/adr/`. These are locked -- they record decisions already made.

| ADR | Decision |
|-----|----------|
| [ADR-001](adr/001-parakeet-stt.md) | Parakeet TDT 0.6B-v3 as primary STT engine |
| [ADR-002](adr/002-local-only.md) | No cloud processing (100% local) |
| [ADR-003](adr/003-one-time-purchase.md) | One-time purchase pricing ($49) |
| [ADR-004](adr/004-deterministic-pipeline.md) | Deterministic text processing pipeline |
| [ADR-005](adr/005-onboarding-first-run.md) | First-run onboarding flow |
| [ADR-006](adr/006-trial-and-license-activation.md) | Trial + license key activation |
| [ADR-007](adr/007-fluidaudio-coreml-migration.md) | FluidAudio CoreML migration (Python elimination) |
| [ADR-008](adr/008-local-llm-runtime-and-model.md) | Local LLM runtime baseline (historical — removed) |
| [ADR-009](adr/009-custom-hotkey.md) | Custom hotkey support (any single key) |
| [ADR-010](adr/010-speaker-diarization.md) | Speaker diarization via FluidAudio offline pipeline |

## Version Roadmap

| Version | Name | Focus | Status |
|---------|------|-------|--------|
| v0.1 | Core MVP | Dictation + transcription + history + settings | **Implemented** |
| v0.2 | Clean Pipeline | Deterministic text processing, custom words, snippets | **Implemented** |
| v0.3 | YouTube & Export | YouTube transcription, export formats | **In Progress** |
| v0.4 | Polish & Launch | Diarization, batch processing, App Store | Planned |

## Version Progress

### v0.1 Core MVP (Implemented)

Dictation + transcription + history + settings. Get audio in, text out, pasted into any app.

- [x] System-wide dictation: Configurable hotkey (Fn default), double-tap (persistent) + hold-to-talk
- [x] File transcription: Drag-drop audio/video files
- [x] Compact dark pill overlay with recording timer + waveform
- [x] Persistent idle pill (always-visible, click-to-dictate)
- [x] Auto-paste with clipboard save/restore
- [x] Dictation history (date-grouped, searchable, flat list with bottom bar player)
- [x] Settings (hotkey display, silence auto-stop, storage, permissions)
- [x] Menu bar app with main window
- [x] Basic export (TXT/Markdown/SRT/VTT + copy to clipboard)
- [x] SQLite database (GRDB, dictations + transcriptions + substring search)
- [x] Internal dev CLI tool (`macparakeet-cli transcribe`, `history`, `health`, `models`, `flow`)
- [x] Test suite passing (`swift test` green)

### v0.2 Clean Pipeline (Implemented)

- [x] Clean text pipeline (deterministic: fillers, custom words, snippets)
- [x] Custom words & snippets management UI
- [x] CLI commands (`macparakeet-cli flow process/words/snippets` + `macparakeet-cli models status/warm-up/repair`)
- [x] In-app feedback form (Feedback sidebar item → Cloudflare Worker → GitHub Issues on `macparakeet-community`)

### v0.3 YouTube & Export (In Progress)

- [x] YouTube URL transcription (yt-dlp + Parakeet)
- [x] Exports: TXT, Markdown, SRT, VTT (one-click to Downloads)
- [x] Full export (.docx, .pdf, .json)

### v0.4 Polish & Launch (Planned)

- [ ] Speaker diarization (auto-detect, label, name)
- [ ] Batch file processing (queue, progress, batch export)
- [ ] App Store submission (sandbox, notarize, privacy policy)

## For AI Coding Assistants

### Key Rules

1. **Specs are authoritative.** If code and spec disagree, the spec is correct (then fix the code).
2. **ADRs are locked.** Do not propose alternatives to locked decisions.
3. **Version order matters.** Implement v0.1 before v0.2. Do not jump ahead.
4. **Never lose user data.** Graceful degradation over silent failure.
5. **Local-first.** Audio and text never leave the device. No cloud APIs.
6. **`swift test` is the gate.** All tests must pass before and after changes.
8. **Kernel has precedence for implementation.** When present, `spec/kernel/*` artifacts define executable requirements and contracts.

### Where to Start

1. Read this file (you're here)
2. Read `CLAUDE.md` in the project root for build instructions and codebase patterns
3. Check `plans/active/` for in-progress work
4. Check the version progress above for what needs doing next
