# MacParakeet

**The fastest, most private voice app for Mac.**

MacParakeet uses NVIDIA's Parakeet TDT model to power system-wide voice dictation and file transcription — entirely on your Mac, with zero cloud uploads.

## Two Modes

### System-Wide Dictation
Press `Fn` anywhere on your Mac → speak → polished text appears. Like WisprFlow, but 100% local.

- **Double-tap Fn** — Persistent recording (press Fn again to stop)
- **Hold Fn** — Push-to-talk (release to auto-stop and paste)

### File Transcription
Drag any audio or video file → get a transcript in seconds.

- Transcribe a 3-hour podcast in under 2 minutes (300x realtime)
- Word-level timestamps with confidence scores
- Export to TXT (SRT/VTT/DOCX planned)

## Why MacParakeet?

| | MacParakeet | WisprFlow | MacWhisper | Superwhisper |
|---|---|---|---|---|
| **Processing** | 100% Local | Cloud | Local | Local |
| **Speed** | 300x realtime | Varies (server) | 15-30x | 15-30x |
| **Price** | $49 once | $12-15/month | $30 Pro | $250 lifetime |
| **Privacy** | Zero cloud | Audio uploaded | Local | Local |
| **Command Mode** | Local LLM | Cloud LLM | No | No |
| **STT Engine** | Parakeet | Whisper (cloud) | Whisper + Parakeet | Whisper |

## Features

### Implemented (v0.1 + v0.2)

- **Blazing Fast** — Parakeet TDT STT, fully local
- **100% Private** — Audio never leaves your Mac. No accounts. No tracking.
- **System-Wide Dictation** — Fn double-tap (persistent) + hold-to-talk
- **File Transcription** — Drag-drop audio/video files, word timestamps
- **Smart Cleanup** — Deterministic 4-step pipeline (filler removal, custom words, snippets, whitespace)
- **Custom Words** — Domain vocabulary corrections and proper noun casing
- **Text Snippets** — Natural language triggers expand into longer text
- **Export** — Plain text export (`.txt`) + copy to clipboard
- **History** — Dictation + transcription history stored locally (SQLite, searchable)
- **CLI** — `macparakeet transcribe`, `history`, `health`, `flow process/words/snippets`

### Planned (v0.2+)

- **AI Refinement** — Qwen3-4B for formal, email, and code modes
- **Command Mode** — Local LLM edits for command-mode workflows
- **More Exports** — SRT/VTT/DOCX and other formats

## Requirements

- macOS 14.2+ (Sonoma)
- Apple Silicon Mac (M1 or later)
- 8GB RAM minimum (16GB recommended)

## Installation

Download from [macparakeet.com](https://macparakeet.com)

## Tech Stack

- **STT Engine**: Parakeet TDT 0.6B-v3 via MLX
- **LLM**: Qwen3-4B via MLX-Swift (local, for command mode)
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
| **Free** | $0 | Free tier plan (not enforced in this repo yet) |
| **Pro** | $49 (one-time) | Pro tier plan (licensing + feature gating not implemented here yet) |

## Development Philosophy

MacParakeet is built for **fast feedback loops**. AI agents make mistakes — but they're good at fixing them if they can detect them. So every component is designed to be verifiable without manual interaction:

- **Tests** — Unit and integration tests for all core logic (`swift test`)
- **CLI** — Headless interface to core services (transcribe files, test the pipeline) so changes can be verified without launching the GUI
- **Protocol-based services** — Mockable boundaries make isolated testing straightforward

The faster the feedback loop, the faster the agent self-corrects. If you can't confirm a change works by running a command, the change isn't done.

## Support

- Email: support@macparakeet.com
- Website: [macparakeet.com](https://macparakeet.com)

## License

Proprietary. All rights reserved.

---

Made for privacy-conscious Mac users who think faster than they type.
