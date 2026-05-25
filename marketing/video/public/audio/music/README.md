# Music & Sound Design (`public/audio/music/`)

The brand film picks up audio from this directory at render time. The
files are **not tracked** (gitignored) — they come from royalty-free
libraries and are sourced once per project.

> **Current status:** procedural placeholder tracks have been synthesized
> via ffmpeg sines + envelopes. They're brand-tonal (A-minor pad, 120 BPM
> sparkle pulse, soft reverb) and prove the audio pipeline works end-to-end,
> but they're *not* premium-produced. Replace with sourced or AI-generated
> tracks when you want to ship for real. See "Regenerate placeholder" below.

## Required files

| File | Used by | What it is | Length |
|---|---|---|---|
| `brand-track.wav` | `BrandShow30` (audioReady=true) | Music bed for the full 30s film | exactly 30 s |
| `brand-track-15s.wav` | `BrandShow15Portrait` | 15 s edit of the same bed (or separate track) | exactly 15 s |
| `logo-sting.wav` | both BrandShow variants | Single chime / synth swell at the logo reveal | 2–4 s |

If the files are missing and the composition is rendered with
`audioReady=false` (default), the brand film renders silently — no
errors, no broken sequences. Flip `audioReady=true` in the render
command (`npm run render:brand-audio`) once the files are in place.

## Brand voice for the music

The film leans Warhol-meets-quiet-confidence. The track should:

- **BPM**: 110–125 — energetic enough to feel alive, calm enough to feel
  considered. Avoid anything over 130 BPM.
- **Texture**: minimal electronic / indie ambient. Sparse drums, clean
  synths, *no vocals*. Think Tycho, Bonobo's calmer cuts, Nils Frahm's
  more rhythmic moments.
- **Arc**: a quiet first ~2 seconds (to match the intro mark fade-in),
  builds through the grid section, then resolves / fades around 20 s
  (where the fade-to-ink begins). A drop-style track with a quiet outro
  is ideal.
- **Mood**: confident, modern, slightly playful. The Pop palette is
  playful; the music should echo without becoming kitsch.

**Avoid**: heavy bass, distorted guitars, cinematic strings, anything
that sounds like a movie trailer.

## Brand voice for the sting

Single sound event that hits the moment the logo reveals (frame 1380 of
BrandShow30, roughly 0:23):

- One synth note, a soft chime, or a calm bell-like tone
- Length 2–4 seconds with a long natural decay
- Should *resolve* — not a stinger that demands a follow-up
- Adds weight to the logo without being loud

**Avoid**: notification dings, sword unsheathing sounds, cinematic
"booms," anything percussive enough to startle.

## Recommended search queries

### Pixabay (free, attribution optional, broad library)

- <https://pixabay.com/music/search/minimal%20electronic/> → filter by
  3-min or shorter, ~120 BPM range
- <https://pixabay.com/music/search/ambient%20chill/> → minimal indie
  electronic
- Sound effects for the sting:
  <https://pixabay.com/sound-effects/search/synth%20chime/> or
  `/search/soft%20bell/`

### Mixkit (free, attribution-required for some)

- <https://mixkit.co/free-stock-music/tag/electronic/>
- <https://mixkit.co/free-stock-music/tag/minimal/>
- Sound effects: <https://mixkit.co/free-sound-effects/notification/>
  → look for "soft notification" / "subtle chime"

### Free Music Archive (Creative Commons)

- <https://freemusicarchive.org/genre/Electronic/> → filter for CC-BY or
  CC0 licenses, electronic/minimal/ambient

### If you have a Suno subscription (~$8/mo)

Prompt suggestion for a 30 s custom track:

> Minimal electronic instrumental, 120 BPM, sparse clean synths, soft
> kick drum on every beat 8–22 s, no vocals, quiet intro and outro,
> modern indie ambient mood, confident but considered, 30 seconds total

## Editing notes

If a track is longer than 30 s, trim or fade it to fit. ffmpeg cookbook:

```sh
# Trim to exactly 30s and fade the last 1.5s out
ffmpeg -i source.mp3 -ss 0 -t 30 -af "afade=t=out:st=28.5:d=1.5" -c:a pcm_s16le brand-track.wav

# 15s edit for portrait variant
ffmpeg -i source.mp3 -ss 0 -t 15 -af "afade=t=out:st=13.5:d=1.5" -c:a pcm_s16le brand-track-15s.wav
```

For the sting, target 2–3 s with a long natural decay tail:

```sh
ffmpeg -i raw-chime.mp3 -t 3 -af "afade=t=out:st=2.0:d=1.0" -c:a pcm_s16le logo-sting.wav
```

## Regenerate the procedural placeholder

If you've deleted the placeholder tracks and want them back without
sourcing a new track, the synthesis is reproducible:

```sh
# Bass layer — A2 (110Hz), present throughout
ffmpeg -y -f lavfi -i "sine=frequency=110:duration=30:sample_rate=44100" \
  -af "volume=0.18,afade=t=in:st=0:d=1.5,afade=t=out:st=27:d=3" \
  /tmp/mp-bass.wav

# Mid chord — A minor (A3+C4+E4), enters at 2s, exits at 23s
ffmpeg -y \
  -f lavfi -i "sine=frequency=220:duration=30:sample_rate=44100" \
  -f lavfi -i "sine=frequency=261.63:duration=30:sample_rate=44100" \
  -f lavfi -i "sine=frequency=329.63:duration=30:sample_rate=44100" \
  -filter_complex "[0:a][1:a][2:a]amix=inputs=3,volume=0.22,afade=t=in:st=2:d=1.5,afade=t=out:st=23:d=2.5" \
  /tmp/mp-chord.wav

# Sparkle — E5 with 2Hz tremolo (= 120 BPM pulse), 4-20s
ffmpeg -y -f lavfi -i "sine=frequency=659.25:duration=30:sample_rate=44100" \
  -af "tremolo=f=2:d=0.5,volume=0.06,afade=t=in:st=4:d=2.5,afade=t=out:st=19:d=2" \
  /tmp/mp-sparkle.wav

# Mix with subtle echo
ffmpeg -y \
  -i /tmp/mp-bass.wav -i /tmp/mp-chord.wav -i /tmp/mp-sparkle.wav \
  -filter_complex "[0:a][1:a][2:a]amix=inputs=3:duration=longest:normalize=0,aecho=0.5:0.5:80:0.3" \
  -ar 44100 -ac 2 public/audio/music/brand-track.wav

# Logo sting — A major chord (440/554.37/659.25) with 2s reverb tail
ffmpeg -y \
  -f lavfi -i "sine=frequency=440:duration=3.5:sample_rate=44100" \
  -f lavfi -i "sine=frequency=554.37:duration=3.5:sample_rate=44100" \
  -f lavfi -i "sine=frequency=659.25:duration=3.5:sample_rate=44100" \
  -filter_complex "[0:a][1:a][2:a]amix=inputs=3,volume=0.32,afade=t=in:st=0:d=0.08,afade=t=out:st=1.2:d=2.0,aecho=0.6:0.5:600:0.4" \
  -ar 44100 -ac 2 public/audio/music/logo-sting.wav

# Portrait 15s edit (trim + refade)
ffmpeg -y -i public/audio/music/brand-track.wav -t 15 \
  -af "afade=t=in:st=0:d=1,afade=t=out:st=12:d=3" \
  -ar 44100 -ac 2 public/audio/music/brand-track-15s.wav
```

## Honest assessment of the placeholder

What it does well:
- ✓ Brand-tonal (calm, no vocals, no theatrics)
- ✓ Has tempo (120 BPM pulse via sparkle tremolo)
- ✓ Has arc (bass-only intro → chord enters → sparkle pulses → resolution)
- ✓ Loops cleanly if needed
- ✓ Original (no IP, no attribution required)

What it doesn't do:
- ✗ Sound expensive. Pure sines are sterile compared to real synth patches.
- ✗ Have real drums / percussion. The "beat" is a tremolo, not a kick.
- ✗ Feel "indie electronic" the way Tycho / Bonobo / Nils Frahm would.

For a launch with budget: replace with a sourced track. For a quick
internal preview or a "soft launch" placeholder: this works.
