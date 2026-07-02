# MacParakeet Marketing Script

> Status: **ACTIVE** — single source of truth for all video, GIF, and copy
> assets. The TypeScript mirror at `marketing/video/src/content/script.ts`
> must stay aligned with this document.

## Locked Hook

> **Dictate. Transcribe. Record meetings. One Mac app.**

This hook leads with the **three-modes scope** — the category claim no
single-mode competitor (WisprFlow, MacWhisper, VoiceInk, Superwhisper,
Voibe, TypeWhisper, FluidVoice) can copy without rebuilding their product.
Privacy and local-first are *supporting* claims, not lead claims, because
that framing is saturated.

## Locked Supporting Line

> **Free. Open source. Built for Apple Silicon.**

Three claims, three short statements, all true. Hits the price wedge against
$5-15/mo competitors AND the closed-source wedge AND the "made for the chip
you have" wedge in one breath.

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

**Lower-third:** Apple Silicon · fast local dictation · runs offline

**VO:** "MacParakeet dictates anywhere on your Mac. Tap a hotkey, speak, the text appears. Apple Silicon. Local transcription. Runs offline."

### 0:22 – 0:38 · Mode 2: Transcription
**Visual sequence:**
1. Drag an MP4 file onto the Transcribe tab. Progress card briefly visible. Transcript appears with diarized speakers and timestamps.
2. Paste a real YouTube URL (Karpathy *"Let's build GPT"*, 1h56m). Card: "Transcribing 1h 56m video..." → done in <60s elapsed.
3. Click Export. Menu opens: TXT · MD · SRT · VTT · PDF · DOCX · JSON.

**Lower-third:** Audio · Video · YouTube · Export anywhere

**VO:** "Drop in any audio, any video, even a YouTube link. Get a transcript with timestamps and speakers. Export it any way you need."

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
Paste URL → progress card with elapsed timer → transcript materializing with diarization labels. Single caption: `1h 56m video · 47s to transcribe`.

### GIF 3 · Meeting recording (10s)
Pill recording state → split to live notepad + transcript ticking → finished meeting card. Caption: `System audio + mic · Local`.

### GIF 4 · Export menu (5s)
Hover Export → menu opens → cursor brushes across TXT, MD, SRT, VTT, PDF, DOCX, JSON. No caption.

## README Hero Block

```markdown
<p align="center">
  <img src="brand-assets/marks/parakeet-line.svg" width="120" alt="MacParakeet"/>
</p>

<h1 align="center">MacParakeet</h1>

<p align="center">
  <strong>Dictate. Transcribe. Record meetings. One Mac app.</strong><br/>
  <em>Free. Open source. Built for Apple Silicon.</em>
</p>

<p align="center">
  <a href="https://macparakeet.com">Website</a> ·
  <a href="https://macparakeet.com/docs">Docs</a> ·
  <a href="https://github.com/moona3k/macparakeet/releases/latest">Download</a> ·
  <a href="#comparison">Compared to other voice apps</a>
</p>

<p align="center">
  <img src="marketing/exports/dictation.gif" alt="Dictation demo" width="720"/>
</p>
```

## Comparison Page Copy

### Headline
**Three voice apps in one. Free.**

### Sub
Most Mac voice apps do one thing. MacParakeet does all three — dictation, file & YouTube transcription, and meeting recording — locally, on Apple Silicon, for free.

### Comparison table

| | MacParakeet | TypeWhisper | FluidVoice | WisprFlow | MacWhisper | VoiceInk | Superwhisper | Voibe |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| System-wide dictation | ✓ | ✓ | ✓ | ✓ | — | ✓ | ✓ | ✓ |
| File transcription | ✓ | ✓ | — | — | ✓ | ✓ | ✓ | ✓ |
| YouTube URL transcription | ✓ | — | — | — | — | — | — | — |
| **Meeting recording** | **✓** | — | — | — | — | — | — | — |
| Speaker diarization | ✓ | beta | — | — | — | — | — | — |
| Local-first | ✓ | ✓ | ✓ | partial | ✓ | ✓ | ✓ | ✓ |
| Apple Silicon optimized | ✓ | ✓ | ✓ | partial | partial | ✓ | partial | partial |
| Open source | GPL-3.0 | GPL / commercial | GPL-3.0 | — | — | GPL-3.0 | — | — |
| Price | **Free** | Free / €5/mo commercial | Free | $12-15/mo | $30 once | $39.99 once | $5.41/mo or $250 once | $4.90/mo or $99 once |

*Last verified: 2026-05.*

### Body paragraph
MacParakeet is the only Mac voice app that captures meetings with system audio, microphone audio, or both, transcribes locally with diarization, and ships the result alongside a live notepad — while also handling system-wide dictation and YouTube/file transcription. The three modes share one STT scheduler and one inference runtime, so meeting recording and dictation can run concurrently without resource contention. Built around local Apple Silicon speech recognition: Parakeet v3 is the default for English and supported European languages, English-only Parakeet builds cover timestamped exports or readable live preview, Whisper handles broader-language files and retranscription, Nemotron is Beta live preview, and Cohere is local batch plain text.

## CTA Conventions

- **Primary URL:** `macparakeet.com`
- **GitHub:** `github.com/moona3k/macparakeet`
- **Homebrew (official cask, live since 2026-06-06):** `brew install --cask macparakeet`
- **Never use:** "Get started today," "Try it free," "Sign up." There is no signup. The app downloads and runs.

## Production Stack

100% local, 100% free, 100% open. The marketing pipeline embodies the same
"local-first, no subscriptions" thesis as the product itself.

| Layer | Tool | Cost |
|---|---|---|
| Native app capture | Screen Studio | $90 one-time |
| Composition + render | Remotion (`marketing/video/`) | Free for solo |
| Voice (default) | **Kokoro-82M** via `kokoro-js` — top open-weight TTS on Artificial Analysis (ELO 1059), MIT licensed, pure Node, ~80MB | Free, local |
| Voice (premium upgrade) | **Higgs Audio V2** via Python — #1 trending on HuggingFace, Llama 3.2 3B foundation, naturalness 9.5/10, multi-speaker | Free, local |
| Voice (future) | **F5-TTS** voice clone of the actual founder's voice from a 5-15s reference | Free, local |
| Music | Pixabay / Mixkit royalty-free | Free |
| Caption font (render) | Inter (Google Fonts) | Free |
| GIF conversion | `ffmpeg` from rendered MP4 | Free |

## Quality Bar (non-negotiable)

- **Resolution:** 1920×1080 minimum for landscape; 4K (3840×2160) for hero loop
- **Frame rate:** 60fps
- **Audio:** 48kHz, 16-bit minimum, mastered to -16 LUFS for web
- **Voice (default):** Kokoro-82M at `q8` precision, `af_bella` or audition equivalent. Calm, measured, slight warmth. Top open-weight TTS by Artificial Analysis ranking.
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
