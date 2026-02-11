# MacParakeet Spec Index

> Status: **ACTIVE** - Authoritative, current

**MacParakeet** is a local-first voice toolkit for macOS: system-wide dictation, file transcription, and AI-powered text editing -- all running on-device with zero cloud dependency.

## Spec Documents

| # | Document | Purpose | Status |
|---|----------|---------|--------|
| 00 | [Vision](00-vision.md) | North star, principles, positioning | Active |
| 01 | [Data Model](01-data-model.md) | Database schema, tables, migrations | Active |
| 02 | [Features](02-features.md) | Feature specifications by version | Active |
| 03 | [Architecture](03-architecture.md) | System architecture, component diagram | Active |
| 04 | [UI Patterns](04-ui-patterns.md) | UI components, overlay, settings | Active |
| 05 | [Audio Pipeline](05-audio-pipeline.md) | Audio capture, processing, storage | Active |
| 06 | [STT Engine](06-stt-engine.md) | Parakeet integration, JSON-RPC protocol | Active |
| 07 | [Text Processing](07-text-processing.md) | Clean pipeline, custom words, snippets | Active |
| 08 | [Error Handling](08-error-handling.md) | Error philosophy, categories, recovery | Active |
| 09 | [Testing](09-testing.md) | Testing strategy, patterns, guidelines | Active |

## Root Decisions (Locked)

These decisions are final. Do not second-guess them.

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Local STT | Parakeet TDT 0.6B-v3 via parakeet-mlx | 300x realtime, ~6.3% WER, fully local |
| Python runtime | uv bootstrap | Isolated venv, no system Python dependency |
| Database | SQLite via GRDB | Single file, embedded, zero config |
| Local LLM | Qwen3-4B via MLX-Swift | Best 4B model on benchmarks, dual-mode (thinking/non-thinking) |
| Platform | macOS 14.2+ (Apple Silicon only) | MLX-Swift framework support, Apple Silicon required for Parakeet + MLX |
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

## Version Roadmap

| Version | Name | Focus | Status |
|---------|------|-------|--------|
| v0.1 | Core MVP | Dictation + transcription + history + settings | **Implemented** |
| v0.2 | AI & Text Processing | Clean pipeline, AI refinement, custom words | **In Progress** |
| v0.3 | Command Mode & Export | Voice commands, YouTube, full export formats | Planned |
| v0.4 | Polish & Launch | Diarization, batch processing, App Store | Planned |

## Version Progress

### v0.1 Core MVP (Implemented)

Dictation + transcription + history + settings. Get audio in, text out, pasted into any app.

- [x] System-wide dictation: Fn double-tap (persistent) + hold-to-talk
- [x] File transcription: Drag-drop audio/video files
- [x] Compact dark pill overlay with recording timer + waveform
- [x] Persistent idle pill (always-visible, click-to-dictate)
- [x] Auto-paste with clipboard save/restore
- [x] Dictation history (date-grouped, searchable, flat list with bottom bar player)
- [x] Settings (hotkey display, silence auto-stop, storage, permissions)
- [x] Menu bar app with main window
- [x] Basic export (plain text, copy to clipboard)
- [x] SQLite database (GRDB, dictations + transcriptions + substring search)
- [x] CLI tool (`macparakeet transcribe`, `history`, `health`)
- [x] 292 tests passing (32 test suites)

### v0.2 AI & Text Processing (In Progress)

- [x] Clean text pipeline (deterministic: fillers, custom words, snippets)
- [ ] AI text refinement (Qwen3-4B: formal, email, code modes)
- [x] Custom words & snippets management UI
- [ ] Personal dictionary (auto-learns vocabulary)
- [x] CLI commands (`macparakeet flow process/words/snippets`)

### v0.3 Command Mode & Export (Planned)

- [ ] Command Mode: select text -> speak command -> LLM edits in-place
- [x] YouTube URL transcription (yt-dlp + Parakeet)
- [ ] Full export (.txt, .srt, .vtt, .docx, .pdf, .json)

### v0.4 Polish & Launch (Planned)

- [ ] Speaker diarization (auto-detect, label, name)
- [ ] Batch file processing (queue, progress, batch export)
- [ ] Whisper mode (optimized for quiet speech)
- [ ] App Store submission (sandbox, notarize, privacy policy)

## For AI Coding Assistants

### Key Rules

1. **Specs are authoritative.** If code and spec disagree, the spec is correct (then fix the code).
2. **ADRs are locked.** Do not propose alternatives to locked decisions.
3. **Version order matters.** Implement v0.1 before v0.2. Do not jump ahead.
4. **Never lose user data.** Graceful degradation over silent failure.
5. **Local-first.** Audio and text never leave the device. No cloud APIs.
6. **One model.** Qwen3-4B for all LLM tasks. No Llama, no Ollama, no OpenAI.
7. **`swift test` is the gate.** All tests must pass before and after changes.

### Where to Start

1. Read this file (you're here)
2. Read `CLAUDE.md` in the project root for build instructions and codebase patterns
3. Check `plans/active/` for in-progress work
4. Check the version progress above for what needs doing next
