#!/usr/bin/env bash
# Generates a deterministic 60-second 24 kHz mono WAV with silence at
# 20-22 s and 40-42 s. Used by VibeVoiceChunkedTranscriberTests for
# silence-detect integration tests without depending on real recordings.

set -euo pipefail

OUT="Tests/MacParakeetTests/STT/Fixtures/synthetic_silence.wav"
mkdir -p "$(dirname "$OUT")"

# Build the 60 s timeline by concatenating five lavfi sources:
# - 0..20 s:  1 kHz sine at ~-24 dB ("speech-like" energy)
# - 20..22 s: anullsrc silence
# - 22..40 s: 1 kHz sine
# - 40..42 s: anullsrc silence
# - 42..60 s: 1 kHz sine
#
# We use concat rather than chained afade because afade with t=out
# permanently zeros the stream beyond the fade — chaining a later
# t=in does not restore the original tone. Five distinct sources
# concatenated gives clean, sharp silence boundaries that register
# at the chunker's -30 dB / 0.3 s silencedetect threshold with margin.
ffmpeg -y \
  -f lavfi -i "sine=frequency=1000:duration=20:sample_rate=24000,volume=0.5" \
  -f lavfi -i "anullsrc=r=24000:cl=mono:duration=2" \
  -f lavfi -i "sine=frequency=1000:duration=18:sample_rate=24000,volume=0.5" \
  -f lavfi -i "anullsrc=r=24000:cl=mono:duration=2" \
  -f lavfi -i "sine=frequency=1000:duration=18:sample_rate=24000,volume=0.5" \
  -filter_complex "[0:a][1:a][2:a][3:a][4:a]concat=n=5:v=0:a=1[out]" \
  -map "[out]" \
  -ac 1 -ar 24000 -c:a pcm_s16le \
  "$OUT" >/dev/null 2>&1

echo "Generated: $OUT"
ffprobe -v error -show_entries format=duration "$OUT"
