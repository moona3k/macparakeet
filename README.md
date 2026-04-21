<p align="center">
  <img src="Assets/AppIcon-1024x1024.png" width="128" height="128" alt="MacParakeet app icon">
</p>

<h1 align="center">MacParakeet</h1>

<p align="center">
  Fast voice app for Mac with fully local speech and optional AI. Free and open-source.
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
  <img src="https://img.shields.io/badge/tests-passing-brightgreen.svg" alt="Tests passing">
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

MacParakeet runs NVIDIA's Parakeet TDT on Apple's Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio) CoreML. It handles system-wide dictation and file/URL transcription. All speech recognition happens on your Mac.

## What it does

**Dictation** — Press a hotkey in any app, speak, text gets pasted. Hold for push-to-talk, double-tap for persistent recording. Works system-wide.

**File transcription** — Drag audio or video files, or paste a YouTube URL. Full transcript with word-level timestamps, speaker labels, and export to 7 formats (TXT, Markdown, SRT, VTT, DOCX, PDF, JSON). Assign global hotkeys to trigger File or YouTube transcription from anywhere.

**Text cleanup** — Filler word removal, custom word replacements, text snippets with triggers. Deterministic pipeline, no LLM needed.

**AI features** — Optional summaries, chat, and an AI formatter. Connect any cloud provider (OpenAI, Anthropic, Gemini, OpenRouter), local runtime (Ollama, LM Studio), OpenAI-compatible endpoint, or CLI tool (Claude Code, Codex). Entirely opt-in.

### Performance

- ~155x realtime — 60 min of audio in ~23 seconds
- ~2.5% word error rate (Parakeet TDT 0.6B-v3)
- ~66 MB working memory per active Parakeet inference slot
- 25 European languages with auto-detection

### Limitations

- Apple Silicon only (M1/M2/M3/M4)
- Best with English — supports 25 European languages but accuracy varies
- No CJK language support (Korean, Japanese, Chinese, etc.)

## Get it

**Download:** Grab the [notarized DMG](https://downloads.macparakeet.com/MacParakeet.dmg) or visit [macparakeet.com](https://macparakeet.com). Drag to Applications, done.

First launch downloads the speech model (~6 GB) plus speaker-detection assets (~130 MB). Everything works fully offline after that.

**Build from source:**

```bash
git clone https://github.com/moona3k/macparakeet.git
cd macparakeet
swift test
scripts/dev/run_app.sh    # build, sign, launch
```

The dev script creates a signed `.app` bundle so macOS grants mic and accessibility permissions. It disables target-level Xcode signing, then signs the finished bundle with the best available local identity. Override with `MACPARAKEET_CODESIGN_IDENTITY="Your Identity"` if needed.

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
| STT orchestration | Shared runtime + explicit scheduler with a reserved dictation slot and a shared batch slot for transcription |
| Language | Swift 6.0 + SwiftUI |
| Database | SQLite via GRDB |
| Auto-updates | Sparkle 2 |
| YouTube | yt-dlp |
| Platform | macOS 14.2+, Apple Silicon |

## Vocabulary

The Vocabulary panel controls how dictated text is cleaned up before pasting. No AI involved — it's a fast, deterministic pipeline that runs in under 1ms.

You choose between two **processing modes**:

- **Raw** — Paste exactly what the speech engine produces, no changes
- **Clean** (default) — Run the text through a multi-step pipeline before pasting

**The Clean pipeline** applies these steps in order:

1. **Filler removal** — Strips "um", "uh", and sentence-start fillers like "so", "well", "like"
2. **Custom words** — Applies your word replacement rules (e.g., "aye pee eye" becomes "API", or "kubernetes" gets capitalized to "Kubernetes"). Case-insensitive, whole-word matching. Words can be toggled on/off without deleting.
3. **Voice Return** — If you've defined a trigger phrase (e.g., "press return") and speak it at the end of a dictation, it's stripped from the output and a Return keypress is simulated after paste
4. **Snippet expansion** — Replaces short trigger phrases with longer text (e.g., "my signature" expands to "Best regards, David"). Triggers are natural language phrases because that's what the speech engine outputs. Matched longest-first to prevent collisions.
5. **Whitespace cleanup** — Collapses spaces, fixes punctuation spacing, capitalizes the first letter

Every dictation stores both the raw and clean transcript so you can always see what changed.

## AI Features

AI features are entirely **opt-in** and separate from speech recognition — transcription is always local. The LLM only sees transcript text, never audio.

**What it does:**

- **Summarize** — After a transcription finishes, click Summarize and pick a prompt ("Meeting Notes", "Action Items", "Key Quotes", etc.) or write your own. The LLM processes the transcript and streams back a summary. You can generate multiple summaries per transcript, each in its own tab. Prompts marked as auto-run generate summaries automatically for new transcriptions.
- **Chat** — Ask questions about a transcript in a multi-turn chat interface. The LLM answers based on the transcript content.
- **AI formatter** — Optionally run your dictation and file transcripts through your AI provider to clean up grammar, punctuation, and paragraphing. Toggle on/off, customize the prompt, or reset to default.

**Supported providers:**

| Type | Options |
|------|---------|
| Cloud | Anthropic (Claude), OpenAI, Google Gemini, OpenRouter |
| Local | Ollama, LM Studio |
| Custom | OpenAI-Compatible (any API-shaped endpoint — vLLM, LocalAI, LiteLLM, llama.cpp server, third-party hosts) |
| CLI | Claude Code, Codex (runs as subprocess) |

**Setup:** In Settings → AI Provider, pick a provider, enter an API key (cloud) or confirm the local server is running, select a model, and hit Test Connection. Cloud providers store keys in the macOS Keychain. Local providers (Ollama, LM Studio, CLI) keep everything on-device.

## Privacy

All speech recognition runs on the Neural Engine. Your audio never leaves your Mac.

- **No cloud STT.** The model runs on-device. No audio is transmitted.
- **No accounts.** No login, no email, no registration.
- **Opt-out telemetry.** Non-identifying usage analytics and crash reporting go to a self-hosted endpoint only when telemetry is enabled. No persistent IDs, no IP storage, and no transcript/audio content is transmitted. [Source code is right here](Sources/MacParakeetCore/Services/TelemetryService.swift) — verify it yourself.
- **Temp files cleaned up.** Audio deleted after transcription unless you save it.

**What does use the network:** AI summaries and chat connect to configured LLM providers or CLI tools when you choose them. Sparkle checks for app updates. YouTube transcription downloads video via yt-dlp. Telemetry and crash reports go to our self-hosted server unless you opt out. Core dictation and transcription stay fully offline.

**Note:** Builds from source also send telemetry by default. Opt out in Settings or set `MACPARAKEET_TELEMETRY_URL` to override.

## Contributing

- **Report bugs** — [Open an issue](https://github.com/moona3k/macparakeet/issues)
- **Submit a PR** — Fork, make changes, `swift test`, open a PR
- **Read the specs** — Architecture decisions and feature specs live in `spec/`

For larger changes, open an issue first.

## Support

MacParakeet is free and open source. If it's useful to you, consider [sponsoring](https://github.com/sponsors/moona3k).

## License

GPL-3.0. Free software. [Full license](LICENSE).
