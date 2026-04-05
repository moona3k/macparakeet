# MacParakeet: Vision & Philosophy

> Status: **ACTIVE** - Authoritative, current
> The fastest, most private voice app for Mac. No cloud. Free and open-source (GPL-3.0).
> Pricing amendment: All references to "$49 one-time purchase" and pricing tiers below are historical. MacParakeet is now free and open-source (GPL-3.0) as of v0.5.

---

## The North Star

**The fastest, most private voice app for Mac. No cloud. No subscriptions.**

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
|   Voice -> Text. Done. Free & open-source.                            |
|                                                                       |
+-----------------------------------------------------------------------+
```

Two modes. That is the entire product:

1. **Dictate anywhere** -- Press Fn (or your configured hotkey), speak, release. Text appears where your cursor is.
2. **Drop a file** -- Drag audio/video in. Get a transcript out.

Everything else exists to make those two modes faster, smarter, and more useful.

---

## Why MacParakeet Exists

**The problem:** Mac users who want voice-to-text face a bad tradeoff:

| Option | Speed | Privacy | Price | Simplicity |
|--------|-------|---------|-------|------------|
| **Cloud services** (WisprFlow, Otter) | Fast | Your audio on their servers | $12+/mo forever | Simple |
| **Local apps** (MacWhisper, Superwhisper) | Good | Private | $30-$250 | Complex or expensive |
| **Apple Dictation** | Slow | Mostly local | Free | Very limited |
| **MacParakeet** | **Fastest** | **Local-first speech** | **Free (GPL-3.0)** | **Two modes** |

No existing app nails all four: **Speed + Privacy + Simplicity + Fair Pricing**.

Cloud services send your voice to remote servers, create accounts, charge monthly, and add server latency. Local apps either bury you in settings (MacWhisper has 50+ features) or charge a premium (Superwhisper at $250). Apple Dictation is free but slow, inaccurate, and has no custom vocabulary, no file transcription.

**MacParakeet's answer:** Built from the ground up around Parakeet TDT -- the fastest, most accurate open-source STT model available. Local-first speech. Two modes. Free. Done.

---

## Core Philosophy

### 1. Speed Is the Feature

Parakeet TDT 0.6B-v3 transcribes 60 minutes of audio in ~23 seconds (155x realtime on the Neural Engine via FluidAudio CoreML). Dictation latency is under 500ms. This is not incremental improvement -- it is a category shift.

Speed changes behavior. When transcription takes 30 seconds, you think about whether it is worth doing. When it takes 0.5 seconds, you just talk. MacParakeet makes voice the faster input method for everything: emails, messages, code comments, documents, notes.

### 2. Privacy Is the Brand

Local-first speech is not a feature. It is the identity.

- Local-first STT. No cloud speech processing, no accounts, no required backend.
- Audio never leaves your Mac for dictation or transcription.
- No email signup. No login. Optional self-hosted telemetry can be disabled in Settings.
- Works in airplane mode, air-gapped environments, classified settings.

This is not privacy theater ("your data is encrypted in transit"). This is privacy by architecture: there is no server to send data to.

### 3. Simplicity Over Features

MacWhisper has 50+ features. MacParakeet has two modes.

- **Dictate** -- Press Fn, speak, text appears at cursor. Works in any app.
- **Transcribe** -- Drop a file, get text out. Audio, video, YouTube links.

Every feature we add must pass the test: "Does this make dictation or transcription better?" If not, it does not ship.

### 4. Modern, Not Minimalist

Simple does not mean basic. MacParakeet includes modern capabilities that cloud competitors pioneered, but runs them locally:

- **Clean Pipeline** -- Deterministic text processing: filler removal, custom word replacement, snippet expansion, whitespace normalization. Professional output with zero latency.
- **Custom Words** -- Teach it your vocabulary. Technical terms, proper nouns, acronyms. Anchors that improve recognition accuracy.
- **Context Awareness** -- (Future) Reads the surrounding text to produce better transcriptions. Knows "React" in a code editor, "react" in a therapy note.

### 5. Free and Open-Source

No price tags. No subscriptions. No feature gates. MacParakeet is free and open-source (GPL-3.0).

Every feature is available to everyone, forever. The code is public. Contributions are welcome.

---

## What MacParakeet Is

| Attribute | Description |
|-----------|-------------|
| **Product type** | Native macOS app (menu bar + window) |
| **Core function** | Voice dictation and file transcription |
| **Target users** | Developers, professionals, writers who want fast private voice input |
| **Key differentiators** | Parakeet speed + local-first speech + free/open-source |
| **Business model** | Free and open-source (GPL-3.0) |
| **Platform** | macOS 14.2+, Apple Silicon only |

---

## What MacParakeet Is Not

- **Not a meeting app** -- That is Oatmeal. MacParakeet does not do calendar integration, entity extraction, meeting memory, or action items.
- **Not a note-taking app** -- It puts text where your cursor is. Your note app is your note app.
- **Not a cloud service** -- No hosted transcription backend, no accounts, no sync product. Core speech stays local.
- **Not an enterprise product** -- Single-user, single-Mac. No admin console, no team management (initially).
- **Not a mobile app** -- macOS only. Apple Silicon required for Parakeet STT via FluidAudio CoreML on the Neural Engine.
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

### ~~Mode 3: Command Mode (Pro)~~ — REMOVED

> **REMOVED** (2026-02-23) — Command Mode and local LLM support removed. MacParakeet is focused on its two core strengths: fast local dictation and file transcription.

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

**What they want:** A good product at a fair price. One-time purchase. No recurring charges.

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
| **STT Engine** | Parakeet TDT | Cloud AI | Whisper | Whisper | Apple Neural |
| **Speed (60 min)** | ~23 sec | ~30 sec* | ~2-4 min | ~2-4 min | Real-time only |
| **WER** | ~2.5% | ~5%** | 7-12% | 7-12% | ~10-15% |
| **Privacy** | Local-first speech | Cloud | Local | Local | Mostly local |
| **Dictation** | Yes | Yes | No | Yes | Yes |
| **File transcription** | Yes | No | Yes | Limited | No |
| **Smart cleanup** | Deterministic | Cloud AI | No | Cloud AI | No |
| **Custom words** | Yes | Yes | Limited | No | No |
| **Price** | Free (GPL-3.0) | $144-180/yr | $30 once | $250 once | Free |
| **Account required** | No | Yes | No | Yes | Apple ID |

*WisprFlow speed includes network latency.
**WisprFlow accuracy estimated; uses proprietary cloud models.

### Why We Win Each Segment

- **vs WisprFlow**: Same speed class, but local-first speech + free vs $144-180/year. WisprFlow users who care about privacy or cost switch to us.
- **vs MacWhisper**: Faster (Parakeet vs Whisper), simpler (2 modes vs 50+ features), plus system-wide dictation — and free.
- **vs Superwhisper**: Free vs $250, Parakeet-first architecture. No contest on price.
- **vs Apple Dictation**: Faster, more accurate, custom words, file transcription. Same price (free), dramatically more capable.

---

## Competitive Advantages

### 1. Parakeet-First Architecture

We are not a Whisper app that added Parakeet. We built the entire product around Parakeet TDT 0.6B-v3 from day one.

- **155x realtime** on the Neural Engine vs Whisper's 15-30x. Not an incremental improvement -- an order of magnitude.
- **~2.5% WER** -- lower error rate than Whisper large-v3 at a fraction of the compute.
- **Word-level timestamps** -- enables synced subtitles, precise seeking, confidence scoring.
- **Technical vocabulary** -- better handling of code terms, acronyms, and proper nouns than Whisper.

Competitors bolted Parakeet onto existing Whisper architectures. We optimized the entire pipeline for it.

### 2. Local-First, Zero-Compromise Speech

This is not "cloud by default with a local mode." Core speech recognition runs entirely on-device. There is no cloud STT path, no account system, and no requirement to send audio anywhere.

Optional network features exist, but they are explicit and separate: transcript text can be sent to user-configured LLM providers, Sparkle checks for updates, YouTube imports download media, and self-hosted telemetry can be disabled. The privacy boundary is simple: speech stays local.

### 3. Free and Open-Source

In a market of subscriptions ($144-180/yr for WisprFlow) and premium pricing ($250 for Superwhisper), free and open-source is the ultimate value proposition. No pricing objection. No trial friction. No conversion funnel. Just the best tool, available to everyone.

### 4. Focused Simplicity

Two modes. Not twenty. Not fifty.

The product surface area is intentionally small. This means fewer bugs, faster iteration, easier onboarding, and a UI that does not require a tutorial. If a user cannot figure out MacParakeet in 30 seconds, we have failed.

---

## Licensing

MacParakeet is free and open-source under the **GPL-3.0** license. All features are available to all users, forever. The source code is public at [github.com/moona3k/macparakeet](https://github.com/moona3k/macparakeet).

> Historical note: MacParakeet was originally planned as a $49 one-time purchase (see ADR-003). The decision to go free/open-source was made in v0.5 to maximize adoption and community contribution.

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
|  - Custom words       |  - Cross-meeting memory                       |
|  - YouTube import     |  - Action items                               |
|  - Export formats     |  - Knowledge graph                            |
|                       |  - Pre-meeting briefs                         |
|  Simple, focused      |  Complex, powerful                            |
|  Free (GPL-3.0)       |  TBD                                          |
+-----------------------+-----------------------------------------------+
```

### Key Distinctions

| Dimension | MacParakeet | Oatmeal |
|-----------|-------------|---------|
| **Purpose** | Voice input and transcription | Meeting memory and knowledge |
| **Scope** | Text in, text out | Meetings, entities, relationships, patterns |
| **Complexity** | Two modes | Full knowledge system |
| **User relationship** | Tool (use and forget) | System (compounds over time) |
| **Codebase** | Independent | Independent |
| **Revenue** | Free (GPL-3.0) | TBD |

### Strategic Relationship

- **Standalone value**: MacParakeet is a complete product on its own. It does not require or reference Oatmeal.
- **Funnel potential**: MacParakeet users who want meeting-specific features (calendar sync, entity extraction, memory) are natural Oatmeal prospects.
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

All within 60 seconds of first launch. No tutorial, no onboarding wizard, no account creation.

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

- YouTube URL transcription (yt-dlp + Parakeet)
- Export formats (.txt, .srt, .vtt, .docx, .pdf, .json)

### v0.4: Polish + Launch

Ship-quality polish. Direct distribution via notarized DMG.

- Onboarding flow (permissions, first dictation)
- Notarized DMG distribution (macparakeet.com + LemonSqueezy)
- Sparkle auto-updates
- Marketing site (macparakeet.com)
- Accessibility (VoiceOver, keyboard navigation)
- UI Localization (English UI first, structure for future languages; STT already supports 25 European languages)

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Platform** | macOS 14.2+, Apple Silicon only | FluidAudio CoreML requires Apple Silicon. |
| **STT engine** | Parakeet TDT 0.6B-v3 | Fastest and most accurate open-source STT. 155x realtime on ANE, ~2.5% WER via FluidAudio CoreML. |
| **YouTube downloads** | Standalone yt-dlp | macOS binary, auto-updates via `--update`. No Python needed. |
| **UI framework** | SwiftUI | Native Mac experience. Menu bar + window. |
| **Database** | SQLite (GRDB) | Single file. No server. Dictation history, custom words, settings. |
| **Cloud option** | No cloud STT; optional LLM providers | Core speech stays local. Network use is explicit and opt-in for AI, updates, telemetry, and media download. |
| **Pricing** | Free (GPL-3.0) | Zero friction. Maximum adoption. Community-driven development. |

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
| **YouTube Transcription** | Paste a URL, get a transcript | File transcription for the YouTube era |
| **Local-First STT** | Speech stays on-device; optional networked AI | Strong privacy claim without pretending the app never uses the network |
| **Clean Pipeline** | Deterministic text cleanup | Professional output without LLM overhead |
| **Custom Words** | User-defined vocabulary anchors | Technical terms transcribed correctly every time |
| **Free & Open-Source** | GPL-3.0, no price, no accounts | Zero friction adoption. Community-driven development. |

---

*This document defines the "why" and the "what." See [02-features.md](./02-features.md) for detailed feature specs and [03-architecture.md](./03-architecture.md) for technical architecture.*
