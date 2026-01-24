# MacWhisper Deep Dive

> Status: **RESEARCH** - Gathered 2026-01-24
> Source: Product Hunt, App Store, 9to5Mac, user reviews, release notes

## Executive Summary

MacWhisper is the dominant macOS transcription app, developed by indie developer Jordi Bruin (Good Snooze). Built on Whisper + Parakeet, with 4.8/5 rating on Product Hunt (1,886+ reviews). Won iMore's "App of the Year."

---

## Pricing

| Tier | Price | Source |
|------|-------|--------|
| Free | $0 | Tiny, Base, Small models |
| Pro (Gumroad) | ~$69 | Lifetime |
| Pro (App Store) | $79.99 | Lifetime |
| Subscription | $4.99/wk, $8.99/mo, $29.99/yr | App Store |

**Discounts:** 25% off for journalists, students, non-profits (email support@macwhisper.com)

---

## Complete Feature List

### Core Transcription
- On-device processing (100% local)
- Whisper models: Tiny, Small, Base, Medium, Large-V2, Large-V3, Large-V3 Turbo
- WhisperKit models (Apple Silicon optimized via CoreML)
- Parakeet v2 (added v13, English-only, 300x realtime)
- Speaker recognition (v12+, described as "spotty")
- Batch transcription (Pro only)

### Input Sources
- Audio: MP3, WAV, M4A, OGG, OPUS
- Video: MP4, MOV
- YouTube URLs (some restrictions)
- Meeting auto-record: Zoom, Teams, Webex, Skype, Discord, Slack, Chime
- System-wide dictation
- System audio (Screen Recording permission)

### Export Formats
- .srt, .vtt (subtitles)
- .docx, .pdf, .html
- .csv, .txt, Markdown
- .whisper (native format with audio + edits)

### Language Support
- 100+ languages for transcription
- Translation to 30+ languages
- DeepL API integration
- **Limitation:** No multilingual file support

### AI Features (Pro)
- ChatGPT, Claude, Groq, Ollama, xAI, Deepseek
- Custom OpenAI endpoints (Azure AI, self-hosted)
- Pre-defined prompts (summaries, action items)
- Custom prompts
- Dictation cleanup

### Additional Features
- Menu bar only mode
- Full-text search across transcripts
- Segment view by speaker
- Transcript customization (font, color, padding)
- History sidebar
- Built-in video player with sync
- iOS/iPad app

---

## Technical Specs

### Model Performance

| Model | Size | RAM | Speed | Accuracy |
|-------|------|-----|-------|----------|
| Tiny | ~75MB | 4GB | Fastest | Lower |
| Base | ~150MB | 4GB | Fast | Moderate |
| Small | ~500MB | 4GB | Moderate | Good |
| Medium | ~1.5GB | 8GB+ | Slow | Very Good |
| Large-V2 | ~3GB | 8GB+ | Slowest | Excellent |
| Large-V3 | ~3GB | 8GB+ | Slowest | Best |
| Large-V3 Turbo | ~3GB | 8GB+ | Fast | Best |

### Parakeet Stats
- Speed: 300x realtime on M-series
- Accuracy: 6.05% WER (vs Whisper 7-12%)
- 3-hour podcast in 82 seconds on M2 Pro
- Speaker diarization included
- English-only (multilingual coming)

### Requirements
- macOS 14.0+ (Sonoma)
- 8GB RAM minimum, 16GB recommended
- Apple Silicon recommended (Intel "significantly slower")

### Known Issues
- Large models require 8GB+ RAM
- Long files (5+ hours) cause memory leaks
- 8GB RAM users report crashes with Large models
- Intel Macs: poor performance

---

## Version History

| Version | Date | Key Features |
|---------|------|--------------|
| 1.0 | Jan 2023 | Initial release |
| 8.0 | May 2024 | Video player, WhisperKit, ChatGPT 4o |
| 11.0 | Dec 2024 | Redesigned sidebar, menu bar mode |
| 12.0 | Mar 2025 | Automatic speaker recognition |
| 13.0 | Jun 2025 | NVIDIA Parakeet support |
| 13.10.4 | Current | Latest |

---

## User Sentiment

### What Users Love
- "I could not imagine my work anymore without this tool"
- "One of the best value for money tools I have ever bought"
- "The accuracy, especially when using the largest model, is FANTASTIC"
- "Fast, accurate, and private on-device transcription"
- "The free version is sufficient for a lot of cases"
- Frequent updates praised

### Common Complaints
- **Speaker diarization:** "a bit spotty", "frequently associates one word to wrong speaker"
- **Accuracy:** "endless loops, repeating the same sentence dozens of times"
- **UI complexity:** "Crucial technical settings are hidden"
- **Formatting:** "very good in terms of accuracy but terrible for formatting"
- **No multilingual files:** Can't transcribe mixed-language content
- **No GitHub:** "Should really have his own GitHub repository"

---

## Developer Background

**Jordi Bruin** - Indie dev, Netherlands
- Studio: Good Snooze
- 12+ years iOS/macOS experience
- 20+ apps in 2 years, 7 App Store features
- Philosophy: "2-2-2 method" (MVP 2 hours, refine 2 days, launch 2 weeks)
- Other apps: Soosee, Navi, Posture Pal, MacGPT, Vivid

---

## MacParakeet Opportunities

### Weaknesses to Exploit
1. Parakeet added as afterthought (v13) - we're Parakeet-first
2. Speaker diarization buggy - opportunity to do better
3. UI complexity (50+ features) - we stay simple
4. No GitHub for issues - we can be more transparent
5. Multilingual files not supported
6. $79 price - we're $49

### Strengths to Match
1. One-time purchase model ✓
2. Local processing ✓
3. Native macOS UI ✓
4. Meeting auto-recording (planned v0.4)
5. YouTube transcription (planned v0.3)
6. Comprehensive export (planned v0.3)

---

## Sources

- [MacWhisper Gumroad](https://goodsnooze.gumroad.com/l/macwhisper)
- [Product Hunt](https://www.producthunt.com/products/macwhisper)
- [App Store](https://apps.apple.com/us/app/whisper-transcription/id1668083311)
- [Support Docs](https://macwhisper.helpscoutdocs.com/)
- [Release Notes](https://macwhisper-site.vercel.app/release_notes.html)
- [9to5Mac - MacWhisper 12](https://9to5mac.com/2025/03/18/macwhisper-12-delivers-the-most-requested-feature-to-the-leading-ai-transcription-app/)
- [9to5Mac - Parakeet Support](https://9to5mac.com/2025/06/27/macwhisper-13-supports-nvidia-parakeet-transcription-model/)
