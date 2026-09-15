#!/usr/bin/env bash
# Unconstrained Auto A/B for issue #1046. Score roster vs RTTM; do not run Exact/max.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELECTED="${SELECTED:-$ROOT/selected_files.tsv}"
VOXCONVERSE_ROOT="${VOXCONVERSE_ROOT:-$HOME/asr-bench/voxconverse}"
RESULTS_DIR="${RESULTS_DIR:-$HOME/asr-bench/issue-1046-ab/results}"
FROZEN_JSON="${FROZEN_JSON:-$HOME/asr-bench/fluidaudio-0.15.7-ab/results/candidate}"
ENGINE="${ENGINE:-parakeet}"

if [[ -z "${CANDIDATE_CLI:-}" ]]; then
  echo "Set CANDIDATE_CLI" >&2
  exit 1
fi
if [[ ! -x "$CANDIDATE_CLI" ]]; then
  echo "not executable: $CANDIDATE_CLI" >&2
  exit 1
fi

mkdir -p "$RESULTS_DIR/baseline" "$RESULTS_DIR/candidate"

while IFS=$'\t' read -r _role _split fid _rttm_speakers _rttm_end_s _rttm_speech_s relpath; do
  relpath="${relpath%$'\r'}"
  wav="$VOXCONVERSE_ROOT/$relpath"
  frozen="$FROZEN_JSON/${fid}.unconstrained.json"
  if [[ ! -f "$wav" ]]; then
    echo "missing wav: $wav" >&2
    exit 1
  fi
  if [[ ! -f "$frozen" ]]; then
    echo "missing frozen baseline: $frozen" >&2
    exit 1
  fi
  cp "$frozen" "$RESULTS_DIR/baseline/${fid}.unconstrained.json"

  out="$RESULTS_DIR/candidate/${fid}.unconstrained.json"
  if [[ -f "$out" ]]; then
    echo "skip candidate $fid unconstrained (exists)"
    continue
  fi
  echo "run candidate $fid unconstrained"
  tmp="$(mktemp -d)"
  if ! "$CANDIDATE_CLI" transcribe "$wav" \
      --engine "$ENGINE" \
      --format json \
      --no-history \
      --speaker-detection on \
      --output-dir "$tmp"; then
    echo "FAILED candidate $fid" >&2
    rm -rf "$tmp"
    exit 1
  fi
  produced="$(find "$tmp" -name '*.json' -type f -print -quit)"
  if [[ -z "$produced" ]]; then
    echo "no JSON for $fid" >&2
    rm -rf "$tmp"
    exit 1
  fi
  mv "$produced" "$out"
  rm -rf "$tmp"
done < <(tail -n +2 "$SELECTED")

echo "=== baseline ==="
python3 "$ROOT/scripts/score_speaker_count.py" --results-dir "$RESULTS_DIR" --arm baseline --unconstrained-only
echo "=== candidate ==="
python3 "$ROOT/scripts/score_speaker_count.py" --results-dir "$RESULTS_DIR" --arm candidate --unconstrained-only
