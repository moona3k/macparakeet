# MacParakeet Video Pipeline

Programmatic rendering for every MacParakeet marketing asset — demos,
hero loops, social cuts, GIFs. Built with [Remotion](https://www.remotion.dev)
for composition and **100% local TTS** for voice (Kokoro-82M by default,
Higgs Audio V2 as the premium-quality upgrade path). Every asset is
regeneratable from a single source: `src/content/script.ts`. No cloud
APIs, no per-render cost, no telemetry — same posture as the product.

The locked human-readable spec lives at [`docs/marketing.md`](../../docs/marketing.md).

## Why this exists

A traditional video editor (Final Cut, Premiere, Screen Studio's editor)
freezes the script at export time. Re-recording when copy changes is hours
of work. With Remotion, every change to `script.ts` re-renders the video
on the next `npm run render`. Marketing moves at engineering velocity.

## Setup

```sh
cd marketing/video
npm install
cp .env.example .env   # optional — defaults are sane
```

Requires Node 20+.

The Kokoro model (~80MB at q8) downloads on first `npm run voice`. No
account, no API key.

For the Higgs Audio V2 premium upgrade, also run:

```sh
uv sync                # creates .venv, installs Higgs deps from pyproject.toml
# or:  pip install -e .
```

[`uv`](https://github.com/astral-sh/uv) is recommended — dramatically
faster than pip and handles the PyTorch wheel selection for Apple Silicon
correctly. Install it once via `curl -LsSf https://astral.sh/uv/install.sh | sh`.

## Workflow

```sh
# Interactive preview in the browser (Remotion Studio)
npm run preview

# Audition Kokoro voices — generates ~8 short test clips you can listen to
npm run audition

# Generate full voiceover from the locked script (Kokoro, pure Node)
npm run voice
npm run voice -- master-demo            # only one scene

# Premium upgrade — Higgs Audio V2 (Python via uv)
npm run voice:hq

# Render compositions — 1080p
npm run render:hook         # 5s validation spike
npm run render:hero         # 30s autoplay-muted hero loop
npm run render:demo         # 60s master demo

# 4K variants
npm run render:hook-4k
npm run render:hero-4k
npm run render:demo-4k
```

Outputs: `public/audio/*.wav` for voice, `out/*.mp4` for video. Both
gitignored. Screencasts (when captured) go in `public/screencasts/`.

## Voice (TTS)

**Default: Kokoro-82M via `kokoro-js`.** #1 open-weight TTS on the
[Artificial Analysis leaderboard](https://artificialanalysis.ai/text-to-speech/leaderboard)
(ELO 1059). 82M params, MIT license, pure Node, no Python, no cloud.
Studio-quality on calm/measured delivery — which matches MacParakeet's
brand voice ("calm, confident, minimal, slight warmth"). Generates ~30s
of audio in under a second on M-series CPUs.

Audition voices from the catalog at the top of `scripts/generate-voice.ts`.
Switch with `KOKORO_VOICE=af_sarah npm run voice`.

### Premium upgrade — Higgs Audio V2

For hero-cut renders where you want SOTA naturalness, multi-speaker
dialog, or emotional range, the project ships an optional second
pipeline using [Higgs Audio V2](https://github.com/boson-ai/higgs-audio)
— currently the #1 trending TTS on HuggingFace (Llama 3.2 3B base,
pretrained on 10M+ hours of audio, naturalness 9.5/10).

```sh
pip install -r scripts/requirements.txt   # one-time, downloads ~6-10GB model
npm run voice:hq                          # uses Higgs instead of Kokoro
```

Runs on Apple Silicon via PyTorch MPS. Generation is slower than Kokoro
(~10-30s per minute of audio on M2 Pro/M3/M4) but quality is the
current open-weight ceiling.

### Future — F5-TTS voice cloning

For the ultimate authenticity, [F5-TTS](https://github.com/SWivid/F5-TTS)
can clone Daniel's voice from a 5-15 second reference recording, then
generate every voiceover line in his actual voice via local AI. Not wired
up yet, but the file paths in `src/assets/audio/` are model-agnostic — any
TTS pipeline can produce the same set of WAV files.

## Architecture

```
marketing/video/
├── package.json
├── pyproject.toml              # uv config for the Higgs Audio HQ path
├── remotion.config.ts          # quality defaults (CRF 16, h264, 60fps)
├── public/                     # gitignored — Remotion staticFile() root
│   ├── audio/                  # voice WAVs (npm run voice)
│   └── screencasts/            # raw screen captures (Screen Studio)
├── src/
│   ├── index.ts                # Remotion entrypoint
│   ├── Root.tsx                # composition registry
│   ├── content/
│   │   ├── script.ts           # ⭐ the locked script — single source of truth
│   │   └── script.json         # auto-generated mirror for Python (gitignored)
│   ├── compositions/
│   │   ├── Hook.tsx            # 5s validation spike
│   │   ├── HeroLoop30.tsx      # 30s autoplay-muted hero
│   │   └── Demo60.tsx          # 60s master demo
│   ├── components/
│   │   ├── HookReveal.tsx      # staggered word reveal
│   │   ├── ParakeetMark.tsx    # animated brand mark
│   │   ├── ScreencastSlot.tsx  # <Video> with branded placeholder fallback
│   │   ├── LowerThird.tsx      # caption strip
│   │   └── Closing.tsx         # final card (mark + headline + URL)
│   └── theme/
│       └── tokens.ts           # imports from brand-assets/palette
└── scripts/
    ├── generate-voice.ts       # default: Kokoro-82M via kokoro-js (Node)
    ├── generate-voice-hq.py    # premium: Higgs Audio V2 (Python via uv)
    ├── audition-voices.ts      # generates shortlist for picking a voice
    └── dump-script.ts          # exports SCRIPT to JSON for Python
```

## Currently scaffolded

- ✅ `Hook` — 5s reveal of the locked hook + supporting line (validation spike)
- ✅ `HeroLoop30` — 30s autoplay-muted hero (silent, captions carry)
- ✅ `Demo60` — 60s master demo with per-scene audio + screencast slots
- ✅ Kokoro-82M voiceover pipeline (pure Node, per-scene regeneration)
- ✅ Voice audition script — generates curated shortlist for picking a voice
- ✅ Higgs Audio V2 upgrade path (Python via uv, optional, premium quality)
- ✅ Reusable components: `ScreencastSlot`, `LowerThird`, `Closing`

## Roadmap

- ⏳ Capture screencasts (Screen Studio, four clips: cold open + 3 modes)
- ⏳ `SocialVertical15` — 9:16 portrait social cut
- ⏳ Mode-specific GIF clips (Dictation, YouTube, Meeting, Export)
- ⏳ F5-TTS voice clone of the founder's voice (most authentic option)

See `docs/marketing.md` for the full storyboard.

## Quality bar

All renders target **1080p / 60fps minimum**, **CRF 16** (visually lossless),
**48kHz audio mastered to -16 LUFS**. Springs for motion, never linear
interpolations. Brand palette from `brand-assets/palette/palette.json`,
typography from `docs/brand-identity.md`.

See `docs/marketing.md` § *Quality Bar* for the non-negotiables.

## Iteration discipline

One-way flow: **docs/marketing.md → src/content/script.ts → voice MP3s → rendered MP4s**.
Never edit a `.mp4` directly. Every change to copy starts in `docs/marketing.md`.
