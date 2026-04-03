<p align="center">
  <img src="Assets/AppIcon-1024x1024.png" width="128" height="128" alt="MacParakeet app icon">
</p>

<h1 align="center">MacParakeet</h1>

<p align="center">
  Fast, local-first voice app for Mac. Free and open-source.
</p>

<p align="center">
  <em>There are many voice transcription/dictation apps, but this one is mine.</em>
</p>

<p align="center">
  <a href="https://macparakeet.com">macparakeet.com</a>
</p>

<p align="center">
  <a href="https://downloads.macparakeet.com/MacParakeet.dmg"><img src="https://img.shields.io/badge/Download-DMG-E86B3B.svg?style=for-the-badge&logo=apple&logoColor=white" alt="Download DMG"></a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue.svg" alt="GPL-3.0 License"></a>
  <img src="https://img.shields.io/badge/macOS-14.2%2B-000000.svg" alt="macOS 14.2+">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138.svg" alt="Swift 6">
  <img src="https://img.shields.io/badge/tests-1090%20passing-brightgreen.svg" alt="1090 tests passing">
  <img src="https://img.shields.io/badge/Apple%20Silicon-only-333333.svg" alt="Apple Silicon only">
</p>

<p align="center">
  <img src="Assets/screenshots/transcribe.png?v=3" width="720" alt="MacParakeet — Transcribe view with YouTube and file input">
</p>

<p align="center">
  <img src="Assets/screenshots/library.png?v=3" width="720" alt="MacParakeet — Transcription library with thumbnails">
</p>

<p align="center">
  <img src="Assets/screenshots/dictations.png?v=3" width="720" alt="MacParakeet — Dictation history and voice stats">
</p>

---

MacParakeet runs NVIDIA's Parakeet TDT on Apple's Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio) CoreML. Press a hotkey, speak, text appears. Or drag a file and get a full transcript. All speech recognition happens on your Mac.

## What it does

**Dictation** — Press a hotkey in any app, speak, text gets pasted. Hold for push-to-talk, double-tap for persistent recording. Works system-wide.

**File transcription** — Drag audio or video files, or paste a YouTube URL. Full transcript with word-level timestamps, speaker labels, and export to 7 formats (TXT, Markdown, SRT, VTT, DOCX, PDF, JSON).

**Text cleanup** — Filler word removal, custom word replacements, text snippets with triggers. Deterministic pipeline, no LLM needed.

**AI features** — Optional transcript summarization and chat via your own API keys (OpenAI, Anthropic, Ollama, OpenRouter). Entirely opt-in.

### Performance

- ~155x realtime — 60 min of audio in ~23 seconds
- ~2.5% word error rate (Parakeet TDT 0.6B-v3)
- ~66 MB working memory during inference
- 25 European languages with auto-detection

### Limitations

- Apple Silicon only (M1/M2/M3/M4)
- Best with English — supports 25 European languages but accuracy varies
- No CJK language support (Korean, Japanese, Chinese, etc.)

## Get it

**Download:** Grab the [notarized DMG](https://downloads.macparakeet.com/MacParakeet.dmg) or visit [macparakeet.com](https://macparakeet.com). Drag to Applications, done.

First launch downloads the speech model (~6 GB). After that, dictation and transcription work fully offline.

**Build from source:**

```bash
git clone https://github.com/moona3k/macparakeet.git
cd macparakeet
swift test                # 1090 tests
scripts/dev/run_app.sh    # build, sign, launch
```

The dev script creates a signed `.app` bundle so macOS grants mic and accessibility permissions. Set `DEVELOPMENT_TEAM=YOUR_TEAM_ID` if needed.

**CLI:**

```bash
swift run macparakeet-cli transcribe /path/to/audio.mp3
swift run macparakeet-cli models status
swift run macparakeet-cli history
```

## Tech stack

| Layer | Choice |
|-------|--------|
| STT | Parakeet TDT 0.6B-v3 via [FluidAudio](https://github.com/FluidInference/FluidAudio) CoreML (Neural Engine) |
| Language | Swift 6.0 + SwiftUI |
| Database | SQLite via GRDB |
| Auto-updates | Sparkle 2 |
| YouTube | yt-dlp |
| Platform | macOS 14.2+, Apple Silicon |

## Privacy

All speech recognition runs on the Neural Engine. Your audio never leaves your Mac.

- **No cloud STT.** The model runs on-device. No audio is transmitted.
- **No accounts.** No login, no email, no registration.
- **Anonymous telemetry.** Non-identifying usage analytics, opt-out in Settings. No persistent IDs, no IP storage, no content transmitted. [Source code is right here](Sources/MacParakeetCore/Services/TelemetryService.swift) — verify it yourself.
- **Temp files cleaned up.** Audio deleted after transcription unless you save it.

**What does use the network:** AI Summary & Chat connects to LLM providers when you configure it with your own API keys. YouTube transcription downloads video via yt-dlp. Telemetry pings our server unless you opt out. Core dictation and transcription are fully offline.

**Note:** Builds from source also send telemetry by default. Opt out in Settings or set `MACPARAKEET_TELEMETRY_URL` to override.

## Contributing

- **Report bugs** — [Open an issue](https://github.com/moona3k/macparakeet/issues)
- **Submit a PR** — Fork, make changes, `swift test`, open a PR
- **Read the specs** — Architecture decisions and feature specs live in `spec/`

For larger changes, open an issue first.

## License

GPL-3.0. Free software. [Full license](LICENSE).

---

*Made for people who think faster than they type.*
