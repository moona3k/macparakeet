# MacParakeet Marketing Script

> Status: **ACTIVE PRODUCTION BRIEF** — source of truth for the demo/video
> script. Current product, privacy, engine, and release claims remain governed
> by `README.md` and `spec/README.md`; revalidate them before publishing. The
> TypeScript mirror at `marketing/video/src/content/script.ts` must stay aligned
> with any script changes in this document.

## Locked Hook

> **Dictate. Transcribe. Record meetings. One Mac app.**

This hook leads with the **three-modes scope**. Privacy and local-first remain
supporting claims in this specific demo structure; the product itself treats
them as core commitments.

## Locked Supporting Line

> **Free. Open source. Built for Apple Silicon.**

Three short, verifiable claims: the current public build is free and open
source, and the supported runtime is Apple Silicon.

## Voice & Tone

- **Tone:** Calm, confident, minimal. Quiet competence — does the work, doesn't brag.
- **Language:** Simple, direct, no jargon, no superlatives. No "AI-powered." No "blazingly fast." No "game-changing."
- **Pacing:** Slow enough to read; tight enough to respect the viewer's time.
- **Posture:** Show, don't claim. The product is the argument.

## Visual System

| Element | Choice | Notes |
|---|---|---|
| Hero background | `paper` (#F8F4EC) | Warm cream; distinctive against ALTIC/Marco's dark grounds |
| Primary text | `ink` (#0E0F12) on paper | Near-black, never pure black |
| Accent | `coral` (#E86B3B) | One element per composition: the mark, a recording dot, or supporting line |
| Brand mark | `brand-assets/marks/parakeet-line.svg` | Single-stroke calligraphic parakeet; recolorable via `currentColor` |
| Display type | SF Pro Display preferred; Inter for rendered video | Tight tracking on display sizes; never below 32pt for video text |
| Motion | Spring physics, never linear | Stagger word reveals 100-150ms; hold beats ≥ 800ms before transitions |

**Forbidden:** drop shadows, gradients, glassmorphism, glows, rotated/skewed mark.

## 60-Second Master Demo Script

Render target: 1920×1080 @ 60fps. Voice via Kokoro-82M by default (or Higgs Audio V2 for premium renders) — both 100% local.

### 0:00 – 0:03 · Cold open (no narration)
**Visual:** Tight shot of hands on MacBook keyboard. Fn key tap (visible). Cursor blinking in a Slack thread. Mid-sentence dictation appearing live, character by character.
**Spoken in the recording:** *"Hey team, can you review the new pull request by end of day?"*
**Sound:** quiet keyboard tap, soft synth swell rising.

### 0:03 – 0:06 · Hook
**Visual:** Cut to paper-cream background. Coral parakeet mark fades in, settles with a gentle scale spring. Title text reveals in two beats:
> Dictate. Transcribe. Record meetings.
> *One Mac app.*

**VO:** "Three things people use voice for on a Mac. Most apps do one."

### 0:06 – 0:22 · Mode 1: Dictation
**Visual:** Three quick app cuts (each ~5s) showing dictation working live in:
1. Slack thread — `"Hey team, can you review the new pull request by end of day?"`
2. Cursor — `"TODO refactor this function to use async await instead of completions"`
3. Browser address bar — `"best ramen in the mission district"`

**Lower-third:** Apple Silicon · local dictation · offline after setup

**VO:** "MacParakeet dictates anywhere on your Mac. Tap a hotkey, speak, the text appears. Speech recognition stays local and works offline after model setup."

### 0:22 – 0:38 · Mode 2: Transcription
**Visual sequence:**
1. Drag an MP4 file onto the Transcribe tab. Progress card briefly visible. Transcript appears with diarized speakers and timestamps.
2. Paste a real YouTube URL. Show the actual duration and measured elapsed time from the captured run; do not pre-script a speed result.
3. Click Export. Menu opens: TXT · MD · SRT · VTT · DAPT · PDF · DOCX · JSON.

**Lower-third:** Audio · Video · YouTube · Export anywhere

**VO:** "Drop in supported audio or video, or paste a media link. When the selected engine provides timing, you get timestamps and speakers. Export it in the format you need."

### 0:38 – 0:54 · Mode 3: Meeting Recording
**Visual sequence:**
1. Sacred-geometry pill appears in corner. Red dot pulses. Timer counts up.
2. Cut to live meeting panel: Notes tab open. User typing notes — *"Q3 priorities..."* — text appearing live. Transcript ticking in below.
3. Switch to Ask tab. Quick prompts visible.
4. Cut to Library: meeting card with full transcript + AI summary.

**Lower-third:** System audio + mic · Live notes · Local transcription

**VO:** "And during a meeting, MacParakeet records both sides — system audio plus your mic — gives you a live notepad, and when you're done, hands you the transcript and the summary."

### 0:54 – 1:00 · Close
**Visual:** Cut back to paper-cream. Parakeet mark + wordmark settle center. Closing card:
> Free. Open source. Built for Apple Silicon.
> macparakeet.com

**VO:** "Free. Open source. Built for Apple Silicon. MacParakeet."

**Total spoken word count:** ~95 words / 60 seconds → ~95 WPM. Paced for clarity, not for "energetic ad voice."

## 30-Second Hero Loop (silent, autoplay-muted)

Same five beats as the master demo, compressed to 6s each, no voiceover. On-screen captions carry the message. Music + ambient sound only. Targets: macparakeet.com hero, GitHub social card animation, X autoplay embeds.

| Beat | Duration | Caption |
|---|---|---|
| Cold open dictation | 4s | (no caption) |
| Hook | 5s | Dictate. Transcribe. Record meetings. / One Mac app. |
| Dictation cuts | 6s | Dictate anywhere |
| Transcription cuts | 6s | Drop in audio, video, or YouTube |
| Meeting recording | 6s | Record meetings · Local transcription |
| Close | 3s | macparakeet.com |

## GIF Storyboards (README + social)

Each renders at 1280×720, ≤10s, ≤4 MB (GitHub README cap). Captured from the same screencast clips used in the master demo.

### GIF 1 · Dictation (8s)
Pure flow: keyboard hand → Fn tap → text streaming into Slack mid-thread. No captions. Loops cleanly.

### GIF 2 · YouTube transcription (10s)
Paste URL → progress card with elapsed timer → transcript materializing with diarization labels. Use the actual duration and elapsed time from the captured run rather than a hard-coded benchmark caption.

### GIF 3 · Meeting recording (10s)
Pill recording state → split to live notepad + transcript ticking → finished meeting card. Caption: `System audio + mic · Local`.

### GIF 4 · Export menu (5s)
Hover Export → menu opens → cursor brushes across TXT, MD, SRT, VTT, DAPT, PDF, DOCX, JSON. No caption.

## README Hero Block

```markdown
<p align="center">
  <img src="brand-assets/marks/parakeet-line.svg" width="120" alt="MacParakeet"/>
</p>

<h1 align="center">MacParakeet</h1>

<p align="center">
  <strong>Fast, private, local-first voice for Apple Silicon Macs.</strong><br/>
  <em>Dictate. Transcribe. Record meetings. Free and open source.</em>
</p>

<p align="center">
  <a href="https://macparakeet.com">Website</a> ·
  <a href="https://github.com/moona3k/macparakeet/releases/latest">Download</a>
</p>

<p align="center">
  <img src="marketing/exports/dictation.gif" alt="Dictation demo" width="720"/>
</p>
```

## Comparison Page Copy

### Headline
**Three voice apps in one. Free.**

### Sub
MacParakeet brings system-wide dictation, file/media transcription, and meeting recording together on Apple Silicon. Speech recognition stays local; the current public build is free and open source.

### Comparison table

No static competitor table is canonical. Competitor features, licenses, and
prices change too quickly for an active product document. Build and date-stamp
a source-backed comparison at publication time if a campaign needs one.

### Body paragraph
MacParakeet captures meetings with system audio, microphone audio, or both, transcribes locally, and keeps the result alongside a live notepad — while also handling system-wide dictation and file/media transcription. The three modes share one scheduler/runtime control plane so meeting recording and dictation can be coordinated safely. Parakeet v3 is the default for English and supported European languages; English-only Parakeet builds cover timestamped exports and readable live preview; Whisper handles broader-language files and retranscription; Nemotron is Beta live preview; and Cohere is local batch plain text.

## CTA Conventions

- **Primary URL:** `macparakeet.com`
- **GitHub:** `github.com/moona3k/macparakeet`
- **Homebrew (official cask, live since 2026-06-06):** `brew install --cask macparakeet`
- **Never use:** "Get started today," "Try it free," "Sign up." There is no signup. The app downloads and runs.

## Production Stack

The marketing-production pipeline favors local, free, and open tooling where
practical. Product privacy claims are governed separately by the README/specs.

| Layer | Tool | Cost |
|---|---|---|
| Native app capture | Screen Studio | Commercial; verify current pricing before purchase |
| Composition + render | Remotion (`marketing/video/`) | Free for solo |
| Voice (default) | **Kokoro-82M** via `kokoro-js` — MIT licensed, pure Node, ~80 MB | Free, local |
| Voice (premium upgrade) | **Higgs Audio V2** via Python — optional multi-speaker render path | Free, local |
| Voice (future) | **F5-TTS** voice clone of the actual founder's voice from a 5-15s reference | Free, local |
| Music | Pixabay / Mixkit royalty-free | Free |
| Caption font (render) | Inter (Google Fonts) | Free |
| GIF conversion | `ffmpeg` from rendered MP4 | Free |

## Quality Bar (non-negotiable)

- **Resolution:** 1920×1080 minimum for landscape; 4K (3840×2160) for hero loop
- **Frame rate:** 60fps
- **Audio:** 48kHz, 16-bit minimum, mastered to -16 LUFS for web
- **Voice (default):** Kokoro-82M at `q8` precision, `af_bella` or audition equivalent. Calm, measured, slight warmth.
- **Voice (premium):** Higgs Audio V2 with the brand-voice system prompt when SOTA quality matters (hero renders, multi-speaker scenes). Never the default robotic preset of any model.
- **Music:** ducked under VO; never overpowers. -18 dB under voice.
- **Type:** anti-aliased, kerned, never below 32pt
- **Motion:** springs (`damping ~15`, `stiffness ~100`), never linear interpolations
- **Color accuracy:** sRGB, brand palette verified against `brand-assets/palette/palette.json`

## Iteration Discipline

Every change to copy lives here first. Then `marketing/video/src/content/script.ts` is updated to match. Then voices are regenerated (`npm run voice`, or `npm run voice:hq` for the Higgs upgrade). Then videos are re-rendered. This is a one-way flow: **docs → code → audio → video**. Never edit a `.mp4` directly.

The local TTS choice is deliberate: regeneration is free and offline, so iteration cost is zero. Tweaking a single word in a VO line does not cost an API call or a recording session — it costs about a second of CPU time.

---

*Locked 2026-05-10. Revisions go through PR review like any other product copy.*
