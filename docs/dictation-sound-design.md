# Original Bloom and Gong dictation sounds

MacParakeet offers two original microphone-open and microphone-closed pairs.
Bloom, selected after maintainer listening comparisons, has a rounded strike,
warm body, and quiet evolving resonance. Gong adds a deeper, bowl-like metallic
character with restrained beating between its modes. Each higher start and lower
stop is a single continuous gesture. The end means capture has closed, not that
transcription or insertion succeeded.

## Sound and controls

| Pair / cue | Fundamental | File length | 95% / 99% energy time |
| --- | --- | --- | --- |
| Bloom start | 440 Hz, with subtle authored drift | 660 ms | 205 / 316 ms |
| Bloom stop | 277.18 Hz, with subtle authored drift | 860 ms | 327 / 580 ms |
| Gong start | 329.63 Hz, with inharmonic modes | 800 ms | 227 / 356 ms |
| Gong stop | 220 Hz, with inharmonic modes | 950 ms | 291 / 489 ms |

File length includes the quiet tail and is not perceived duration. A centered
body carries the cue's identity; a quieter stereo component evolves during the
decay. Mono folding reduces measured energy by about 0.09 / 0.11 dB for Bloom
and 0.05 / 0.07 dB for Gong. This is a
signal check, not a hearing or device-compatibility study.

Both pairs are optional. The master toggle remains off by default, and the default
selection remains macOS Tink/Pop at 40%. Each cue and volume can be selected
independently. Saved Handy Pop and Handy Marimba selections decode as Bloom,
retaining saved volume and imported-file metadata. The unreleased `pebble`
draft selection also decodes as Bloom; its assets and picker choice are not
shipped. A saved `gong` selection uses the new Gong pair. None, zero volume, custom files, and the system selection retain their
existing behavior.

## Design basis

Apple's [Designing Sound](https://developer.apple.com/videos/play/wwdc2017/803/)
recommends sparse, quiet, purposeful cues, precise timing, user control, and
listening on real devices over repeated use. Its editing advice supports smooth
attacks and tails. The [Glasgow earcon guidelines](https://www.dcs.gla.ac.uk/~stephen/earcon_guidelines.shtml)
support related sounds with recognizable differences and restrained levels.
Neither source establishes optimal pitches, lengths, or loudness for dictation.
The frequencies, envelopes, and spatial movement here are creative choices.

The existing visual capture state remains available when cues are muted, in line
with Apple's [accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility).
Capture timing is unchanged: the start cue follows successful capture startup,
and the stop cue follows capture closure. Playback does not gate microphone
capture or discard an interval of early speech.

## Provenance and reproducibility

Only the four `macparakeet_{bloom,gong}_{start,stop}.wav` files are bundled.
Bloom is byte-identical to the approved third audition's motion pair; “motion”
is an authoring label, not a setting. Gong is the independently checked companion
pair created for the requested deeper flavor. The rejected first-draft assets
and other audition studies are not shipped. The assets and their original
synthesis source are contributed under this
repository's existing [license](../LICENSE).

The [offline generator](../scripts/dev/generate_dictation_sounds.py) uses original
equations and parameters. No Handy audio, sampled recordings, impulse responses,
soundfonts, extracted phase curves, or model-generated audio enter synthesis.
NumPy and SciPy are **authoring-only** dependencies; the app uses its existing
prepared audio players and gains no runtime dependency. Reference authoring
versions are NumPy **2.4.2** and SciPy **1.17.1**.

In an authoring environment with those versions:

```sh
python3 scripts/dev/generate_dictation_sounds.py
python3 scripts/dev/generate_dictation_sounds.py --check
```

The generator renders damped modes at 192 kHz, applies a low high-pass filter,
resamples to 48 kHz, removes residual DC with tapered boundaries, and exports
stereo signed 24-bit PCM WAV with deterministic triangular dither. Exact zero
boundary samples avoid a hard file edge. The audition seed names remain stable
so renaming the resources does not change the approved bytes.

| File | Frozen SHA-256 |
| --- | --- |
| Bloom start | `c59dc2829470c65c37a864d1fc0125f0898378738fdf29aeaf91f35616d6a410` |
| Bloom stop | `e56b0fc90c77130ae3ac928d06d6ceedf76a5774393991db475329a2aafaca83` |
| Gong start | `2411a8b858e6b79994acc0f6a939c492cce121242786187e68d00c4e72c98a42` |
| Gong stop | `131f0d4d80f3c1dbd93845766e1f252fb6fa0b3e0437f960804bcac5d128b78d` |

Each cue's maximum 100 ms channel-mean RMS is aligned to −10.5 dBFS. Estimated
four-times-oversampled peaks are approximately −4.80 / −6.16 dBFS for Bloom and
−3.99 / −4.49 dBFS for Gong. This is an
initial body-level alignment and headroom check, not equal perceived loudness,
a certified true-peak measurement, or calibrated exposure at the listener's ear.
The existing per-cue volume controls still govern app playback.

[`manifest.json`](assets/dictation-sounds/manifest.json) records the exact hashes,
format, RMS, peaks, energy times, stereo/mono measures, and endpoints.
`--check` compares the generated bytes and manifest without changing them; a
relative output path naming the committed resource directory also checks the
manifest. Alternate output directories support offline authoring experiments.

## Verification and limits

The focused tests cover legacy decoding, preserved volume/import metadata,
current-style persistence, the exact approved asset hashes, stereo resource
decoding, separate capture/preview players, fallback, mute, and rapid interruption.
Settings search includes Bloom, Gong, and the retired Handy names so existing users can
find the controls. The removed Handy files and notice are no longer packaged.

Maintainer audition approved Bloom, and Gong adds the requested companion flavor.
Gong's character is an aesthetic choice; no therapeutic effect is claimed. That preference does not establish
universal appeal or complete acoustic qualification. Speaker-to-microphone
leakage, first-phoneme preservation while speaking at cue onset, Bluetooth route
changes, mono/one-ear recognition, and comfort across repeated daily use remain
separate real-device checks. Smooth file endpoints do not prove interrupted
playback is click-free. This change does not alter the capture or playback
pipeline, completion/error sounds, or user defaults.
