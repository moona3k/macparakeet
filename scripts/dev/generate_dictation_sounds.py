#!/usr/bin/env python3
"""Render MacParakeet's original cues using only Python's standard library.

No samples, soundfonts, model output, or third-party audio are used. This is
an offline authoring tool, not a runtime dependency. See
docs/dictation-sound-design.md for intent, provenance and listening limits.
"""

import argparse
import hashlib
import io
import json
import math
from pathlib import Path
import random
import wave


ROOT = Path(__file__).resolve().parents[2]
RATE = 48_000
BITS = 24
SCALE = (1 << (BITS - 1)) - 1

# (frequency ratio, relative level, decay multiplier). Inharmonic modes give
# each material its character; upper modes die sooner than the fundamental.
MODES = {
    "pebble": [(1, 1, 1), (2.76, 0.18, 0.48), (5.40, 0.035, 0.24)],
    "bloom": [(1, 1, 1), (2.01, 0.24, 0.70), (3.97, 0.065, 0.40)],
    "gong": [(1, 1, 1), (1.48, 0.32, 0.86), (2.09, 0.17, 0.65),
             (2.67, 0.08, 0.44), (3.91, 0.025, 0.28)],
}

# Seconds, followed by strikes: (onset, Hz, amplitude, decay seconds).
# Start opens with two articulations; stop is one lower, settling articulation.
# Durations and pitches are creative choices, not perceptual standards.
CUES = {
    "pebble_start": (0.190, [(0, 587.33, 0.75, 0.029), (0.052, 783.99, 1, 0.035)]),
    "pebble_stop": (0.155, [(0, 523.25, 1, 0.036)]),
    "bloom_start": (0.240, [(0, 783.99, 0.72, 0.045), (0.060, 1046.50, 1, 0.048)]),
    "bloom_stop": (0.210, [(0, 659.25, 1, 0.052)]),
    "gong_start": (0.340, [(0, 392.00, 0.70, 0.065), (0.060, 523.25, 1, 0.075)]),
    "gong_stop": (0.380, [(0, 349.23, 1, 0.082)]),
}


def smooth_attack(t, seconds):
    return math.sin(math.pi / 2 * min(t / seconds, 1)) ** 2


def render(name, duration, strikes):
    material = name.split("_")[0]
    count = round(duration * RATE)
    samples = [0.0] * count
    for onset, frequency, level, decay in strikes:
        offset = round(onset * RATE)
        for i in range(offset, count):
            t = (i - offset) / RATE
            # A short downward relaxation rounds the strike without a siren
            # glide. Bronze uses paired modes to produce a restrained shimmer.
            bend = 0.003 if material == "gong" else 0.008
            cycles = frequency * (t + bend * 0.012 * (1 - math.exp(-t / 0.012)))
            value = 0.0
            for index, (ratio, strength, damping) in enumerate(MODES[material]):
                phase = 2 * math.pi * ratio * cycles
                mode = math.sin(phase)
                if material == "gong":
                    mode = 0.76 * mode + 0.24 * math.sin(phase + 2 * math.pi * (1.7 + index) * t)
                value += strength * math.exp(-t / (decay * damping)) * mode
            samples[i] += level * smooth_attack(t, 0.006 if material != "gong" else 0.009) * value

    # Remove residual DC without introducing a step; taper to zero at both
    # boundaries. These fades do not claim to fix an interrupted AVAudioPlayer.
    window = []
    for i in range(count):
        t = i / RATE
        remaining = (count - 1 - i) / RATE
        window.append(smooth_attack(t, 0.004) * smooth_attack(remaining, 0.030))
    mean = sum(x * w for x, w in zip(samples, window)) / sum(window)
    samples = [(x - mean) * w for x, w in zip(samples, window)]

    # Use a common 50-ms maximum RMS as an initial level alignment; preserve
    # at least 6 dB of peak headroom. This is not a perceptual loudness match.
    width = round(0.050 * RATE)
    squares = [x * x for x in samples]
    energy = sum(squares[:width])
    maximum = energy
    for i in range(width, count):
        energy += squares[i] - squares[i - width]
        maximum = max(maximum, energy)
    rms = math.sqrt(maximum / width)
    gain = min(10 ** (-18 / 20) / rms, 10 ** (-6 / 20) / max(map(abs, samples)))
    samples = [x * gain for x in samples]

    # Deterministic, one-LSB triangular dither at 24-bit quantization. Exact
    # zero endpoints are intentional so the file begins/ends at silence.
    rng = random.Random(name)
    quantized = [round(x * SCALE + rng.random() - rng.random()) for x in samples]
    quantized[0] = quantized[-1] = 0
    assert max(map(abs, quantized)) < SCALE
    pcm = b"".join(x.to_bytes(3, byteorder="little", signed=True) for x in quantized)
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(3)
        wav.setframerate(RATE)
        wav.writeframes(pcm)
    return output.getvalue(), [x / SCALE for x in quantized]


def describe(data, samples):
    energy = sum(x * x for x in samples)
    cumulative = 0.0
    energy_99_ms = 0.0
    for i, x in enumerate(samples):
        cumulative += x * x
        if cumulative >= 0.99 * energy:
            energy_99_ms = 1000 * i / RATE
            break
    return {
        "sha256": hashlib.sha256(data).hexdigest(),
        "bytes": len(data),
        "duration_ms": round(len(samples) / RATE * 1000, 2),
        "peak_dbfs": round(20 * math.log10(max(map(abs, samples))), 2),
        "rms_dbfs": round(10 * math.log10(energy / len(samples)), 2),
        "energy_99_ms": round(energy_99_ms, 2),
        "dc_mean": round(sum(samples) / len(samples), 10),
        "first_sample": samples[0],
        "last_sample": samples[-1],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify committed WAVs and manifest without writing")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "Sources/MacParakeet/Resources")
    args = parser.parse_args()
    manifest = {
        "format": {"sample_rate_hz": RATE, "channels": 1, "pcm_bits": BITS},
        "source": "Original modal synthesis; scripts/dev/generate_dictation_sounds.py",
        "level_note": "Maximum 50 ms RMS aligned to -18 dBFS with a -6 dBFS sample-peak ceiling; not a listening-test result.",
        "assets": {},
    }
    failures = []
    for name, (duration, strikes) in CUES.items():
        data, samples = render(name, duration, strikes)
        filename = f"macparakeet_{name}.wav"
        path = args.output_dir / filename
        manifest["assets"][filename] = describe(data, samples)
        if args.check:
            if not path.is_file() or path.read_bytes() != data:
                failures.append(str(path))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    manifest_path = ROOT / "docs/assets/dictation-sounds/manifest.json"
    encoded = (json.dumps(manifest, indent=2) + "\n").encode()
    # Alternate outputs are for authoring experiments, not the committed manifest.
    if args.output_dir == ROOT / "Sources/MacParakeet/Resources":
        if args.check:
            if not manifest_path.is_file() or manifest_path.read_bytes() != encoded:
                failures.append(str(manifest_path))
        else:
            manifest_path.parent.mkdir(parents=True, exist_ok=True)
            manifest_path.write_bytes(encoded)
    if failures:
        raise SystemExit("Generated assets differ: " + ", ".join(failures))
    print(f"{'Verified' if args.check else 'Rendered'} {len(CUES)} original mono {RATE} Hz / {BITS}-bit cues.")


if __name__ == "__main__":
    main()
