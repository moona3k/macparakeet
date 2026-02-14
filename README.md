# MacParakeet

**The fastest, most private voice app for Mac.**

> Migration Note: FluidAudio CoreML is the active target architecture. Specs/docs reflect target runtime behavior while implementation work is in progress.

MacParakeet uses NVIDIA's Parakeet TDT model — running on Apple's Neural Engine via FluidAudio CoreML — to power system-wide voice dictation and file transcription. Entirely on your Mac, with zero cloud uploads.

First-run onboarding prepares both local models (Parakeet STT + Qwen3-8B) so dictation and AI refinement are ready before you start using the app.

## Two Modes

### System-Wide Dictation
Press `Fn` anywhere on your Mac → speak → polished text appears. Like WisprFlow, but 100% local.

- **Double-tap Fn** — Persistent recording (press Fn again to stop)
- **Hold Fn** — Push-to-talk (release to auto-stop and paste)

Trigger key configurable in Settings (Fn, Control, Option, Shift, or Command).

### File Transcription
Drag any audio or video file → get a transcript in seconds.

- Transcribe a 1-hour podcast in under 25 seconds (155x realtime)
- Word-level timestamps with confidence scores
- Export to TXT, Markdown, SRT, and VTT (DOCX planned)

## Why MacParakeet?

| | MacParakeet | WisprFlow | MacWhisper | Superwhisper |
|---|---|---|---|---|
| **Processing** | 100% Local | Cloud | Local | Local |
| **Speed** | 155x realtime | Varies (server) | 15-30x | 15-30x |
| **Price** | $49 once | $12-15/month | $30 Pro | $250 lifetime |
| **Privacy** | Zero cloud | Audio uploaded | Local | Local |
| **Command Mode** | Local LLM | Cloud LLM | No | No |
| **STT Engine** | Parakeet | Whisper (cloud) | Whisper + Parakeet | Whisper |

## Features

### Implemented (v0.1 + v0.2)

- **Blazing Fast** — Parakeet TDT STT, fully local
- **100% Private** — Audio never leaves your Mac. No accounts. No tracking.
- **System-Wide Dictation** — Configurable hotkey (Fn default), double-tap (persistent) + hold-to-talk
- **File Transcription** — Drag-drop audio/video files, word timestamps
- **Smart Cleanup** — Deterministic 4-step pipeline (filler removal, custom words, snippets, whitespace)
- **AI Refinement Modes** — Formal, Email, and Code modes powered by local Qwen3-8B with deterministic fallback
- **Custom Words** — Domain vocabulary corrections and proper noun casing
- **Text Snippets** — Natural language triggers expand into longer text
- **Export** — TXT, Markdown, SRT, and VTT exports + copy to clipboard
- **History** — Dictation + transcription history stored locally (SQLite, searchable)
- **YouTube Transcription** — Paste a YouTube URL, auto-download audio via yt-dlp, transcribe with Parakeet
- **YouTube Audio Retention** — Downloaded YouTube audio is kept by default (configurable in Settings > Storage)

### Planned

- **Command Mode** — Local LLM edits for command-mode workflows
- **Chat with Transcript (GUI)** — Ask questions about your transcriptions via local LLM
- **More Exports** — DOCX and other formats

## Requirements

- macOS 14.2+ (Sonoma)
- Apple Silicon Mac (M1 or later)
- 8GB RAM minimum (16GB recommended)

## Installation

Download from [macparakeet.com](https://macparakeet.com)

## Tech Stack

- **STT Engine**: Parakeet TDT 0.6B-v3 via FluidAudio CoreML (Neural Engine)
- **LLM**: Qwen3-8B via MLX-Swift (local, for command mode + chat)
- **Framework**: Swift + SwiftUI
- **Database**: SQLite via GRDB
- **Platform**: macOS 14.2+ (Apple Silicon)

## Privacy

MacParakeet processes everything locally. Your audio is never:
- Uploaded to any server
- Stored outside your Mac
- Used for training AI models
- Accessible without your permission

## Pricing

| Tier | Price | Includes |
|------|-------|----------|
| **Free** | $0 | 7-day trial (full features) |
| **Pro** | $49 (one-time) | License unlock after trial (activation UI + local gating implemented; production checkout/variant config is provided at build time) |

## Development Philosophy

MacParakeet is built for **fast feedback loops**. AI agents make mistakes — but they're good at fixing them if they can detect them. So every component is designed to be verifiable without manual interaction:

- **Tests** — Unit and integration tests for all core logic (`swift test`)
- **Internal CLI** — Headless interface to core services (transcribe files, test the pipeline) so changes can be verified without launching the GUI
  - Tip: use `swift run macparakeet-cli transcribe ... --database /tmp/macparakeet-dev.db` to avoid writing into your real app database during dev.
  - Local LLM checks: `swift run macparakeet-cli llm smoke-test --stats`, `swift run macparakeet-cli llm refine formal "draft text"`, and `swift run macparakeet-cli llm chat "question" --transcript-file /path/to/transcript.txt`.
  - See `docs/cli-testing.md` for GUI-parity vs deterministic testing modes.
- **Protocol-based services** — Mockable boundaries make isolated testing straightforward

The faster the feedback loop, the faster the agent self-corrects. If you can't confirm a change works by running a command, the change isn't done.

## Support

- Email: support@macparakeet.com
- Website: [macparakeet.com](https://macparakeet.com)

## License

Proprietary. All rights reserved.

---

Made for privacy-conscious Mac users who think faster than they type.
