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
  <a href="https://deepwiki.com/moona3k/macparakeet"><img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue.svg" alt="GPL-3.0 License"></a>
  <img src="https://img.shields.io/badge/macOS-14.2%2B-000000.svg" alt="macOS 14.2+">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138.svg" alt="Swift 6">
  <img src="https://img.shields.io/badge/tests-passing-brightgreen.svg" alt="Tests passing">
  <img src="https://img.shields.io/badge/Apple%20Silicon-only-333333.svg" alt="Apple Silicon only">
</p>

<p align="center">
  <img src="Assets/screenshots/transcribe.png?v=4" width="720" alt="MacParakeet — Transcribe tab with YouTube, file drop, and Record Meeting tile">
</p>

<p align="center">
  <img src="Assets/screenshots/library.png?v=4" width="720" alt="MacParakeet — Transcription library with thumbnails">
</p>

<p align="center">
  <img src="Assets/screenshots/youtube-transcript.png?v=1" width="720" alt="MacParakeet — YouTube transcript with synced video playback and timestamped transcript, summary, and chat tabs">
</p>

<p align="center">
  <img src="Assets/screenshots/dictations.png?v=4" width="720" alt="MacParakeet — Dictation Stats with streak heatmap and top apps">
</p>

<p align="center">
  <img src="Assets/screenshots/meeting-recording.png?v=4" width="720" alt="MacParakeet — Live meeting recording with floating pill and Notes/Transcript/Ask panel">
</p>

<p align="center">
  <img src="Assets/screenshots/meeting-ask.png?v=4" width="720" alt="MacParakeet — Ask tab summarizing a live meeting with quick-prompt starters">
</p>

---

MacParakeet runs NVIDIA's Parakeet TDT on Apple's Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio) CoreML. The current stable release includes system-wide dictation, file/URL transcription, meeting recording, meeting calendar support, optional local WhisperKit recognition for languages Parakeet does not cover, and Transforms for selected-text rewrites. All speech recognition happens on your Mac.

## Release status

The [notarized DMG](https://downloads.macparakeet.com/MacParakeet.dmg) is the stable release channel.

| Channel | Status | Includes |
|---------|--------|----------|
| Stable DMG | Recommended for normal use | Dictation, file/video/YouTube transcription, meeting recording, meeting calendar reminders and opt-in auto-start, Transforms, optional WhisperKit, exports, vocabulary, AI features |
| `main` branch | Development | Latest stable release plus in-progress fixes and development changes, including beta media pause while dictating |

Meeting calendar support is live in the stable DMG. MacParakeet reads upcoming meetings from the local macOS Calendar store through EventKit, can show reminders, and can optionally start a recording after a countdown. Auto-start defaults to `.off` and must be opted into; recordings still stop manually.

## What it does

**Dictation** — Press a hotkey in any app, speak, text gets pasted. Hold for push-to-talk, or tap the hands-free shortcut to start and stop longer dictations. Works system-wide. A beta setting can pause supported Now Playing media while you dictate and resume it when capture stops.

**File transcription** — Drag audio or video files, or paste a YouTube URL. Full transcript with word-level timestamps, speaker labels, and export to 7 formats (TXT, Markdown, SRT, VTT, DOCX, PDF, JSON). Assign global hotkeys to trigger File or YouTube transcription from anywhere.

**Meeting recording** — Record system audio and microphone together, see a live local transcript preview, take notes during the call, then save the finalized transcript to the library with export, prompts, and chat.

**Meeting calendar support** — Grant Calendar access to get local reminders for upcoming meetings or opt into auto-start. MacParakeet uses calendars already configured in macOS Calendar through EventKit; it does not add Google or Microsoft sign-ins, and recordings still stop manually.

**Text cleanup** — Filler word removal, custom word replacements, text snippets with triggers. Deterministic pipeline, no LLM needed.

**AI features** — Optional summaries, chat, AI formatter, and Transforms for rewriting selected text through your configured provider. Connect any cloud provider (OpenAI, Anthropic, Gemini, OpenRouter), local runtime (Ollama, LM Studio), OpenAI-compatible endpoint, or CLI tool (Claude Code, Codex). Entirely opt-in.

### Performance

- ~155x realtime — 60 min of audio in ~23 seconds
- ~2.5% word error rate (Parakeet TDT 0.6B-v3)
- ~66 MB working memory per active Parakeet inference slot
- 25 European languages with Parakeet auto-detection
- Optional local WhisperKit engine for Korean, Japanese, Chinese, and many other languages

### Limitations

- Apple Silicon only (M1/M2/M3/M4)
- Parakeet is best for English and supported European languages
- WhisperKit multilingual support requires a separate local model download before first use

## Get it

**Download:** Grab the [notarized DMG](https://downloads.macparakeet.com/MacParakeet.dmg) or visit [macparakeet.com](https://macparakeet.com). Drag to Applications, done.

First launch downloads the speech model (~6 GB) plus speaker-detection assets (~130 MB). Everything works fully offline after that.

The DMG is the stable release.

**Standalone CLI (Homebrew):**

```bash
brew install moona3k/tap/macparakeet-cli
macparakeet-cli --version
macparakeet-cli health --json
```

The Homebrew formula installs the public `macparakeet-cli` surface plus
Homebrew-managed `ffmpeg` and `yt-dlp`. It shares the same local database and
model cache as the app.

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
macparakeet-cli transcribe /path/to/audio.mp3
macparakeet-cli transcribe /path/to/audio.mp3 --format transcript --no-history
macparakeet-cli models download whisper-large-v3-v20240930-turbo-632MB
macparakeet-cli models list
macparakeet-cli models select parakeet
macparakeet-cli transcribe /path/to/korean.mp3 --engine whisper --language ko --format json
macparakeet-cli models status
macparakeet-cli history
```

Use `--format transcript` for transcript-only stdout in shell pipelines. Add
`--no-history` when you want a one-off transcription without saving a completed
row to MacParakeet history. `models list` and `models select` inspect or update
the shared speech default used by the app and `--engine app-default`. The
Whisper CLI commands above require a downloaded local WhisperKit model. When
developing from source, prefix the same commands with `swift run`.

## Tech stack

| Layer | Choice |
|-------|--------|
| STT | Parakeet TDT 0.6B-v3 via [FluidAudio](https://github.com/FluidInference/FluidAudio) CoreML (default) + optional local WhisperKit engine |
| STT orchestration | Shared runtime + explicit scheduler with a reserved dictation slot and a shared meeting/file slot; speech-engine routing and meeting-session pinning |
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

- **Summarize** — After a transcription finishes, click Summarize and pick a prompt ("Summary", "Action Items & Decisions", "Chapter Breakdown", etc.) or write your own. The LLM processes the transcript and streams back a summary. You can generate multiple summaries per transcript, each in its own tab. Prompts marked as auto-run generate summaries automatically for new transcriptions.
- **Chat** — Ask questions about a transcript in a multi-turn chat interface. The LLM answers based on the transcript content.
- **AI formatter** — Optionally run your dictation and file transcripts through your AI provider to clean up grammar, punctuation, and paragraphing. Toggle on/off, customize the prompt, or reset to default.
- **Transforms** — Select text in any app and press a bound Transform hotkey, such as `Option-1` for Polish, to rewrite the selection through your configured LLM provider.

**Supported providers:**

| Type | Options |
|------|---------|
| Cloud | Anthropic (Claude), OpenAI, Google Gemini, OpenRouter |
| Local | Ollama, LM Studio |
| Custom | OpenAI-Compatible (any API-shaped endpoint — vLLM, LocalAI, LiteLLM, llama.cpp server, third-party hosts) |
| CLI subprocess | Claude Code, Codex, or another configured command |

**Setup:** In Settings → AI Provider, pick a provider, enter an API key (cloud) or confirm the local server/CLI command is available, select a model, and hit Test Connection. Cloud providers store keys in the macOS Keychain. Ollama and LM Studio can keep LLM inference on-device. CLI subprocess providers run the configured command locally, but that command may contact its own cloud service.

## Privacy

All speech recognition runs locally. Parakeet uses the Neural Engine; the optional WhisperKit engine also runs on-device. Your audio never leaves your Mac.

- **No cloud STT.** The model runs on-device. No audio is transmitted.
- **No accounts.** No login, no email, no registration.
- **Opt-out telemetry.** Non-identifying usage analytics and crash reporting go to a self-hosted endpoint only when telemetry is enabled. No persistent IDs, no IP storage, and no transcript/audio content is transmitted. [Source code is right here](Sources/MacParakeetCore/Services/Telemetry/TelemetryService.swift) — verify it yourself.
- **Temp files cleaned up.** Audio deleted after transcription unless you save it.

**What does use the network:** AI summaries and chat connect to configured LLM providers, or to whatever service a configured CLI tool chooses to use, when you choose them. Sparkle checks for app updates. YouTube transcription downloads video via yt-dlp. Telemetry and crash reports go to our self-hosted server unless you opt out. Core dictation and transcription stay fully offline.

**Note:** Builds from source also send telemetry by default. Opt out in Settings or set `MACPARAKEET_TELEMETRY_URL` to override.

## Contributing

- **Report bugs** — [Open an issue](https://github.com/moona3k/macparakeet/issues) with steps to reproduce and relevant logs or screenshots.
- **Discuss new work first** — For features or behavior changes, open an issue before starting a PR so we can agree on scope and product fit.
- **Submit scoped PRs** — Once the issue direction is clear, fork, make the scoped changes, run `swift test`, and link the issue in the PR.
- **Read the specs** — Architecture decisions and feature specs live in `spec/`

## Support

MacParakeet is free and open source. If it's useful to you, consider [sponsoring](https://github.com/sponsors/moona3k).

## License

GPL-3.0. Free software. [Full license](LICENSE).
