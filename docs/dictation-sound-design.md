# Original dictation sounds

MacParakeet has three original pairs for microphone-open and microphone-closed
feedback. **Pebble is the recommended starting point for daily use.** Bloom adds
brightness; Gong offers a brief, warmer bronze resonance. These are deliberate
sound-design choices, not findings that one timbre is universally best.

## Sound palette

| Pair | Character and purpose | Start / stop length |
| --- | --- | --- |
| Pebble | Rounded mallet-like taps; the shortest and most restrained option | 190 / 155 ms |
| Bloom | Light, glass-like tones with a little more ring | 240 / 210 ms |
| Gong | Compact bowl-inspired resonance with subtly beating partials | 340 / 380 ms |

Every start cue has two rising articulations. Every stop cue has one lower,
settling articulation. Rhythm and pitch both distinguish the events. None is
a transcription-success cue, notification, alarm, or musical celebration.
Gong's meditative character is an aesthetic direction; no therapeutic effect
is claimed.

These are optional presets. The master toggle stays off by default, the default
pair stays macOS Tink/Pop at 40%, and users can select each cue and volume
independently. Saved Handy Pop selections map to Pebble and Handy Marimba to
Bloom on decode. This deliberately changes those two selected sounds while
retaining their saved volumes and imported-file metadata. None, zero volume,
custom files and the system selection retain their meaning.

## Design basis

Apple's [Designing Sound](https://developer.apple.com/videos/play/wwdc2017/803/)
recommends sparse, quiet feedback, meaningful timing, an off option, listening
on actual devices/headphones, and living with candidates over repeated use.
Its production advice includes removing leading silence and fading edited
endings. That motivates compact cues with immediate, softened attacks and
smooth tails.

The [Glasgow earcon guidelines](https://www.dcs.gla.ac.uk/~stephen/earcon_guidelines.shtml)
support related sound families with recognizable differences and restrained
levels under user control. Their numerical suggestions concern different
tasks and are not optimal tuning values for modern dictation. Our note lengths,
pitches and gain are authoring choices. Apple also calls for
[visual equivalents to audio feedback](https://developer.apple.com/design/human-interface-guidelines/accessibility).
The existing visual capture UI remains the source of state when cues are muted.

Short files do not prove that speech cannot be masked or recorded through the
speakers. Capture timing is unchanged: the start cue follows successful capture
startup, and the stop cue follows capture closure. Playback does not gate
microphone capture or discard a fixed interval of early speech.

## Provenance and reproducibility

All six `macparakeet_{pebble,bloom,gong}_{start,stop}.wav` files are generated
from original equations and parameters in
[`scripts/dev/generate_dictation_sounds.py`](../scripts/dev/generate_dictation_sounds.py).
They contain no Handy audio, recordings, soundfonts, downloaded samples, or
model-generated audio. The source and assets are part of this repository under
its existing [license](../LICENSE). There is no synthesis dependency in the app:
it plays bundled WAVs using the existing prepared audio players.

```sh
python3 scripts/dev/generate_dictation_sounds.py
python3 scripts/dev/generate_dictation_sounds.py --check
```

The generator uses only Python's standard library. It adds decaying sinusoidal
modes with material-specific ratios, softens the attacks, corrects residual DC
using a tapered window, fades the ends, and quantizes to mono 48 kHz / 24-bit PCM
with deterministic triangular dither. Mono keeps the identity independent of
stereo placement. Twenty-four-bit storage allows editing headroom; it is not
evidence of better perceived quality by itself.

The initial level alignment uses maximum 50 ms RMS at -18 dBFS, capped at a
-6 dBFS sample peak. Actual peaks are approximately -9 to -12 dBFS. This leaves
headroom and avoids picking a winner merely because its peak was normalized
to full scale. It does **not** establish equal perceived loudness across timbres
or a calibrated acoustic level at the listener's ear. Use the existing volume
controls to tune the pair in context.

[`manifest.json`](assets/dictation-sounds/manifest.json) records the hashes,
format, peaks, RMS, DC, endpoints and time by which 99% of sample energy has
occurred. The 99% energy times are roughly 85–202 ms even though the files
include quiet tails. File duration and perceived duration are different.

## Scope and verification

This change replaces four bundled assets with six originals, updates preset
names and compatibility decoding, and removes the retired sound attribution
from packaging. It does not change capture, playback scheduling, fallback,
preview interruption, custom-file validation, completion/error sounds, or the
master sound preference. Removing the old cases is internal to this app;
the CLI exposes no sound-style contract.

The focused tests cover legacy decoding, retained volumes/import metadata,
current-style persistence, distinct capture/preview resources, resource decoding,
fallback, mute, and rapid cue interruption. The generator's `--check` verifies
the committed audio against its source and manifest.

Waveform checks and playback success do not establish subjective excellence.
Before changing a default or calling the set acoustically qualified, audition
at ordinary volume on Mac speakers, wired headphones, and a Bluetooth route.
Check first-phoneme preservation when speaking at cue onset, speaker-to-mic
leakage, rapid start/stop, media coexistence, mono/one-ear recognition, and fatigue
after several days of use. A file's smooth endpoints do not prove that an
interrupted player is click-free; test actual interruptions separately.
