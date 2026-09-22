# Demo Agents — Landscape & The MacParakeet Recipe

> Status: **DATED RESEARCH SNAPSHOT** — last updated 2026-05-03. Product names,
> availability, prices, rankings, and model capabilities below are not current
> authority; reverify them before choosing or purchasing a tool.

## Why this doc

We need a steady flow of demo videos — X/Twitter, Reddit, YouTube Shorts,
blog posts, App Store-style screen recordings — and we'd like to scale that
without scheduling Daniel to record every clip by hand. This doc maps the
content-creation agent landscape, names the gap between "synthetic video
hype" and "scripted demo loop you can ship today," and gives a concrete
recipe MacParakeet can adopt now.

## Landscape at a glance

### Synthetic / generative video — **don't build on it for UI demos yet**

In May 2026, no model (Sora 2, Veo 3.1, Runway Gen-4.5, Kling 3.0, Pika 2.5,
Luma Ray3) can render a faithful, frame-stable macOS UI. They hallucinate
menu bars, drift typography, melt cursors. **Sora 2's app shut down
2026-04-26 and the API sunsets 2026-09-24** — don't build on it.

Use these tools only for B-roll, hero shots, "vibe" cuts at the head of a
video, or 2-second cinematic stings. The day a model can take a screenshot
+ a flow description and emit faithful-pixel UI demos, hand-recording dies —
track Veo 4 / Gen-5 / Q3-Q4 2026 releases.

### Demo recording / editing platforms

| Tool | macOS native | Why it earns its slot |
|---|---|---|
| **Screen Studio** | Yes (macOS only) | Auto-zoom on cursor/click, smooth cursor, auto-social aspects. Best for the polished hero clip. $29/mo |
| **Descript** | Yes | Text-based editing, Studio Sound, filler-word strip, AI Eye Contact, Overdub voice clone. Best for editing the talk track. $24-35/mo |
| **Tella** | Web + Mac | Auto-zoom, transcript-edit, filler removal, 4K. $19/mo |
| **Opus Clip** | Web | Long-form → 10 short-form clips, viral-moment detection, captions. **$29/mo for 10-shorts-from-one-demo fan-out.** |
| **Arcade.software** | Web | Recording → demo + video export, AI voiceover, brand kit. Hotspot replay (deterministic). |
| **Remotion** (OSS) | Local (Node) | Programmatic React → MP4. The #4 most-installed Claude Code skill (~126k installs). **Fully deterministic.** Best for animated explainers, infographics, intros. |
| Loom + Loom AI, CapCut AI | Mixed | Decent floor for casual clips; not where we differentiate |
| Synthesia / HeyGen / Tavus | — | AI-avatar narrator over your screen recording. Tavus has API for personalized variants. Probably not our voice. |
| Storylane, Supademo | Web | Browser-only capture; useful for *interactive embeds* on the marketing site, not native-app demos |

### The macOS automation building blocks (this is where MP has leverage)

| Block | Tool | Notes |
|---|---|---|
| Window-scoped capture | **ScreenCaptureKit** (Swift, macOS 12.3+) | Per-window `SCContentFilter`, async/await, hardware accelerated. **The only Apple-maintained API in 2026.** AVCaptureScreenInput is deprecated as of macOS 13. |
| Capture (CLI) | `screencapture -V <sec>` (built-in) or **SwiftCapture** (OSS, ScreenCaptureKit wrapper) | Region/window/full-screen, no install for `screencapture`. SwiftCapture adds multi-screen + per-app window. |
| Capture (CLI alt) | `ffmpeg -f avfoundation -i "<idx>:<idx>"` | Full-display only; pair with crop filter for window |
| Input synthesis | **`cliclick`** (`brew install cliclick`) | `c:x,y`, `kp:`, `t:"text"`, `kd/ku:` modifiers. Needs Accessibility perm |
| Audio routing → mic | **BlackHole 2ch** (OSS, free) | Set as MacParakeet mic input; `afplay -d BlackHole2ch` pipes pre-recorded utterance into the dictation pipeline |
| Audio routing (paid) | **Loopback 2.4.9** ($99, Apr 9 2026) | Wire-based routing, virtual devices, AppleScript-automatable |
| TTS (free, prototype) | **`say -v Zoe -o out.aiff "..."`** | Built-in, instant, fine for prototyping |
| TTS (cloud, branded) | **ElevenLabs** | Best expressiveness, pro voice cloning. ~$0.30/1k chars at scale |
| TTS (cheap real-time) | **Cartesia Sonic** | ~$5/mo for ~100k credits, 40-90ms latency, unlimited instant clones, 15 langs. **Watch this** — when it matches ElevenLabs quality at this price, every demo gets a free branded "Parakeet voice." |

### Does the "demo agent" exist yet? Almost — and there's an opening.

The pieces are converging but no single product takes "describe a flow →
finished MacParakeet demo video":

- **`splitbrain/ndemo`** (Claude Code skill) — narrated demo videos of *web*
  apps. Closest spiritual match. Browser-only.
- **Claude Code Video Toolkit** (`digitalsamba`, `wilwaldon`) — Remotion +
  screen recording + ffmpeg + Qwen3-TTS. Native, but you write the script.
- **Demo Video Builder** (Claude skill on mcpmarket) — TTS + screen
  recording + branded slides → MP4. Generic, not macOS-app-aware.
- **OpenAdapt** — record-once-replay-many on macOS. Brittle on UI changes.
- **Anthropic Computer Use** — runs in Docker/VNC by default; can drive a
  real Mac in research preview but too non-deterministic for repeatable
  shipping demos.

**The opportunity:** a `macparakeet/scripts/demo/` skill (or standalone
Claude skill) that wraps the recipe below, parameterized by `(flow_name,
narration_script, dictation_text, output_aspects)`. We'd be one of the first
OSS native-macOS demo agents. Reuse the `granola-export` skill style — single
self-contained dir.

## The MacParakeet recipe — use this today

Build `scripts/demo/record_demo.sh` that produces a deterministic 60-second
demo every run. No editor, no mouse. Everything scripted.

**One-time setup:**

```bash
brew install cliclick ffmpeg
# Install BlackHole 2ch from existential.audio
# In Audio MIDI Setup: create Aggregate Device "MacParakeet-Demo"
#   = BlackHole 2ch (+ optionally your speakers, for monitoring)
# In MacParakeet Settings: input device → "MacParakeet-Demo"
# Bind dictation hotkey to F18 (single-key, scriptable, ADR-009)
# Grant Terminal: Accessibility + Screen Recording in System Settings
```

**The loop:**

```bash
#!/bin/bash
set -e
SCRIPT="MacParakeet turns your voice into text, instantly. Watch."
DEMO="Hello world, this is a fast local dictation demo on macOS."

# 1. Synthesize narration to AIFF (Apple `say`) or call ElevenLabs/Cartesia
say -v Zoe -o /tmp/narration.aiff "$SCRIPT"
say -v Zoe -o /tmp/dictation.aiff "$DEMO"

# 2. Launch + focus the app
open -a MacParakeet
sleep 1
osascript -e 'tell app "MacParakeet" to activate'

# 3. Start window-scoped screen recording in the background
swiftcapture --window "MacParakeet" --fps 60 --output /tmp/demo.mov &
REC_PID=$!
sleep 0.5

# 4. Play intro narration (heard by viewer, NOT routed to mic)
afplay /tmp/narration.aiff

# 5. Trigger dictation hotkey (F18 = key code 79)
cliclick kp:f18
sleep 0.2

# 6. Pipe dictation audio into MacParakeet via BlackHole
#    afplay -d <device> routes to that output device only
afplay -d BlackHole2ch /tmp/dictation.aiff

# 7. Toggle hotkey off, let pipeline finish
cliclick kp:f18
sleep 1.5

# 8. Stop recording
kill -INT $REC_PID
wait $REC_PID 2>/dev/null

# 9. Post-process for X (1:1) and Shorts (9:16) from one source
ffmpeg -y -i /tmp/demo.mov -i /tmp/narration.aiff \
  -vf "crop=ih:ih,scale=1080:1080" \
  -c:v h264_videotoolbox -b:v 8M -c:a aac -shortest \
  dist/demo-twitter.mp4

ffmpeg -y -i /tmp/demo.mov -i /tmp/narration.aiff \
  -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920" \
  -c:v h264_videotoolbox -b:v 10M -c:a aac -shortest \
  dist/demo-shorts.mp4
```

**Why each piece:**

- **ScreenCaptureKit** gives **window-scoped** capture so menu bar, mouse
  outside the app, and other apps never bleed in.
- `cliclick kp:f18` deterministically fires the dictation hotkey — F18 is
  unbound by macOS and matches ADR-009 single-key support; no
  accidental modifier collisions like the Fn-chord case.
- `afplay -d BlackHole2ch` is the magic step: it sends a pre-recorded
  utterance to the BlackHole virtual output, which MacParakeet sees as a
  mic input. Same Parakeet pipeline, fully scripted, byte-identical every run.
- Two `ffmpeg` outputs from one recording = X (1:1) + Shorts/Reels (9:16)
  without re-recording.

**Hotkey behavior caveat:** the recipe assumes F18 toggles dictation
on/off (press → start, press → stop). If MacParakeet's hotkey is
press-and-hold, swap `cliclick kp:f18` for `cliclick kd:f18 ... ku:f18`
around step 6.

## Post-production: X / Twitter video prep

X has the strictest acceptance ceiling of the social platforms; if it works
there it'll work everywhere. The killer constraint people miss is **aspect
ratio: ≤ 2.39:1**. A 3:1 screen recording will be rejected even if the
codec is fine.

| Constraint | Value |
|---|---|
| Container | MP4 |
| Video codec | H.264 (NOT HEVC — Apple Silicon QuickTime defaults to HEVC; convert) |
| Audio codec | AAC LC |
| Resolution | ≤ 1920×1200 |
| Aspect ratio | 1:1 / 9:16 / 16:9 (≤ 2.39:1 ceiling) |
| Frame rate | Constant 30 or 60 fps |
| Duration | ≤ 2:20 (free tier) |
| File size | ≤ 512 MB |

**The conversion recipe** for any source `.mov`:

```bash
ffmpeg -y -i in.mov \
  -vf "scale=1920:-2:flags=lanczos,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=#0E0F12,setsar=1" \
  -c:v libx264 -profile:v high -level 4.0 -pix_fmt yuv420p \
  -preset slow -crf 20 -r 30 \
  -movflags +faststart \
  -c:a aac -b:a 128k -ar 48000 \
  out.mp4
```

`#0E0F12` = brand `ink`. The pad fills with brand color so a 3:1 recording
becomes a 16:9 frame X will accept.

## Polish toolchain (when scripted output isn't enough)

Layer one or both of these on top of the raw recipe output for launch / hero
videos:

- **Screen Studio** — auto-zoom on clicks + cursor smoothing. Drop the raw
  `.mov` in, get a polished export. ~30 seconds of work for 80% of the
  visual polish you'd hand-edit.
- **Descript** — talk-track editing by transcript. Strip filler words,
  smooth pacing, swap audio without re-recording. Pair with Overdub if
  you've cloned a Parakeet voice.
- **Opus Clip** — feed a 5-minute long-form demo, get 10 short-form clips
  with auto-captions and viral-moment detection. The fastest way to fan
  one demo into a week of social posts.

## Watch list

1. **Veo 4 / Runway Gen-5 with grounded UI rendering.** When a model takes
   a screenshot + flow description and emits faithful-pixel UI demos,
   hand-recording dies. Track Q3-Q4 2026 releases.
2. **Remotion + Claude Code as the dominant programmatic-video stack.**
   126k+ installs, growing weekly. Worth seeding a `macparakeet-demo`
   Remotion template even before we adopt it — community contributions
   multiply.
3. **Cartesia Sonic 2.x voice cloning at $5/mo.** Sub-$10/mo unlimited-clone
   TTS at ElevenLabs quality unlocks a free branded "Parakeet voice" for
   every demo, podcast intro, error tooltip narration.
4. **OpenAdapt-class self-recovering computer-use agents.** When they
   handle window-drift and modal popups deterministically, the recipe above
   collapses to one prompt.
5. **A native-macOS-aware demo skill.** The market gap is real — every
   browser-demo tool exists, no native-Mac one does. First-mover OSS
   Claude skill that drives any macOS app via cliclick + ScreenCaptureKit
   + BlackHole + TTS would be widely forked. Could double as MacParakeet's
   internal demo tooling and external dev-evangelism content.

## References

- [Sora 2 discontinuation](https://help.openai.com/en/articles/20001152-what-to-know-about-the-sora-discontinuation)
- [Veo 3.1 update (Google)](https://blog.google/innovation-and-ai/technology/ai/veo-3-1-ingredients-to-video/)
- [AI video model comparison 2026 (Lushbinary)](https://lushbinary.com/blog/ai-video-generation-sora-veo-kling-seedance-comparison/)
- [Best interactive demo software 2026 (Arcade)](https://www.arcade.software/post/best-interactive-demo-software-2026)
- [Screen Studio](https://screen.studio/)
- [Descript](https://www.descript.com/pricing)
- [Tella pricing 2026](https://www.tella.com/pricing)
- [Remotion](https://www.remotion.dev/)
- [ScreenCaptureKit (Apple)](https://developer.apple.com/documentation/screencapturekit/)
- [Engineering a macOS AI agent with ScreenCaptureKit (Fazm)](https://earezki.com/ai-news/2026-03-17-what-we-learned-building-a-macos-ai-agent-in-swift-screencapturekit-accessibility-apis-async-pipelines/)
- [SwiftCapture CLI](https://github.com/GlennWong/SwiftCapture)
- [`cliclick`](https://github.com/BlueM/cliclick)
- [BlackHole](https://existential.audio/blackhole/)
- [Loopback 2.4.9](https://rogueamoeba.com/loopback/whatsnew.php)
- [ElevenLabs vs Cartesia 2026](https://elevenlabs.io/blog/elevenlabs-vs-cartesia)
- [TTS API comparison 2026 (TokenMix)](https://tokenmix.ai/blog/tts-api-comparison)
- [`splitbrain/ndemo` Claude skill](https://github.com/splitbrain/ndemo)
- [Claude Code Video Toolkit](https://github.com/digitalsamba/claude-code-video-toolkit)
- [OpenAdapt](https://github.com/OpenAdaptAI/OpenAdapt)
- [X video specs](https://help.x.com/en/using-x/twitter-videos)
