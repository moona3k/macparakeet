# MacParakeet Spec Index

> Status: **ACTIVE** - Authoritative, current
> Runtime Note: FluidAudio CoreML is the active architecture. Core STT is local; optional LLM and telemetry features are opt-in; a fully local setup is supported when only local features/providers are used.

**MacParakeet** is a voice toolkit for macOS with on-device STT, optional AI and telemetry features, and support for a fully local setup.

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
| 11 | [LLM Integration](11-llm-integration.md) | LLM providers, summary, chat, transforms | Implemented (§1 summary superseded by spec/12) |
| 12 | [Processing Layer](12-processing-layer.md) | Prompt library, multi-summary, current v0.7 implementation contract | Active |
| 13 | [Agent Workflows](13-agent-workflows.md) | Future actions, workflows, agents, voice control, App Intents | Draft |

## Root Decisions (Locked)

These decisions are final. Do not second-guess them.

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Local STT | Parakeet TDT 0.6B-v3 via FluidAudio CoreML/ANE | 155x realtime, ~2.5% WER, fully local, ~66 MB working RAM |
| Database | SQLite via GRDB | Single file, embedded, zero config |
| Platform | macOS 14.2+ (Apple Silicon only) | FluidAudio requires Apple Silicon; Swift 6.0 |
| Business model | Free and open-source (GPL-3.0) | Originally $49 one-time (ADR-003), went free with open-source release in v0.5 |

## Architecture Decision Records (ADRs)

All ADRs live in `spec/adr/`. These are locked -- they record decisions already made.

| ADR | Decision |
|-----|----------|
| [ADR-001](adr/001-parakeet-stt.md) | Parakeet TDT 0.6B-v3 as primary STT engine |
| [ADR-002](adr/002-local-only.md) | Local processing with optional external AI/telemetry surfaces |
| [ADR-003](adr/003-one-time-purchase.md) | One-time purchase pricing ($49) |
| [ADR-004](adr/004-deterministic-pipeline.md) | Deterministic text processing pipeline |
| [ADR-005](adr/005-onboarding-first-run.md) | First-run onboarding flow |
| [ADR-006](adr/006-trial-and-license-activation.md) | Trial + license key activation |
| [ADR-007](adr/007-fluidaudio-coreml-migration.md) | FluidAudio CoreML migration (Python elimination) |
| [ADR-008](adr/008-local-llm-runtime-and-model.md) | Local LLM runtime baseline (historical — removed) |
| [ADR-009](adr/009-custom-hotkey.md) | Custom hotkey support (any single key + chord combos) |
| [ADR-010](adr/010-speaker-diarization.md) | Speaker diarization via FluidAudio offline pipeline |
| [ADR-011](adr/011-llm-cloud-and-local-providers.md) | LLM via cloud API keys + optional local providers |
| [ADR-012](adr/012-telemetry-system.md) | Self-hosted telemetry via Cloudflare (Worker + D1) |
| [ADR-013](adr/013-prompt-library-multi-summary.md) | Prompt Library + multi-summary architecture |
| [ADR-014](adr/014-meeting-recording.md) | Meeting recording via Core Audio Taps |

## Version Roadmap

| Version | Name | Focus | Status |
|---------|------|-------|--------|
| v0.1 | Core MVP | Dictation + transcription + history + settings | **Implemented** |
| v0.2 | Clean Pipeline | Deterministic text processing, custom words, snippets | **Implemented** |
| v0.3 | YouTube & Export | YouTube transcription, export formats | **Implemented** |
| v0.4 | Polish & Launch | Diarization, custom hotkey, non-blocking progress, direct distribution | **Implemented** |
| v0.5 | Data & Reliability | Private dictation, video metadata, multi-conversation chat, FTS5 cleanup, favorites | **Implemented** |
| v0.6 | Video Player & UI Revamp | Embedded video playback, split-pane detail view, library grid, thumbnail cards | **Implemented** |
| v0.7 | Prompt Library & Multi-Summary | Prompt library, multi-summary per transcript, custom instructions | **Implemented** |
| v0.6 | Meeting Recording | System audio + mic capture, local transcription, library integration | **Planned** |

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

### v0.3 YouTube & Export (Implemented)

- [x] YouTube URL transcription (yt-dlp + Parakeet)
- [x] Exports: TXT, Markdown, SRT, VTT (one-click to Downloads)
- [x] Full export (.docx, .pdf, .json)

### v0.4 Polish & Launch (Implemented)

- [x] Speaker diarization CLI preview (FluidAudio offline pipeline, ADR-010)
- [x] Speaker diarization GUI (summary panel + inline rename)
- [x] Custom hotkey support (any single key + chord combos, ADR-009)
- [x] Sparkle auto-updates
- [x] LLM provider integration (cloud API keys, summary + chat, ADR-011)
- [x] Private dictation mode
- [x] Newline escape in text snippets
- [x] Menu bar drag-and-drop
- [x] Hide dictation pill toggle
- [x] Voice stats dashboard
- [x] UI polish (toggles, sidebar sections, copy improvements)
- [x] Non-blocking transcription progress (bottom bar UX)
- [x] Distribution: Notarized DMG via macparakeet.com + LemonSqueezy, Sparkle auto-updates

### v0.5 Data & Reliability (Implemented)

- [x] Private dictation mode (hidden flag, excluded from history)
- [x] Word count caching for voice stats dashboard
- [x] Multi-conversation chat per transcription (migrated from single chatMessages field)
- [x] YouTube video metadata (thumbnail, channel name, description)
- [x] Transcription favorites with library filtering
- [x] FTS5 removal (unused search infrastructure dropped, search uses LIKE)
- [x] Open-source release (GPL-3.0)

### v0.6 Video Player & UI Revamp (Implemented)

- [x] YouTube video metadata expansion (thumbnailURL, channelName, videoDescription)
- [x] Thumbnail cache service (download YouTube thumbnails, FFmpeg frame extraction for local video)
- [x] HLS streaming for YouTube video playback (yt-dlp URL extraction + AVPlayer)
- [x] AVPlayer SwiftUI wrapper with subtitle overlay
- [x] MediaPlayerViewModel (state machine, 10Hz time sync, seek, play/pause)
- [x] Audio scrubber bar for audio-only files (44px horizontal bar)
- [x] Playback mode auto-detection (video/audio/none)
- [x] Split-pane detail view (video 40% left, tabbed content 60% right)
- [x] Synced transcript highlighting during playback (binary search, auto-scroll)
- [x] Clickable timestamp seeking in transcript tab
- [x] Video panel collapse (full → hidden)
- [x] Two side-by-side input cards on home page (YouTube + Local File)
- [x] Transcription library view with thumbnail grid
- [x] Library filter bar (All/YouTube/Local/Favorites)
- [x] Library search and sort

### v0.7 Prompt Library & Multi-Summary (Implemented)

- [x] `prompts` table + built-in/community prompt seeds
- [x] `summaries` table (one-to-many per transcription, cascade delete)
- [x] Prompt model + repository (CRUD, visibility toggle, built-in guard)
- [x] Summary model + repository (CRUD, replace for regeneration)
- [x] SummaryViewModel (extracted from TranscriptionViewModel)
- [x] PromptsViewModel (CRUD, validation, restore defaults)
- [x] Prompt picker + generation bar with model selector
- [x] Extra instructions field
- [x] Multi-summary tab navigation + queued pipeline
- [x] Management sheet (hide built-in/community, CRUD custom)
- [x] LLMService accepts custom system prompt
- [x] Migration from `transcriptions.summary` → `summaries`
- [x] Auto-run uses selected prompt cards; zero auto-run cards is supported

### v0.6 Meeting Recording (Planned)

- [ ] System audio capture via Core Audio Taps (macOS 14.2+), ported from Oatmeal
- [ ] Mic + system audio dual-stream recording (`MeetingAudioCaptureService`)
- [ ] `MeetingRecordingService` actor with protocol-based dependencies
- [ ] `MeetingRecordingFlowStateMachine` + coordinator (separate from dictation)
- [ ] Recording pill UI (floating NSPanel with timer + stop button)
- [ ] `sourceType` column on `transcriptions` table (file/youtube/meeting)
- [ ] "Meetings" sidebar item + "Record Meeting" in menu bar
- [ ] Library filter for meeting transcriptions
- [ ] Screen Recording permission handling (required, no mic-only fallback)
- [ ] Batch transcription after recording stops (Parakeet STT)
- [ ] Meeting recordings get prompt library, multi-summary, chat, and export automatically

## For AI Coding Assistants

### Key Rules

1. **Specs are authoritative.** If code and spec disagree, the spec is correct (then fix the code).
2. **ADRs are locked.** Do not propose alternatives to locked decisions.
3. **Version order matters.** Implement v0.1 before v0.2. Do not jump ahead.
4. **Never lose user data.** Graceful degradation over silent failure.
5. **Local-first.** Audio stays on-device for STT. Optional AI sends transcript text only to the user-configured provider or CLI tool. Telemetry is opt-out and self-hosted.
6. **`swift test` is the gate.** All tests must pass before and after changes.
8. **Kernel has precedence for implementation.** When present, `spec/kernel/*` artifacts define executable requirements and contracts.

### Where to Start

1. Read this file (you're here)
2. Read `CLAUDE.md` in the project root for build instructions and codebase patterns
3. Check `plans/active/` for in-progress work
4. Check the version progress above for what needs doing next
