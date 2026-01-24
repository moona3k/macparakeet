# CLAUDE.md

> Context for AI coding assistants working on MacParakeet.

## What is MacParakeet?

A **fast, private, local-first transcription app** for macOS powered by NVIDIA's Parakeet TDT.

**North Star:** The fastest, most private Mac transcription app. No subscriptions. No cloud.

## Quick Navigation

| Need | Go To |
|------|-------|
| Product vision | `spec/00-vision.md` |
| Feature spec | `spec/01-features.md` |
| Technical architecture | `spec/02-architecture.md` |
| Competitive research | `docs/competitive-analysis.md` |
| Implementation plans | `plans/` |

## Tech Stack (Decisions)

| Layer | Choice | Notes |
|-------|--------|-------|
| Platform | macOS 14.2+ | Apple Silicon only |
| Language | Swift 5.9+ | SwiftUI for UI |
| STT | Parakeet TDT 0.6B-v3 | Via parakeet-mlx, Python daemon (~6.3% WER) |
| Python | uv bootstrap | Bundled uv binary, isolated venv |
| LLM | MLX-Swift | Qwen3-4B for text refinement |

## Project Context

MacParakeet shares STT infrastructure with [Oatmeal](https://github.com/moona3k/oatmeal) but is a separate product:
- **Oatmeal** = Meeting memory app (meetings, entities, calendar integration)
- **MacParakeet** = Standalone transcription/dictation (simple, focused)

### Why Separate Products?

1. **SEO** - Capture "mac transcription", "macwhisper alternative" searches
2. **Simpler value prop** - "Fast local transcription" vs complex meeting memory
3. **Lower barrier** - Entry-level product funnels to Oatmeal
4. **Monetization** - One-time purchase model like MacWhisper ($49-69)

## Competitive Landscape

Direct competitors (see `docs/competitive-analysis.md`):

| App | Price | Our Advantage |
|-----|-------|---------------|
| MacWhisper | $69-79 | We have Parakeet first-class, they added it later |
| Superwhisper | $250 lifetime | 5x cheaper, Parakeet speed |
| VoiceInk | $19-39 | More features, better AI refinement |
| Spokenly | Free-$8/mo | One-time purchase, no subscription |
| Whisper Notes | $4.99 | More powerful, Parakeet support |

**Our differentiators:**
1. **Parakeet-first** - Built around fastest local STT model
2. **One-time purchase** - No subscription fatigue
3. **Privacy-first** - Zero cloud, zero tracking, zero accounts
4. **Simple** - Does one thing well (transcription)

## Current Phase

**v0.1 → MVP** (In Progress)

### v0.1 MVP Goals
- [ ] Core transcription (file → text)
- [ ] System-wide dictation (hotkey → paste)
- [ ] Basic export (TXT, SRT, VTT)
- [ ] Menu bar app interface
- [ ] Settings (model selection, hotkey config)

### Future Versions
- v0.2: AI text refinement (grammar, formatting)
- v0.3: YouTube URL transcription
- v0.4: Batch processing, speaker diarization
- v0.5: Meeting auto-detection

## Folder Structure

```
macparakeet/
├── CLAUDE.md           # This file
├── README.md           # Public-facing readme
├── Package.swift       # Swift package manifest
├── spec/               # Product specifications
│   ├── 00-vision.md    # Product vision
│   ├── 01-features.md  # Feature details
│   └── 02-architecture.md
├── docs/               # Research and analysis
│   └── competitive-analysis.md
├── plans/              # Implementation plans
│   ├── active/
│   └── completed/
├── Sources/
│   ├── MacParakeet/        # GUI app (SwiftUI)
│   └── MacParakeetCore/    # Shared library
├── Tests/
├── Assets/             # App icons
├── python/             # STT daemon (shared with Oatmeal)
│   └── macparakeet_stt/
└── scripts/
```

## Key Patterns

### STT Integration (Parakeet)
- Python daemon via JSON-RPC over stdin/stdout
- uv bootstraps Python environment on first run
- Parakeet TDT 0.6B-v3 returns word-level timestamps

### Architecture Principles
1. **Local-only** - Audio never leaves device
2. **Fast startup** - Menu bar app, always ready
3. **Simple UI** - One primary action (transcribe)
4. **Modular core** - MacParakeetCore can be shared

## Building

```bash
# Build GUI app
xcodebuild build -scheme MacParakeet -destination 'platform=OS X' -derivedDataPath .build/xcode

# Run
.build/xcode/Build/Products/Debug/MacParakeet.app/Contents/MacOS/MacParakeet

# Run tests
swift test
```

## Common Tasks

### Add transcription feature
1. Update `spec/01-features.md`
2. Add to `MacParakeetCore/Services/TranscriptionService.swift`
3. Add tests
4. Update UI in `MacParakeet/Views/`

### Test STT pipeline
```bash
# Python daemon test
cd python/macparakeet_stt
uv run python -m macparakeet_stt.server
```

## Marketing Site

Separate repo: [macparakeet-website](https://github.com/moona3k/macparakeet-website)
- Astro + Tailwind
- SEO-optimized landing page
- Domain: macparakeet.com

---

## Quick Checklist for AI Agents

Before starting work:
- [ ] Read this file (CLAUDE.md)
- [ ] Check current phase and scope
- [ ] Understand competitive positioning

After completing work:
- [ ] Run `swift test`
- [ ] Update docs if needed
- [ ] Keep it simple (resist feature creep)

---

*This file helps AI assistants understand the project quickly. Update it as the project evolves.*
