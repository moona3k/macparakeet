<p align="center">
  <img src="Assets/AppIcon-1024x1024.png" width="128" height="128" alt="MacParakeet app icon">
</p>

<h1 align="center">MacParakeet</h1>

<p align="center">
  The fastest, most private voice app for Mac.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue.svg" alt="GPL-3.0 License"></a>
  <img src="https://img.shields.io/badge/macOS-14.2%2B-000000.svg" alt="macOS 14.2+">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138.svg" alt="Swift 6">
  <img src="https://img.shields.io/badge/tests-807%20passing-brightgreen.svg" alt="807 tests passing">
  <img src="https://img.shields.io/badge/Apple%20Silicon-only-333333.svg" alt="Apple Silicon only">
</p>

---

MacParakeet runs NVIDIA's Parakeet TDT speech model on Apple's Neural Engine via FluidAudio CoreML. System-wide dictation and file transcription, entirely on your Mac. No cloud. No accounts.

<!-- TODO: add hero screenshot -->

## Features

**System-Wide Dictation** -- Press a hotkey anywhere on macOS, speak, text appears.

- Double-tap for persistent recording, hold for push-to-talk
- Configurable trigger: bare keys, modifiers, or chord combos (Fn default)
- Auto-paste with clipboard preservation
- Private dictation mode (skip saving to history)

**File Transcription** -- Drag audio or video files, get a transcript in seconds.

- 155x realtime: ~60 minutes of audio in ~23 seconds
- ~2.5% word error rate (Parakeet TDT 0.6B-v3)
- Word-level timestamps with confidence scores
- Speaker diarization (auto-detect and label speakers)
- YouTube URL transcription via yt-dlp

**Text Processing**

- Deterministic 4-step cleanup pipeline: filler removal, custom words, snippets, whitespace normalization
- Custom vocabulary for domain terms and proper nouns
- Text snippets with natural language triggers (supports `\n` for newlines)

**Export** -- TXT, Markdown, SRT, VTT, DOCX, PDF, JSON, or copy to clipboard.

**AI Summary & Chat** -- Summarize transcriptions and ask follow-up questions via cloud LLM providers (OpenAI, Anthropic, Ollama, OpenRouter). Optional -- bring your own API keys.

**Everything Else**

- Searchable dictation and transcription history (SQLite)
- Voice stats dashboard
- Automatic background updates via Sparkle (pre-built DMG)
- Menu bar app with drag-and-drop support
- 25 European languages with automatic detection

## Getting Started

### Download

Grab the latest notarized DMG from [macparakeet.com](https://macparakeet.com). Open it, drag to Applications, done.

On first launch, MacParakeet downloads the Parakeet speech model (~6 GB). After that, everything runs offline.

### Or Build from Source

See [Building from Source](#building-from-source) below.

## Requirements

- macOS 14.2+ (Sonoma or later)
- Apple Silicon (M1 or later)
- ~6 GB disk space for the speech model

## Building from Source

MacParakeet is a Swift Package Manager project. No Xcode project file needed.

```bash
# Clone
git clone https://github.com/moona3k/macparakeet.git
cd macparakeet

# Run tests
swift test

# Build, code-sign, and launch the dev app
scripts/dev/run_app.sh

# Or open in Xcode
open Package.swift
```

The dev script builds a signed `.app` bundle (`MacParakeet-Dev.app`) so macOS grants microphone and accessibility permissions. Set `DEVELOPMENT_TEAM=YOUR_TEAM_ID` if the default doesn't match your Apple Developer account.

### Build the CLI

```bash
swift build --target CLI
swift run macparakeet-cli --help
```

## CLI

MacParakeet includes an internal CLI for headless operation and development.

```bash
# Transcribe a file
swift run macparakeet-cli transcribe /path/to/audio.mp3

# Use a separate database for dev work
swift run macparakeet-cli transcribe recording.wav --database /tmp/macparakeet-dev.db

# Check STT model status
swift run macparakeet-cli models status

# View dictation history
swift run macparakeet-cli history
```

## Tech Stack

| Layer | Choice |
|-------|--------|
| STT Engine | Parakeet TDT 0.6B-v3 via FluidAudio CoreML (Neural Engine) |
| Language | Swift 6.0 + SwiftUI |
| Database | SQLite via GRDB |
| Auto-Updates | Sparkle 2 |
| YouTube | yt-dlp |
| Platform | macOS 14.2+, Apple Silicon |

## Privacy

MacParakeet processes everything locally. Your audio never leaves your Mac.

- **No cloud processing.** The speech model runs on the Neural Engine, not a server.
- **No accounts.** No login, no email, no registration.
- **Anonymous telemetry.** Non-identifying, session-scoped usage analytics help us improve the app. No persistent IDs, no IP storage, no audio or text content transmitted. Opt out anytime in Settings.
- **Temp files cleaned up.** Audio files are deleted after transcription unless you explicitly save them.

The optional AI Summary & Chat feature connects to external LLM providers only when you configure it with your own API keys and explicitly invoke it. Dictation and transcription never touch the network.

## Contributing

MacParakeet is open source and contributions are welcome.

- **Report bugs or request features** -- [Open an issue](https://github.com/moona3k/macparakeet/issues)
- **Submit a pull request** -- Fork the repo, make your changes, run `swift test`, and open a PR
- **Read the specs** -- Architecture decisions and feature specs live in `spec/`. Start with `spec/README.md` for an overview.

For larger changes, open an issue first to discuss the approach.

## License

MacParakeet is free software, released under the [GNU General Public License v3.0](LICENSE).

---

Made for people who think faster than they type.
