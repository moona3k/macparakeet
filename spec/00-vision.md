# MacParakeet: Vision & Philosophy

> Status: **ACTIVE** - Authoritative, current
> Fast, private, local-first voice app for Mac. Fully local speech, optional networked features, free and open-source (GPL-3.0).
> Pricing amendment: The current public build is free, GPL-3.0, and fully unlocked. Older "$49 one-time purchase" and trial-tier language is historical, but GPL-compatible official paid distribution, support, hosted services, or future paid builds remain valid options. The retained purchase activation plumbing must not be removed as dead code without explicit owner direction and an ADR/spec update.

---

## The North Star

**Fast, private, local-first voice for Mac. Fully local speech when you want it. No required cloud subscription for core speech.**

That is the day-one promise. The destination it builds toward
([ADR-027](adr/027-product-north-star.md)): **every word you speak or hear on
your Mac becomes private, permanent, and useful — on your machine, owned by
you, readable by you and your agents.** MacParakeet is the private speech
memory of your Mac.

```
+-----------------------------------------------------------------------+
|                                                                       |
|   CLOUD SPEECH SERVICE                                                |
|   --------------------                                                |
|   Voice -> Provider -> Text -> account and service dependency         |
|                                                                       |
|   LOCAL SINGLE-MODE TOOL                                              |
|   ----------------------                                              |
|   Voice/file -> Local model -> Text -> narrow workflow                |
|                                                                       |
|   MacPARAKEET                                                         |
|   -----------                                                         |
|   Voice -> Text. Done. Local-first and GPL open-source.               |
|                                                                       |
+-----------------------------------------------------------------------+
```

Three capture modes plus one optional selected-text AI utility. That is the product:

1. **Dictate anywhere** -- Double-tap Fn for hands-free dictation, or hold Fn for push-to-talk. Text appears where your cursor is.
2. **Drop a file** -- Drag audio/video in. Get a transcript out.
3. **Record a meeting** -- Capture system audio, mic audio, or both, and get a transcript when you stop.
4. **Transform selected text** -- Press a bound Transform hotkey to rewrite selected text through your configured LLM provider.

Everything else exists to make those capture modes and the selected-text rewrite surface faster, smarter, and more useful.

### Where This Is Going

The modes converge ([ADR-027](adr/027-product-north-star.md)): dictation
captures what you say, meetings capture what you discuss, files capture what
you consume — and all of it lands in one local, searchable library that
compounds in value the longer you use the app.

- **The Library becomes the center of gravity** — unified search across all
  three modes, question-answering over your own corpus, and export. Scope
  guard: search + QA + export, not a PKM.
- **Agents are first-class consumers** — anything you can do with your
  corpus, your local agents can do through `macparakeet-cli` and its
  versioned contract.
- **Session-based, by design** — every capture is explicitly started by you.
  Ambient/always-on capture is deliberately parked
  ([ADR-027](adr/027-product-north-star.md) §4); cloud STT remains
  permanently out ([ADR-002](adr/002-local-only.md)).

Every feature must capture speech better, make the corpus more useful, or
hand it safely to you and your agents — otherwise it does not ship.

---

## Why MacParakeet Exists

**The problem:** Mac users who want voice-to-text face a bad tradeoff:

| Option | Speech boundary | Product breadth | Ownership |
|--------|-----------------|-----------------|-----------|
| **Cloud speech services** | Audio leaves the Mac | Often focused on dictation or meetings | Provider account and service dependency |
| **Local transcription tools** | Speech can stay local | Often focused on files or one capture mode | Local files, product-specific automation |
| **Built-in OS dictation** | OS-managed | Dictation only | No shared transcript library or file/meeting workflow |
| **MacParakeet** | **No cloud STT; can be fully local** | **Three capture modes + Transforms** | **Local library, exports, and versioned CLI** |

MacParakeet is deliberately optimized for **speed + privacy + simplicity + user ownership**. Competitor capabilities and prices change; this spec defines MacParakeet's product commitments rather than serving as a live market-comparison table.

**MacParakeet's answer:** Built from the ground up around Parakeet TDT for speed, with multilingual v3 as the default, English-only v2 as an opt-in TDT build, and Parakeet Unified as an opt-in English build with punctuation, capitalization, live preview, and word-timestamped output, plus optional local Nemotron Beta, Cohere Transcribe, and WhisperKit engines for broader language coverage and accuracy-focused batch work. Fully local speech by default, with optional networked features. Three capture modes, plus Transforms for selected text. Simple and GPL open-source. Done.

---

## Core Philosophy

### 1. Speed Is the Feature

On the repository's Apple M4 Pro reference benchmark, the three Parakeet builds sustain roughly 81–93x realtime with 115–131 MB peak RSS, depending on the build. English-only v2 provides a no-auto-detect TDT path, while Parakeet Unified provides English punctuation/capitalization, live preview, and word timestamps. These measurements are hardware- and corpus-specific; [`benchmarks/asr/`](../benchmarks/asr/) and the README carry the current tables.

Speed changes behavior. When a short dictation returns quickly and predictably, voice becomes a practical input method for emails, messages, code comments, documents, and notes.

### 2. Privacy Is the Brand

Fully local speech is a core product property, and the app can stay fully local when configured that way.

- Local STT. No cloud speech processing, no accounts, no required backend for core speech.
- Audio never leaves your Mac for dictation or transcription.
- No email signup. No login. Optional self-hosted telemetry can be disabled in Settings.
- Core capture and local-file speech workflows work in airplane-mode or air-gapped environments after the required models are installed. Media imports, updates, telemetry, and remote AI providers are separate network surfaces.

This is privacy by architecture: speech recognition has no server path. Optional transcript-AI, media-download, update, and telemetry surfaces remain explicit and separately documented.

### 3. Simplicity Over Features

MacParakeet keeps the top-level product centered on three capture modes plus Transforms.

- **Dictate** -- Double-tap Fn or hold Fn, speak, and text appears at cursor. Works in any app.
- **Transcribe** -- Drop a file, get text out. Audio, video, YouTube links.
- **Record** -- Capture a meeting (system audio, mic audio, or both), get a transcript.
- **Transform** -- Select text anywhere, press a bound hotkey, rewrite it through your configured LLM provider.

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
| **Key differentiators** | Parakeet speed + optional local Nemotron/Cohere/Whisper engines + free/open-source |
| **Business model** | Current public build is free/GPL/unlocked; official paid distribution, support, or hosted services remain possible |
| **Platform** | macOS 14.2+, Apple Silicon only |

---

## What MacParakeet Is Not

- **Not a full meeting intelligence app** -- MacParakeet records and transcribes meetings, has live notes, Ask, and prompt-based action summaries. Calendar auto-start is implemented and enabled (opt-in). Cross-mode search and QA over your own library are in scope ([ADR-027](adr/027-product-north-star.md)); entity extraction, CRM-style enrichment, and team intelligence are not.
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
|  1. Hold Fn for push-to-talk or double-tap Fn for hands-free          |
|  2. Speak naturally                                                   |
|  3. Release Fn, or tap Fn again                                       |
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
|  Capture system audio, mic audio, or both. Transcribe locally.        |
|                                                                       |
|  1. Click "Record Meeting" (or press meeting hotkey)                  |
|  2. Grant the permissions required by the selected source mode         |
|  3. Meeting pill appears — recording the selected audio source(s)      |
|  4. Click Stop when done                                              |
|  5. Local STT transcribes source audio (Parakeet by default)          |
|  6. Result saved to library with full export/prompt support            |
|                                                                       |
|  Runs concurrently with dictation (ADR-015).                          |
|  Dictate a Slack message while your meeting is being recorded.        |
+-----------------------------------------------------------------------+
```

- Source-mode capture: system audio (ScreenCaptureKit), mic (AVAudioEngine), or both
- Floating recording pill with elapsed timer and stop button
- Results stored as `Transcription` with `sourceType = .meeting` — gets export, prompts, summaries, chat for free
- Requires Screen & System Audio Recording permission only for modes that capture system audio (macOS 14.2+)

> **Historical note:** This slot was originally "Command Mode (Pro)" which was removed in 2026-02. Meeting recording replaced it as Mode 3 in v0.6.

### Optional Utility: Transform Selected Text

```
+-----------------------------------------------------------------------+
|  Rewrite selected text anywhere without leaving the current app.       |
|                                                                       |
|  1. Select text in Slack, Mail, Linear, a browser, or an editor         |
|  2. Press a bound Transform hotkey (Control-Option-1/2/3)              |
|  3. MacParakeet captures the selection and runs the saved prompt        |
|  4. The result replaces the selection in place                         |
|                                                                       |
|  Uses the user's configured LLM provider. No selected text is sent      |
|  unless the user explicitly triggers a Transform.                      |
+-----------------------------------------------------------------------+
```

- Built-ins: Polish, Distill, Decide.
- Uses the same BYO-provider LLM architecture as summaries, chat, and the AI formatter.
- Separate from STT: it operates on selected text, not audio.

---

## Target Users

### Primary: Developers and Power Users

People who type quickly but prefer voice for long messages, thinking out loud,
and dictating documentation. They care about low latency, clear privacy
boundaries, automation, and avoiding a required subscription.

**What they want:** Fast dictation that works in VS Code, Terminal, Slack. No cloud, no subscription, no bloat.

### Secondary: Privacy-Conscious Professionals

People who handle sensitive notes, interviews, research, or internal material
and want speech recognition to stay on their Mac. MacParakeet does not itself
certify a user's regulatory compliance; users must evaluate their complete
workflow, device controls, enabled telemetry, and configured AI providers.

**What they want:** Understandable data boundaries, no required product
account, local core speech, and the ability to disable telemetry and avoid
remote AI providers.

### Tertiary: Subscription-Fatigued Users

People who want a capable voice app without another recurring subscription, account, or feature-gated trial.

**What they want:** A good product without recurring charges. Free and open-source.

### Quaternary: Writers and Content Creators

Writers who think better out loud. Podcasters who need episode transcripts. Content creators making captions and subtitles. Students transcribing lectures. Anyone who produces text and prefers speaking to typing.

**What they want:** Fast file transcription with good export formats. Clean output that needs minimal editing. Reliable custom vocabulary for domain-specific terms.

---

## Product Position

MacParakeet does not depend on a time-sensitive competitor matrix for its identity. Published comparisons must be reverified when used; prices, engine choices, and feature sets are not stable facts.

| Product commitment | MacParakeet's position |
|--------------------|------------------------|
| Speech privacy | No cloud STT; supported speech engines run on the Mac |
| Scope | System-wide dictation, file/media transcription, and meeting recording in one app |
| Ownership | Local library, local artifacts, export, and a versioned CLI contract |
| Processing | Deterministic cleanup by default; optional provider-backed AI |
| Distribution | Current public build is free and GPL-3.0 |
| Platform fit | Native Swift app for Apple Silicon Macs |

---

## Competitive Advantages

### 1. Parakeet-First Architecture

We are not a Whisper app that added Parakeet. We built the entire product around Parakeet TDT 0.6B-v3 from day one, later exposed v2 and Unified as English-only Parakeet options, then added WhisperKit, Nemotron, and Cohere explicitly as local opt-in engines for broader coverage, experimentation, and accuracy-focused batch work.

- **Fast default path** -- the current M4 Pro benchmark measures roughly 81–93x steady realtime across Parakeet v3, v2, and Unified.
- **Measured engine tradeoffs** -- the shared benchmark reports accuracy, throughput, memory, and language coverage instead of relying on one headline number.
- **Word-level timestamps** -- enables synced subtitles, precise seeking, and speaker alignment where the selected engine supplies timings.
- **Vocabulary support** -- deterministic replacements ship today; recognition-time custom-vocabulary boosting is separately controlled and tested.

MacParakeet optimizes the default pipeline for Parakeet while routing optional Nemotron, Cohere, and Whisper through the same scheduler/runtime control plane.

### 2. Local-First, Zero-Compromise Speech

This is not "cloud by default with a local mode." Core speech recognition runs entirely on-device. There is no cloud STT path, no account system, and no requirement to send audio anywhere.

Optional network features exist, but they are explicit and separate: transcript text can be sent to user-configured LLM providers, Sparkle checks for updates, YouTube imports download media, and self-hosted telemetry can be disabled. The privacy boundary is simple: speech stays local.

### 3. Free and Open-Source

The current free and open-source build removes account, trial, and subscription friction. Future monetization should sell official convenience, support, hosted services, or team workflows without undermining local-first GPL distribution.

### 4. Focused Simplicity

Three capture modes plus Transforms. Not twenty. Not fifty.

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
| **Complexity** | Three capture modes + Transforms | Full knowledge system |
| **User relationship** | Tool whose local library compounds over time ([ADR-027](adr/027-product-north-star.md)) | System (compounds over time) |
| **Codebase** | Independent | Independent |
| **Revenue** | Current public build free/GPL; official paid distribution/support possible | TBD |

### Strategic Relationship

- **Standalone value**: MacParakeet is a complete product on its own. It does not require or reference Oatmeal.
- **Funnel potential**: MacParakeet records and transcribes meetings. Users who want intelligence on top (calendar sync, entity extraction, cross-meeting memory) are natural Oatmeal prospects.
- **Adoption timing**: MacParakeet builds community and mindshare while Oatmeal matures. Simpler product = faster to market.
- **Technology proving ground**: Parakeet integration and clean pipeline are battle-tested in MacParakeet before being used in Oatmeal.
- **Boundary note (2026-07)**: [ADR-027](adr/027-product-north-star.md) moves cross-mode search and corpus QA into MacParakeet; whether Oatmeal continues as a distinct product is an open question recorded there.

---

## Success Metrics

### Year 1 Targets

| Metric | Target | How We Measure |
|--------|--------|----------------|
| Downloads | 10,000 | Website analytics + telemetry |
| GitHub stars | 1,000 | GitHub |
| User satisfaction | 4.5+ stars equivalent | Community feedback + NPS |
| Daily active users | 2,000 | Telemetry (opt-out, non-identifying) |
| Dictation sessions/user/day | 5+ | Local metrics |

### Quality Metrics

| Metric | Target |
|--------|--------|
| Dictation latency | Measure end-of-capture to paste by engine/build; do not publish one hardware-independent number |
| Parakeet throughput | ≥80x steady realtime on the current M4 Pro reference harness |
| Word error rate | Publish per-engine/corpus results from `benchmarks/asr/`; no universal WER claim |
| App crash rate | < 0.1% of sessions |
| First-use success rate | > 95% (user dictates successfully on first try) |

### The Ultimate Test

A new user should be able to:

1. Download MacParakeet
2. Open it
3. Hold Fn and speak a sentence
4. See clean text appear at their cursor
5. Think "this is better than anything I have tried"

On first use, the user should reach this outcome as soon as the required model
download and permission setup complete. No product account is required.

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

### v0.6: Meeting Recording + Multilingual STT

- System audio + mic capture with fragmented source files and crash recovery
- Live meeting pill + Notes / Transcript / Ask panel
- Source-aware final transcription with prompt results and chat in the library
- Parakeet model selection: v3 multilingual default, v2 English-only TDT opt-in, and Unified English opt-in
- Optional local WhisperKit and Cohere Transcribe engines for languages or accuracy needs outside the default Parakeet coverage
- Settings speech-engine picker, Parakeet model picker, Nemotron controls, Cohere language picker, and Whisper language picker
- CLI `transcribe --engine parakeet|nemotron|whisper|cohere --language --parakeet-model`
- Meeting recordings pin engine/language for live preview, recovery, and finalization
- Calendar auto-start is implemented and enabled (`AppFeatures.calendarEnabled = true`); defaults to opt-in mode `.off`. Calendar-driven auto-stop was removed (ADR-017 amendment); recordings stop manually

### v0.7: Post-v0.6 polish

- Stable v0.7.3 adds System Default microphone-routing repair, split live/final
  speech-engine routes, bounded meeting-capture lifecycle handling, meeting
  auto-save feedback, CLI 3.0, and post-v0.6 reliability polish.
- Meeting echo cancellation ships as a fail-soft derived cleaned-microphone
  artifact; activity-based auto-stop remains opt-in and activity-based meeting
  detection remains gated.
- Direction per [ADR-027](adr/027-product-north-star.md): continue Library
  convergence and safe agent access through the CLI. Developer-gated local MLX
  groundwork is not a normal-user v0.7 feature.

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Platform** | macOS 14.2+, Apple Silicon only | FluidAudio CoreML requires Apple Silicon. |
| **STT engine** | Parakeet TDT 0.6B-v3 by default; Parakeet v2 and Unified English opt-ins; optional Nemotron Beta, WhisperKit, and Cohere Transcribe | Parakeet gives the latency target for supported languages; v2 avoids language auto-detect for English-only users; Unified offers a newer English punctuation/capitalization path with live preview and word timestamps; Nemotron is a fast local Beta path; WhisperKit keeps mature broader multilingual speech local; Cohere is a larger batch-only accuracy path. |
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
| **Parakeet Speed** | ~81–93x steady realtime across current builds on the M4 Pro reference benchmark | Fast local transcription with measured, hardware-specific evidence |
| **System-wide Dictation** | Fn to dictate in any app | Voice input everywhere, not just our app |
| **Meeting Recording** | Capture system audio, mic audio, or both; transcribe locally | Record any call or meeting without cloud services |
| **YouTube Transcription** | Paste a URL, get a transcript | File transcription for the YouTube era |
| **Local-First STT** | Speech stays on-device; optional networked AI | Strong privacy claim without pretending the app never uses the network |
| **Clean Pipeline** | Deterministic text cleanup | Professional output without LLM overhead |
| **Custom Words** | User-defined vocabulary anchors | Technical terms transcribed correctly every time |
| **Free & Open-Source** | Current public build is GPL-3.0, no price, no accounts | Zero friction adoption today; official paid distribution/support remains possible. |

---

*This document defines the "why" and the "what." See [02-features.md](./02-features.md) for detailed feature specs and [03-architecture.md](./03-architecture.md) for technical architecture.*
