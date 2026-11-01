#!/usr/bin/env python3
"""Render the original Bloom and Gong pairs for MacParakeet.

NumPy and SciPy are offline authoring dependencies only. No sampled audio,
reference recordings, or network access enter this generator. See
docs/dictation-sound-design.md for provenance and reference dependency versions.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import wave

import numpy as np
from scipy.signal import butter, resample_poly, sosfilt

ROOT = Path(__file__).resolve().parents[2]
RATE = 48000
SR = RATE * 4


def env(t, attack, decay):
    return (1 - np.exp(-t / attack)) ** 2 * np.exp(-t / decay)


def max_rms(x, seconds=.1):
    p = np.mean(x * x, axis=1)
    n = round(seconds * RATE)
    s = np.r_[0, np.cumsum(p)]
    return np.sqrt(np.max((s[n:] - s[:-n]) / n))


def render_bloom(cue):
    start = cue == 'start'
    duration = .660 if start else .860
    t = np.arange(round(SR * duration)) / SR
    base = 440.0 if start else 277.18
    # A small, repeatable pitch relaxation and irregular slow drift. This is
    # authored modulation, not an extracted Handy phase/frequency trajectory.
    drift = .75 * np.exp(-t / .045)
    drift += .60 * np.sin(2 * np.pi * 2.7 * t + .3) * (1 - np.exp(-t / .02))
    drift += .28 * np.sin(2 * np.pi * 6.1 * t - .7) * np.exp(-t / .35)
    phase = 2 * np.pi * np.cumsum(base + drift) / SR

    # A shaped body attack connects the contact mode to the resonance.
    attack = .010 if start else .022
    decay = .115 if start else .140
    fundamental = env(t, attack, decay)
    # A separate weak late component bends the stop tail away from a single
    # straight exponential; it does not raise the entire early/body decay.
    if start:
        late = .024 * (1 - np.exp(-t / .180)) ** 3 * np.exp(-t / .55)
    else:
        # A later opening keeps the added resonance from overfilling the
        # middle decay.
        late = .115 * (1 - np.exp(-t / .250)) ** 6 * np.exp(-t / .85)
    mid = np.sin(phase) * (fundamental + late)
    # A short higher contact mode leads into the body. No hiss or second hit.
    strike = .24 if start else .13
    mid += strike * np.sin(phase * 4.025 + .17) * env(t, .0035 if start else .005, .027 if start else .035)
    mid += .035 * np.sin(phase * 9.91 + .31) * env(t, .002, .010)
    mid += .018 * np.sin(phase * 2.008 - .23) * env(t, .006, .052)

    # A relatively centered excitation, followed by a quieter evolving
    # side component. Tail width can grow while absolute level decreases.
    if start:
        side_envelope = .07 * fundamental
        side_envelope += .095 * (1 - np.exp(-t / .065)) ** 2 * np.exp(-t / .220)
    else:
        side_envelope = .03 * fundamental
        side_envelope += .18 * (1 - np.exp(-t / .150)) ** 3 * np.exp(-t / .360)
        side_envelope *= np.exp(-np.maximum(0, t - .40) ** 2 / .21 ** 2)
    side_phase = phase + np.pi / 2
    side_phase += .13 * np.sin(2 * np.pi * 1.8 * t + .4)
    side_phase += .05 * np.sin(2 * np.pi * 4.3 * t)
    side = np.sin(side_phase) * side_envelope
    audio = np.stack([mid + side, mid - side], axis=1)

    return finish(audio)


def render_gong(cue):
    start = cue == 'start'
    duration = .800 if start else .950
    t = np.arange(round(SR * duration)) / SR
    base = 329.63 if start else 220.0
    attack = .009 if start else .014
    decay = .150 if start else .180
    # Inharmonic, independently damped bronze modes; restrained beating.
    # No physical-instrument or health-effect claim is implied.
    mid = np.zeros_like(t)
    side = np.zeros_like(t)
    modes = [(1, 1, 1), (1.483, .25, .85), (2.034, .12, .66),
             (2.695, .055, .46), (3.867, .025, .29), (5.106, .012, .20)]
    for i, (ratio, amplitude, damping) in enumerate(modes):
        phase = 2 * np.pi * base * ratio * (t + .0015 * .025 * (1 - np.exp(-t/.025)))
        body = amplitude * env(t, attack / (1 + .12 * i), decay * damping)
        beat = 2 * np.pi * (1.15 + .21 * i) * t
        mid += body * (.87 * np.sin(phase) + .13 * np.sin(phase + beat))
        spatial = .04 + .16 * (1 - np.exp(-t / .16))
        side += body * spatial * np.cos(phase + .12 * np.sin(beat))
    phase = 2 * np.pi * base * t
    late = (.030 if start else .060) * (1 - np.exp(-t/.200)) ** 4 * np.exp(-t/.55)
    mid += late * np.sin(phase)
    side += .14 * late * np.cos(phase)
    audio = np.stack([mid + side, mid - side], axis=1)

    return finish(audio)


def finish(audio):
    audio = sosfilt(butter(2, 22, btype='highpass', fs=SR, output='sos'), audio, axis=0)
    audio = resample_poly(audio, 1, 4, axis=0)
    window = np.ones(len(audio))
    n = round(.002 * RATE)
    window[:n] *= np.sin(np.linspace(0, np.pi / 2, n)) ** 2
    n = round(.085 * RATE)
    window[-n:] *= np.sin(np.linspace(np.pi / 2, 0, n)) ** 2
    dc = np.sum(audio * window[:, None], axis=0) / np.sum(window)
    audio = (audio - dc) * window[:, None]
    gain = 10 ** (-10.5 / 20) / max_rms(audio)
    peak = np.max(np.abs(resample_poly(audio, 4, 1, axis=0)))
    audio *= min(gain, 10 ** (-2 / 20) / peak)
    audio[0] = audio[-1] = 0
    return audio


def describe(x, data):
    p = np.mean(x * x, axis=1)
    cumulative = np.cumsum(p) / np.sum(p)
    intervals = np.searchsorted(cumulative, [.05, .95, .99]) / RATE * 1000
    mid = np.mean(x, axis=1)
    side = (x[:, 0] - x[:, 1]) / 2
    stereo = []
    for lo, hi in [(0, .05), (.05, .15), (.15, .3), (.3, .5), (.5, len(x) / RATE)]:
        a, b = round(lo * RATE), round(hi * RATE)
        mid_e, side_e = np.mean(mid[a:b] ** 2), np.mean(side[a:b] ** 2)
        stereo.append({'interval_ms': [lo * 1000, hi * 1000],
                       'side_mid_db': round(float(10 * np.log10(max(side_e, 1e-25) / mid_e)), 3)})
    return {
        'sha256': hashlib.sha256(data).hexdigest(),
        'duration_ms': round(len(x) / RATE * 1000),
        'max100ms_rms_dbfs': round(float(20 * np.log10(max_rms(x))), 3),
        'sample_peak_dbfs': round(float(20 * np.log10(np.max(np.abs(x)))), 3),
        'estimated4x_peak_dbfs': round(float(20 * np.log10(np.max(np.abs(resample_poly(x, 4, 1, axis=0))))), 3),
        'energy5_95_99_ms': [round(float(v), 2) for v in intervals],
        'stereo_correlation': round(float(np.corrcoef(x.T)[0, 1]), 5),
        'mono_energy_delta_db': round(float(10 * np.log10(np.mean(mid * mid) / np.mean(p))), 3),
        'side_mid_by_interval': stereo,
        'first_samples': x[0].tolist(), 'last_samples': x[-1].tolist(),
    }


def encode(style, cue, audio):
    # Keep the audition's seed identity independent of production filenames.
    # This preserves the exact Bloom audition and Gong companion WAV bytes.
    seed_name = f"bloom_v3_motion_{cue}.wav" if style == "bloom" else f"gong_v3_{cue}.wav"
    seed = int.from_bytes(hashlib.sha256(seed_name.encode()).digest()[:8], "little")
    rng = np.random.default_rng(seed)
    quantized = np.rint(audio * 8388607 + rng.random(audio.shape) - rng.random(audio.shape)).astype(np.int32)
    quantized[0] = quantized[-1] = 0
    assert np.max(np.abs(quantized)) < 8388607
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(2)
        wav.setsampwidth(3)
        wav.setframerate(RATE)
        wav.writeframes(b"".join(int(value).to_bytes(3, "little", signed=True) for value in quantized.ravel()))
    return output.getvalue(), quantized / 8388608.0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify WAVs and manifest without writing")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "Sources/MacParakeet/Resources")
    args = parser.parse_args()
    manifest = {
        "format": {"sample_rate_hz": RATE, "channels": 2, "pcm_bits": 24},
        "source": "Original Bloom and Gong modal synthesis; scripts/dev/generate_dictation_sounds.py",
        "reference_authoring_versions": {"numpy": "2.4.2", "scipy": "1.17.1"},
        "level_note": "Maximum 100 ms channel-mean RMS aligned to -10.5 dBFS; not a perceptual loudness or acoustic exposure measurement.",
        "assets": {},
    }
    failures = []
    for style, render in (("bloom", render_bloom), ("gong", render_gong)):
        for cue in ("start", "stop"):
            data, audio = encode(style, cue, render(cue))
            filename = f"macparakeet_{style}_{cue}.wav"
            path = args.output_dir / filename
            manifest["assets"][filename] = describe(audio, data)
            if args.check:
                if not path.is_file() or path.read_bytes() != data:
                    failures.append(str(path))
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
    manifest_path = ROOT / "docs/assets/dictation-sounds/manifest.json"
    encoded = (json.dumps(manifest, indent=2) + "\n").encode()
    # Alternate outputs are for authoring experiments, not the committed manifest.
    if args.output_dir.resolve() == (ROOT / "Sources/MacParakeet/Resources").resolve():
        if args.check:
            if not manifest_path.is_file() or manifest_path.read_bytes() != encoded:
                failures.append(str(manifest_path))
        else:
            manifest_path.parent.mkdir(parents=True, exist_ok=True)
            manifest_path.write_bytes(encoded)
    if failures:
        raise SystemExit("Generated assets differ: " + ", ".join(failures))
    print(f"{'Verified' if args.check else 'Rendered'} 4 original Bloom/Gong stereo {RATE} Hz / 24-bit cues.")


if __name__ == "__main__":
    main()
