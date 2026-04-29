# MacParakeet: Vision & Philosophy

> Status: **ACTIVE** - Authoritative, current
> The fastest, most private voice app for Mac. Fully local speech, optional networked features, free and open-source (GPL-3.0).
> Pricing amendment: The current public build is free, GPL-3.0, and fully unlocked. Older "$49 one-time purchase" and trial-tier language is historical, but GPL-compatible official paid distribution, support, hosted services, or future paid builds remain valid options. The retained purchase activation plumbing must not be removed as dead code without explicit owner direction and an ADR/spec update.

---

## The North Star

**The fastest, most private voice app for Mac. Fully local speech when you want it. No required cloud subscription for core speech.**

```
+-----------------------------------------------------------------------+
|                                                                       |
|   CLOUD DICTATION (WisprFlow, Otter)                                  |
|   ---------------------------------                                   |
|   Voice -> Server -> Wait -> Text -> $12-15/mo forever                |
|                                                                       |
|   LOCAL BUT COMPLEX (MacWhisper, Superwhisper)                        |
|   -------------------------------------------                         |
|   Voice -> Configure -> Select model -> Text -> $30-$250             |
|                                                                       |
|   MacPARAKEET                                                         |
|   -----------                                                         |
|   Voice -> Text. Done. Local-first and GPL open-source.               |
|                                                                       |
+-----------------------------------------------------------------------+
```

Three modes. That is the entire product:

1. **Dictate anywhere** -- Press Fn (or your configured hotkey), speak, release. Text appears where your cursor is.
2. **Drop a file** -- Drag audio/video in. Get a transcript out.
3. **Record a meeting** -- Capture system audio + mic, get a transcript when you stop.

Everything else exists to make those three modes faster, smarter, and more useful.

---

## Why MacParakeet Exists

**The problem:** Mac users who want voice-to-text face a bad tradeoff:

| Option | Speed | Privacy | Price | Simplicity |
|--------|-------|---------|-------|------------|
| **Cloud services** (WisprFlow, Otter) | Fast | Your audio on their servers | $12+/mo forever | Simple |
| **Local apps** (MacWhisper, Superwhisper) | Good | Private | $30-$250 | Complex or expensive |
| **Apple Dictation** | Slow | Mostly local | Free | Very limited |
| **MacParakeet** | **Fastest** | **Can be fully local** | **Current public build free/GPL** | **Three modes** |

No existing app nails all four: **Speed + Privacy + Simplicity + Fair Pricing**.

Cloud services send your voice to remote servers, create accounts, charge monthly, and add server latency. Local apps either bury you in settings (MacWhisper has 50+ features) or charge a premium (Superwhisper at $250). Apple Dictation is free but slow, inaccurate, and has no custom vocabulary, no file transcription.

**MacParakeet's answer:** Built from the ground up around Parakeet TDT for speed, with optional local WhisperKit for languages Parakeet does not cover. Fully local speech by default, with optional networked features. Three modes. Simple and GPL open-source. Done.

---

## Core Philosophy

### 1. Speed Is the Feature

Parakeet TDT 0.6B-v3 transcribes 60 minutes of audio in ~23 seconds (155x realtime on the Neural Engine via FluidAudio CoreML). Dictation latency is under 500ms. This is not incremental improvement -- it is a category shift.

Speed changes behavior. When transcription takes 30 seconds, you think about whether it is worth doing. When it takes 0.5 seconds, you just talk. MacParakeet makes voice the faster input method for everything: emails, messages, code comments, documents, notes.

### 2. Privacy Is the Brand

Fully local speech is a core product property, and the app can stay fully local when configured that way.

- Local STT. No cloud speech processing, no accounts, no required backend for core speech.
- Audio never leaves your Mac for dictation or transcription.
- No email signup. No login. Optional self-hosted telemetry can be disabled in Settings.
- Works in airplane mode, air-gapped environments, classified settings.

This is not privacy theater ("your data is encrypted in transit"). This is privacy by architecture: there is no server to send data to.

### 3. Simplicity Over Features

MacWhisper has 50+ features. MacParakeet has three modes.

- **Dictate** -- Press Fn, speak, text appears at cursor. Works in any app.
- **Transcribe** -- Drop a file, get text out. Audio, video, YouTube links.
- **Record** -- Capture a meeting (system audio + mic), get a transcript.

Every feature we add must pass the test: "Does this make dictation, transcription, or meeting recording better?" If not, it does not ship.

### 4. Modern, Not Minimalist

Simple does not mean basic. MacParakeet includes modern capabilities that cloud competitors pioneered, but runs them locally:

- **Clean Pipeline** -- Deterministic text processing: filler removal, custom word replacement, snippet expansion, whitespace normalization. Professional output with zero latency.
- **Custom Words** -- Teach it your vocabulary. Technical terms, proper nouns, acronyms. Anchors that improve recognition accuracy.
- **Context Awareness** -- (Future) Reads the surrounding text to produce better transcriptions. Knows "React" in a code editor, "react" in a therapy note.

### 5. Free and Open-Source, Monetizable Official Distribution

The current public build has no price tags, subscriptions, or feature gates. MacParakeet is free and open-source (GPL-3.0), and every core feature is available in the current official build.

That does not mean monetization is permanently forbidden. GPL permits charging for distribution, and MacParakeet may later sell official signed/notarized builds, support, hosted services, team features, or paid official distribution while preserving recipients' GPL rights. The old LemonSqueezy/trial entitlement plumbing is intentionally retained for that future option and must not be removed as dead code without explicit owner direction and an ADR/spec update.

---

## What MacParakeet Is

| Attribute | Description |
|-----------|-------------|
| **Product type** | Native macOS app (menu bar + window) |
| **Core function** | Voice dictation, file transcription, and meeting recording |
| **Target users** | Developers, professionals, writers who want fast private voice input |
| **Key differentiators** | Parakeet speed + optional local multilingual Whisper fallback + free/open-source |
| **Business model** | Current public build is free/GPL/unlocked; official paid distribution, support, or hosted services remain possible |
| **Platform** | macOS 14.2+, Apple Silicon only |

---

## What MacParakeet Is Not

- **Not a full meeting intelligence app** -- MacParakeet records and transcribes meetings, has lightweight calendar auto-start, live notes, Ask, and prompt-based action summaries. It does not do entity extraction, cross-meeting memory, CRM-style enrichment, or team intelligence. That deeper intelligence layer is Oatmeal.
- **Not a note-taking app** -- It puts text where your cursor is. Your note app is your note app.
- **Not a cloud service** -- No hosted transcription backend, no accounts, no sync product. Core speech stays local.
- **Not an enterprise product** -- Single-user, single-Mac. No admin console, no team management (initially).
- **Not a mobile app** -- macOS only. Apple Silicon required for the local speech stack.
- **Not a transcription editor** -- Drop a file, get text. We do not build a full editing environment around transcripts.

---

## The MacParakeet Experience

### Mode 1: Dictate Anywhere

```
+-----------------------------------------------------------------------+
|  Any app. Any text field. Any time.                                   |
|                                                                       |
|  1. Press and hold Fn (or double-tap Fn)                              |
|  2. Speak naturally                                                   |
|  3. Release Fn                                                        |
|  4. Clean text appears at cursor in <500ms                            |
|                                                                       |
|  +-----------------------------------------+                          |
|  |  [Fn held]  Recording...  0:03          |  <-- floating pill        |
|  +-----------------------------------------+                          |
|                                                                       |
|  Works in: Slack, VS Code, Mail, Pages,                               |
|  Terminal, browsers -- everywhere.                                    |
+-----------------------------------------------------------------------+
```

- System-wide. Works in every app that accepts text input.
- Floating pill overlay shows recording status. Unobtrusive.
- Clean pipeline processes output: capitalization, punctuation, number formatting.
- Custom words ensure your vocabulary is transcribed correctly.

### Mode 2: Transcribe Files

```
+-----------------------------------------------------------------------+
|  +---------------------------+                                        |
|  |                           |                                        |
|  |   Drop audio or video     |     Supported:                        |
|  |   files here              |     .mp3 .wav .m4a .mp4 .mov          |
|  |                           |     .webm .ogg .flac .aac             |
|  |   [Browse Files]          |     YouTube URLs                       |
|  |                           |                                        |
|  +---------------------------+                                        |
|                                                                       |
|  Recent Transcriptions:                                               |
|  +-----------------------------------------------------------+       |
|  | meeting-recording.m4a      | 47:23  | 12s  | Completed    |       |
|  | podcast-ep-42.mp3          | 1:12:00| 18s  | Completed    |       |
|  | interview-notes.wav        | 22:15  | 6s   | Completed    |       |
|  +-----------------------------------------------------------+       |
|                                                                       |
|  Export: [Copy] [TXT] [SRT] [VTT] [Markdown]                         |
+-----------------------------------------------------------------------+
```

- Drag and drop. Or paste a YouTube URL.
- Progress indicator with ETA based on file duration.
- Multiple export formats: plain text, SRT subtitles, VTT, Markdown.
- Transcription history with search.

### Mode 3: Record a Meeting

```
+-----------------------------------------------------------------------+
|  Capture system audio + mic. Transcribe locally.                      |
|                                                                       |
|  1. Click "Record Meeting" (or press meeting hotkey)                  |
|  2. Grant Screen Recording permission (first time only)               |
|  3. Meeting pill appears — recording system audio + mic               |
|  4. Click Stop when done                                              |
|  5. Local STT transcribes source audio (Parakeet by default)          |
|  6. Result saved to library with full export/prompt support            |
|                                                                       |
|  Runs concurrently with dictation (ADR-015).                          |
|  Dictate a Slack message while your meeting is being recorded.        |
+-----------------------------------------------------------------------+
```

- Dual-stream capture: system audio (Core Audio Taps) + mic (AVAudioEngine)
- Floating recording pill with elapsed timer and stop button
- Results stored as `Transcription` with `sourceType = .meeting` — gets export, prompts, summaries, chat for free
- Requires Screen Recording permission (macOS 14.2+)

> **Historical note:** This slot was originally "Command Mode (Pro)" which was removed in 2026-02. Meeting recording replaced it as Mode 3 in v0.6.

---

## Target Users

### Primary: Developers and Power Users

The people who would use WisprFlow if it were not cloud-dependent. They type fast already, but voice is faster for certain tasks: writing long messages, thinking out loud, dictating documentation. They care deeply about privacy and dislike subscriptions.

**What they want:** Fast dictation that works in VS Code, Terminal, Slack. No cloud, no subscription, no bloat.

### Secondary: Privacy-Conscious Professionals

Lawyers handling confidential case notes. Healthcare professionals with HIPAA constraints. Journalists protecting sources. Security researchers in air-gapped environments. Government and defense contractors with data sovereignty requirements.

**What they want:** Absolute certainty that audio never leaves the device. No accounts, no tracking, no terms-of-service loopholes. Compliance-friendly architecture.

### Tertiary: Subscription-Fatigued Users

MacWhisper and Superwhisper users who balk at paying $30-$250. WisprFlow users tired of $144-180/year. People who searched "MacWhisper alternative" or "WisprFlow free alternative."

**What they want:** A good product without recurring charges. Free and open-source.

### Quaternary: Writers and Content Creators

Writers who think better out loud. Podcasters who need episode transcripts. Content creators making captions and subtitles. Students transcribing lectures. Anyone who produces text and prefers speaking to typing.

**What they want:** Fast file transcription with good export formats. Clean output that needs minimal editing. Reliable custom vocabulary for domain-specific terms.

---

## Competitive Position

```
                         SPEED + ACCURACY
                               |
                               |
            MacParakeet -------+----------------- WisprFlow
            (free, local,      |                  ($144-180/yr, cloud,
             Parakeet 155x)    |                   fast but server delays)
                               |
                               |
   PRIVATE -------------------+------------------------------- CLOUD
                               |
                               |
            MacWhisper --------+----------------- Otter.ai
            ($30, local,       |                  ($100/yr, cloud,
             Whisper 15-30x)   |                   meeting-focused)
                               |
                               |
                          SLOW + COMPLEX
```

### Head-to-Head Comparison

| Feature | MacParakeet | WisprFlow | MacWhisper | Superwhisper | Apple Dictation |
|---------|-------------|-----------|------------|--------------|-----------------|
| **STT Engine** | Parakeet default + optional WhisperKit | Cloud AI | Whisper | Whisper | Apple Neural |
| **Speed (60 min)** | ~23 sec | ~30 sec* | ~2-4 min | ~2-4 min | Real-time only |
| **WER** | ~2.5% | ~5%** | 7-12% | 7-12% | ~10-15% |
| **Privacy** | Local-first speech | Cloud | Local | Local | Mostly local |
| **Dictation** | Yes | Yes | No | Yes | Yes |
| **File transcription** | Yes | No | Yes | Limited | No |
| **Meeting recording** | Yes | No | No | No | No |
| **Smart cleanup** | Deterministic | Cloud AI | No | Cloud AI | No |
| **Custom words** | Yes | Yes | Limited | No | No |
| **Price** | Current public build free/GPL | $144-180/yr | $30 once | $250 once | Free |
| **Account required** | No | Yes | No | Yes | Apple ID |

*WisprFlow speed includes network latency.
**WisprFlow accuracy estimated; uses proprietary cloud models.

### Why We Win Each Segment

- **vs WisprFlow**: Same speed class, but a fully local speech option + free vs $144-180/year. WisprFlow users who care about privacy or cost switch to us.
- **vs MacWhisper**: Faster default engine, simpler three-mode product, plus system-wide dictation and free/open-source distribution.
- **vs Superwhisper**: Free vs $250, Parakeet-first architecture. No contest on price.
- **vs Apple Dictation**: Faster, more accurate, custom words, file transcription. Same price (free), dramatically more capable.

---

## Competitive Advantages

### 1. Parakeet-First Architecture

We are not a Whisper app that added Parakeet. We built the entire product around Parakeet TDT 0.6B-v3 from day one, then added WhisperKit explicitly for language coverage.

- **155x realtime** on the Neural Engine vs Whisper's 15-30x. Not an incremental improvement -- an order of magnitude.
- **~2.5% WER** -- lower error rate than Whisper large-v3 at a fraction of the compute.
- **Word-level timestamps** -- enables synced subtitles, precise seeking, confidence scoring.
- **Technical vocabulary** -- better handling of code terms, acronyms, and proper nouns than Whisper.

Competitors bolted Parakeet onto existing Whisper architectures. We optimized the default pipeline for Parakeet while routing optional Whisper through the same scheduler/runtime control plane.

### 2. Local-First, Zero-Compromise Speech

This is not "cloud by default with a local mode." Core speech recognition runs entirely on-device. There is no cloud STT path, no account system, and no requirement to send audio anywhere.

Optional network features exist, but they are explicit and separate: transcript text can be sent to user-configured LLM providers, Sparkle checks for updates, YouTube imports download media, and self-hosted telemetry can be disabled. The privacy boundary is simple: speech stays local.

### 3. Free and Open-Source

In a market of subscriptions ($144-180/yr for WisprFlow) and premium pricing ($250 for Superwhisper), the current free and open-source build is the adoption wedge: no pricing objection, no trial friction, no conversion funnel. Future monetization should sell official convenience, support, hosted services, or team workflows without undermining local-first GPL distribution.

### 4. Focused Simplicity

Three modes. Not twenty. Not fifty.

The product surface area is intentionally small. This means fewer bugs, faster iteration, easier onboarding, and a UI that does not require a tutorial. If a user cannot figure out MacParakeet in 30 seconds, we have failed.

---

## Licensing

MacParakeet is open-source under the **GPL-3.0** license. Current public builds are free and fully unlocked. The source code is public at [github.com/moona3k/macparakeet](https://github.com/moona3k/macparakeet).

> Historical note: MacParakeet was originally planned as a $49 one-time purchase (see ADR-003). The decision to go free/open-source in v0.5 maximized adoption and community contribution. It did not permanently ban GPL-compatible paid official distribution, support, hosted services, or future paid builds.

---

## Relationship to Oatmeal

MacParakeet and Oatmeal are **separate products** that share underlying technology.

```
+-----------------------------------------------------------------------+
|                       Shared Technology                                |
|  +---------------------------------------------------------------+    |
|  |  FluidAudio CoreML (STT on Neural Engine)                      |    |
|  |  Text processing pipeline (raw/clean modes)                    |    |
|  +---------------------------------------------------------------+    |
+-----------------------+-----------------------------------------------+
|    MacParakeet        |              Oatmeal                          |
|    (Voice App)        |              (Meeting Memory)                  |
|                       |                                               |
|  - Dictate anywhere   |  - Calendar integration                       |
|  - Transcribe files   |  - Entity extraction                          |
|  - Record meetings    |  - Cross-meeting memory                       |
|  - Custom words       |  - Action items                               |
|  - YouTube import     |  - Knowledge graph                            |
|  - Export formats     |  - Pre-meeting briefs                         |
|  Simple, focused      |  Complex, powerful                            |
|  Current public build free/GPL |  TBD                                  |
+-----------------------+-----------------------------------------------+
```

### Key Distinctions

| Dimension | MacParakeet | Oatmeal |
|-----------|-------------|---------|
| **Purpose** | Voice input, transcription, meeting recording | Meeting memory and knowledge |
| **Scope** | Text in, text out, meetings transcribed | Meetings, entities, relationships, patterns |
| **Complexity** | Three modes | Full knowledge system |
| **User relationship** | Tool (use and forget) | System (compounds over time) |
| **Codebase** | Independent | Independent |
| **Revenue** | Current public build free/GPL; official paid distribution/support possible | TBD |

### Strategic Relationship

- **Standalone value**: MacParakeet is a complete product on its own. It does not require or reference Oatmeal.
- **Funnel potential**: MacParakeet records and transcribes meetings. Users who want intelligence on top (calendar sync, entity extraction, cross-meeting memory) are natural Oatmeal prospects.
- **Adoption timing**: MacParakeet builds community and mindshare while Oatmeal matures. Simpler product = faster to market.
- **Technology proving ground**: Parakeet integration and clean pipeline are battle-tested in MacParakeet before being used in Oatmeal.

---

## Success Metrics

### Year 1 Targets

| Metric | Target | How We Measure |
|--------|--------|----------------|
| Downloads | 10,000 | Website analytics + telemetry |
| GitHub stars | 1,000 | GitHub |
| User satisfaction | 4.5+ stars equivalent | Community feedback + NPS |
| Daily active users | 2,000 | Telemetry (opt-in, anonymized) |
| Dictation sessions/user/day | 5+ | Local metrics |

### Quality Metrics

| Metric | Target |
|--------|--------|
| Dictation latency (press-to-text) | < 500ms |
| Transcription speed (60 min file) | < 30s on M1, < 15s on M1 Pro+ |
| Word error rate | < 3% (Parakeet via FluidAudio CoreML: ~2.5%) |
| App crash rate | < 0.1% of sessions |
| First-use success rate | > 95% (user dictates successfully on first try) |

### The Ultimate Test

A new user should be able to:

1. Download MacParakeet
2. Open it
3. Hold Fn and speak a sentence
4. See clean text appear at their cursor
5. Think "this is better than anything I have tried"

All within 60 seconds of first launch. A short permissions/model setup flow is acceptable; accounts and tutorials are not.

---

## Product Roadmap

### v0.1: MVP -- Core Engine

The foundation. Dictation works. File transcription works. It is fast.

- Parakeet STT integration (FluidAudio CoreML on Neural Engine)
- System-wide dictation (Fn trigger, configurable, floating overlay)
- File transcription (drag-and-drop, common audio/video formats)
- Basic UI (menu bar app, transcription window)
- Settings (audio input selection, output preferences)

### v0.2: Clean Pipeline

Clean pipeline makes dictation output polish-ready.

- Clean text pipeline (deterministic: filler removal, custom words, snippets)
- Custom words & snippets management UI
- In-app feedback

### v0.3: YouTube & Export

YouTube transcription and full export pipeline.

- YouTube URL transcription (yt-dlp + local STT)
- Export formats (.txt, .srt, .vtt, .docx, .pdf, .json)

### v0.4: Polish + Launch

Ship-quality polish. Direct distribution via notarized DMG.

- Onboarding flow (permissions, first dictation)
- Notarized DMG distribution (macparakeet.com/R2 + Sparkle)
- Sparkle auto-updates
- Marketing site (macparakeet.com)
- Accessibility (VoiceOver, keyboard navigation)
- UI Localization (English UI first, structure for future languages; STT already supports 25 European languages)

### v0.6: Meeting Recording

- System audio + mic capture with fragmented source files and crash recovery
- Live meeting pill + Notes / Transcript / Ask panel
- Calendar auto-start/auto-stop affordances
- Source-aware final transcription with prompt results and chat in the library

### v0.7: Multilingual STT

- Optional local WhisperKit engine for languages outside Parakeet coverage
- Settings speech-engine picker and Whisper language picker
- CLI `transcribe --engine parakeet|whisper --language`
- Meeting recordings pin engine/language for live preview, recovery, and finalization

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Platform** | macOS 14.2+, Apple Silicon only | FluidAudio CoreML requires Apple Silicon. |
| **STT engine** | Parakeet TDT 0.6B-v3 by default; optional WhisperKit | Parakeet gives the latency target for supported languages; WhisperKit keeps broader multilingual speech local. |
| **YouTube downloads** | Standalone yt-dlp | macOS binary, auto-updates via `--update`. No Python needed. |
| **UI framework** | SwiftUI | Native Mac experience. Menu bar + window. |
| **Database** | SQLite (GRDB) | Single file. No server. Dictation history, custom words, settings. |
| **Cloud option** | No cloud STT; optional LLM providers | Core speech stays local. AI and media downloads are user-triggered; updates and opt-out telemetry/crash reporting are product-managed network surfaces. Retained purchase activation endpoints remain in code but current public builds are free/unlocked. |
| **Pricing** | Current public build free/GPL | Zero friction today; GPL-compatible official paid distribution/support remains available later. |

---

## Naming

**MacParakeet** -- Named after the Parakeet STT model that powers it. "Mac" prefix signals native macOS. The name is friendly, memorable, and directly communicates the technology inside.

The parakeet bird is known for mimicking speech -- a fitting metaphor for a voice transcription app.

---

## Killer Features (What Sets Us Apart)

| Feature | What It Does | Why It Matters |
|---------|--------------|----------------|
| **Parakeet Speed** | 60 min audio in ~23 seconds | Transcription so fast it feels instant |
| **System-wide Dictation** | Fn to dictate in any app | Voice input everywhere, not just our app |
| **Meeting Recording** | Capture system audio + mic, transcribe locally | Record any call or meeting without cloud services |
| **YouTube Transcription** | Paste a URL, get a transcript | File transcription for the YouTube era |
| **Local-First STT** | Speech stays on-device; optional networked AI | Strong privacy claim without pretending the app never uses the network |
| **Clean Pipeline** | Deterministic text cleanup | Professional output without LLM overhead |
| **Custom Words** | User-defined vocabulary anchors | Technical terms transcribed correctly every time |
| **Free & Open-Source** | Current public build is GPL-3.0, no price, no accounts | Zero friction adoption today; official paid distribution/support remains possible. |

---

*This document defines the "why" and the "what." See [02-features.md](./02-features.md) for detailed feature specs and [03-architecture.md](./03-architecture.md) for technical architecture.*
