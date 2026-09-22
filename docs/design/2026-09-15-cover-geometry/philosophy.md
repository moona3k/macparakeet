# Library covers — Seed of Life

Status: **Accepted for native v2.** The HTML study remains the visual
reference; this note is the product rule.

## Philosophy

A Library cover is a quiet identity, not an explanation.

Meetings, local files, and failed remote artwork all land in the same
16:9 slot. That slot should look like one product, not a wallpaper
sampler and not a second brand. Brand coral stays reserved for
recording, CTAs, and other attention. Gold does not belong on the card.

The figure is ceremonial geometry, not a biometric. It rhymes with the
meeting pill without copying the spinner into a thumbnail. Nothing in
the image is audio, transcript, sentiment, speaker identity, or
quality. Titles, dates, duration, source, and status stay outside the
art, where they can stay legible.

One shared construction. Each card is still its own.

## The figure

Seven equal circles: one center and six petals. That is the Seed of
Life. At card size the silhouette is the whole language — rotation,
which rings are denser, and a small mineral hue drift. Fine forks,
second palettes, and a bright nucleus all fail this test.

Scale is **Present** (`0.76` of the study's comfortable size): large
enough that the rings survive duration and source overlays, small
enough that the night field still reads as space.

## What the input is

The only input is the transcription UUID plus the frozen recipe
version.

Hash that pair with a domain-separated FNV-1a seed, then SplitMix64,
exactly as v1. Do not use Swift `hashValue`, the title, date, path,
labels, duration, transcript text, confidence, audio, or a fresh
random value. Rename, relabel, favorite, edit, retranscribe, restart,
and audio removal must not change the cover.

v2 is an explicit recipe replacement. Existing items reshape once, at
this cutover, because the version is part of the seed. After v2 ships,
do not silently retune geometry. A later visual change needs v3.

## How the UUID is allowed to vary the figure

Independent streams keep a slider in the study from recoloring the
grid. Native v2 uses one geometry stream and one ink stream.

| Parameter | Range | Why |
|-----------|-------|-----|
| Rotation | `0 … π/3` | Six-fold symmetry. A full turn would duplicate poses. |
| Lit rings | one or two of the seven circles | Density, not a second color. Lit strokes are the same ink, stronger. |
| Center | `x = 0.50 ± 0.01`, `y = 0.40 ± 0.01` | Enough life to avoid a stamp. Not enough to look like two layouts. |
| Radius | `(0.168 … 0.180) × 0.76` of `min(width, height)` | Present scale. |
| Ink hue | sage `#7ea89a` ± 12° | One night, one mineral family. Adjacent cards related, not cloned. |
| Background | locked `#14191b` | Stops teal/plum from splitting the wall. |

Pale ring highlights and the small center bead use the same hue shift
as the ink, at higher value. They are not gold and not white chalk.

Do not vary:

- palette family (Tidal / Lichen / Plum)
- an accent pigment on the figure
- limb count, depth, or branching
- anything derived from sound or text

Two different UUIDs may still look similar. That is acceptable. The
title remains the reliable name.

## Drawing

A bounded static Canvas. Compute the recipe once per identity; the
canvas only maps normalized geometry onto the current card size. No
timer, animation, audio decode, network, or cache job for v2.

Real cached or remote artwork still wins. Generated art is the
missing-image fallback only.

Treat the image as decorative for accessibility.

## Out of scope

Audio envelopes, FFTs, transcript-seeded mandalas, per-item stored
recipe versions, mixing Seed of Life with leftover canopy cards, and
a user-facing palette picker.
