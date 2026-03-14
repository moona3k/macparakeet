# MacParakeet: Vision & Philosophy

> Status: **ACTIVE** - Authoritative, current
> The fastest, most private voice app for Mac. No cloud. No subscriptions.

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
|   Voice -> Text. Done. $49 once.                                      |
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
| **MacParakeet** | **Fastest** | **100% local** | **$49 once** | **Two modes** |

No existing app nails all four: **Speed + Privacy + Simplicity + Fair Pricing**.

Cloud services send your voice to remote servers, create accounts, charge monthly, and add server latency. Local apps either bury you in settings (MacWhisper has 50+ features) or charge a premium (Superwhisper at $250). Apple Dictation is free but slow, inaccurate, and has no custom vocabulary, no file transcription.

**MacParakeet's answer:** Built from the ground up around Parakeet TDT -- the fastest, most accurate open-source STT model available. 100% local. Two modes. $49. Done.

---

## Core Philosophy

### 1. Speed Is the Feature

Parakeet TDT 0.6B-v3 transcribes 60 minutes of audio in ~23 seconds (155x realtime on the Neural Engine via FluidAudio CoreML). Dictation latency is under 500ms. This is not incremental improvement -- it is a category shift.

Speed changes behavior. When transcription takes 30 seconds, you think about whether it is worth doing. When it takes 0.5 seconds, you just talk. MacParakeet makes voice the faster input method for everything: emails, messages, code comments, documents, notes.

### 2. Privacy Is the Brand

100% local is not a feature. It is the identity.

- Zero cloud. Zero accounts. Zero tracking.
- Audio never leaves your Mac. Not to our servers, not to anyone's.
- No email signup. No login. No analytics. Download and use.
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

### 5. Fair Pricing, No Tricks

One-time purchase. No subscription. No feature gates that make the free tier unusable.

- **Free**: 7-day trial (full features).
- **Pro ($49)**: Unlimited. Everything. Forever.

WisprFlow charges $144-180/year. After 3-4 months of MacParakeet, you have saved money. After a year, you have saved $95-131. After two years, $239-311. The gap only grows.

---

## What MacParakeet Is

| Attribute | Description |
|-----------|-------------|
| **Product type** | Native macOS app (menu bar + window) |
| **Core function** | Voice dictation and file transcription |
| **Target users** | Developers, professionals, writers who want fast private voice input |
| **Key differentiators** | Parakeet speed + 100% local + $49 one-time |
| **Business model** | Free trial (7 days) + $49 Pro (one-time) |
| **Platform** | macOS 14.2+, Apple Silicon only |

---

## What MacParakeet Is Not

- **Not a meeting app** -- That is Oatmeal. MacParakeet does not do calendar integration, entity extraction, meeting memory, or action items.
- **Not a note-taking app** -- It puts text where your cursor is. Your note app is your note app.
- **Not a cloud service** -- No servers, no accounts, no sync. Local only.
- **Not an enterprise product** -- Single-user, single-Mac. No admin console, no team management (initially).
- **Not a mobile app** -- macOS only. Apple Silicon required for Parakeet/MLX performance.
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
            ($49, local,       |                  ($144-180/yr, cloud,
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
| **Privacy** | 100% local | Cloud | Local | Local | Mostly local |
| **Dictation** | Yes | Yes | No | Yes | Yes |
| **File transcription** | Yes | No | Yes | Limited | No |
| **Smart cleanup** | Deterministic | Cloud AI | No | Cloud AI | No |
| **Custom words** | Yes | Yes | Limited | No | No |
| **Price** | $49 once | $144-180/yr | $30 once | $250 once | Free |
| **Account required** | No | Yes | No | Yes | Apple ID |

*WisprFlow speed includes network latency.
**WisprFlow accuracy estimated; uses proprietary cloud models.

### Why We Win Each Segment

- **vs WisprFlow**: Same speed class, but local + $49 once vs $144-180/year. WisprFlow users who care about privacy or cost switch to us.
- **vs MacWhisper**: Faster (Parakeet vs Whisper), simpler (2 modes vs 50+ features), plus system-wide dictation. The $19 premium over MacWhisper ($30) buys dictation and a Parakeet-first architecture.
- **vs Superwhisper**: Dramatically cheaper ($49 vs $250), Parakeet-first architecture. Price-sensitive Superwhisper users switch to us.
- **vs Apple Dictation**: Faster, more accurate, custom words, file transcription. Free users wanting more capability upgrade to us.

---

## Competitive Advantages

### 1. Parakeet-First Architecture

We are not a Whisper app that added Parakeet. We built the entire product around Parakeet TDT 0.6B-v3 from day one.

- **155x realtime** on the Neural Engine vs Whisper's 15-30x. Not an incremental improvement -- an order of magnitude.
- **~2.5% WER** -- lower error rate than Whisper large-v3 at a fraction of the compute.
- **Word-level timestamps** -- enables synced subtitles, precise seeking, confidence scoring.
- **Technical vocabulary** -- better handling of code terms, acronyms, and proper nouns than Whisper.

Competitors bolted Parakeet onto existing Whisper architectures. We optimized the entire pipeline for it.

### 2. 100% Local, Zero Compromise

This is not "local option available." This is "there is no cloud option." The architecture has no server component. There is no API endpoint to send audio to. There is no account system to create.

This makes our privacy claim unchallengeable. Competitors who offer "local mode" still have cloud infrastructure, still collect accounts, still have terms of service that hedge on data usage. We have none of that.

### 3. $49 One-Time Purchase

In a market of subscriptions ($144-180/yr for WisprFlow) and premium pricing ($250 for Superwhisper), $49 one-time is a clear value proposition.

- Break-even vs WisprFlow: 3-4 months
- Savings vs WisprFlow after 1 year: $95-131
- Savings vs WisprFlow after 2 years: $239-311
- Savings vs Superwhisper: $201 immediately

### 4. Focused Simplicity

Two modes. Not twenty. Not fifty.

The product surface area is intentionally small. This means fewer bugs, faster iteration, easier onboarding, and a UI that does not require a tutorial. If a user cannot figure out MacParakeet in 30 seconds, we have failed.

---

## Pricing Strategy

### Tiers

| Tier | Price | What You Get |
|------|-------|--------------|
| **Free** | $0 | 7-day trial (full features) |
| **Pro** | $49 (one-time) | Unlimited dictation, unlimited transcription, all export formats (SRT/VTT/MD), custom words, text snippets, dictation history |

### Why This Works

**Trial reduces friction.** A 7-day full-feature trial lets users build the habit and evaluate accuracy and speed before buying.

**Pro is a clear upgrade.** Unlimited usage removes the daily cap. Export formats add real capability. Custom words and snippets add personalization. The upgrade path is obvious and compelling.

**No subscription.** This is a feature, not a limitation. In a market where every competitor charges monthly or annually, one-time pricing is a differentiator that drives word-of-mouth. "I paid $49 once and never think about it again" is a story people tell their friends.

### Revenue Model

With 10,000 downloads and a 10% conversion rate:
- 1,000 Pro purchases at $49 = $49,000 Year 1 revenue
- Ongoing organic growth from SEO, word-of-mouth, and direct distribution
- Future: major version upgrades (MacParakeet 2.0) as separate paid upgrade if warranted

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
|  $49 one-time         |  TBD                                          |
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
| **Revenue** | $49 one-time | TBD |

### Strategic Relationship

- **Standalone value**: MacParakeet is a complete product on its own. It does not require or reference Oatmeal.
- **Funnel potential**: MacParakeet users who want meeting-specific features (calendar sync, entity extraction, memory) are natural Oatmeal prospects.
- **Revenue timing**: MacParakeet can generate revenue while Oatmeal matures. Simpler product = faster to market.
- **Technology proving ground**: Parakeet integration and clean pipeline are battle-tested in MacParakeet before being used in Oatmeal.

---

## Success Metrics

### Year 1 Targets

| Metric | Target | How We Measure |
|--------|--------|----------------|
| Downloads | 10,000 | Website analytics + LemonSqueezy |
| Paid conversions | 1,000 (10% rate) | LemonSqueezy |
| Revenue | $49,000 | LemonSqueezy |
| User satisfaction | 4.5+ stars equivalent | Community feedback + NPS |
| Daily active users | 2,000 | Local analytics (opt-in, anonymized) |
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
| **Cloud option** | None | Privacy is the brand. No cloud means no cloud. |
| **Pricing** | $49 one-time | Clear value vs subscriptions. Premium over MacWhisper ($30) justified by system-wide dictation + smart cleanup. |
| **Subscription** | No | Differentiator. One-time purchase builds trust and word-of-mouth. |

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
| **100% Local** | Zero network, zero accounts | Unchallengeable privacy claim |
| **Clean Pipeline** | Deterministic text cleanup | Professional output without LLM overhead |
| **Custom Words** | User-defined vocabulary anchors | Technical terms transcribed correctly every time |
| **$49 Forever** | One-time purchase, no subscription | Pay once, use forever. Saves $95+/yr vs competitors |

---

*This document defines the "why" and the "what." See [02-features.md](./02-features.md) for detailed feature specs and [03-architecture.md](./03-architecture.md) for technical architecture.*
