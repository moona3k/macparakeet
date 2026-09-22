#!/usr/bin/env bash
# Run the selected VoxConverse slice on two CLI binaries.
# Requires BASELINE_CLI and/or CANDIDATE_CLI. Skips missing arms and existing JSON.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELECTED="${SELECTED:-$ROOT/selected_files.tsv}"
VOXCONVERSE_ROOT="${VOXCONVERSE_ROOT:-$HOME/asr-bench/voxconverse}"
RESULTS_DIR="${RESULTS_DIR:-$HOME/asr-bench/fluidaudio-0.15.7-ab/results}"
ENGINE="${ENGINE:-parakeet}"

if [[ -z "${BASELINE_CLI:-}" && -z "${CANDIDATE_CLI:-}" ]]; then
  echo "Set BASELINE_CLI and/or CANDIDATE_CLI" >&2
  exit 1
fi

run_one() {
  local cli="$1" arm="$2" wav="$3" fid="$4" run="$5"
  shift 5
  local out_dir="$RESULTS_DIR/$arm"
  local out="$out_dir/${fid}.${run}.json"
  mkdir -p "$out_dir"
  if [[ -f "$out" ]]; then
    echo "skip $arm $fid $run (exists)"
    return 0
  fi
  echo "run $arm $fid $run"
  local tmp
  tmp="$(mktemp -d)"
  # --output-dir keeps CoreML chatter off stdout and writes one JSON file.
  if ! "$cli" transcribe "$wav" \
      --engine "$ENGINE" \
      --format json \
      --no-history \
      --speaker-detection on \
      --output-dir "$tmp" \
      "$@"; then
    echo "FAILED $arm $fid $run" >&2
    rm -rf "$tmp"
    return 1
  fi
  local produced
  produced="$(find "$tmp" -name '*.json' -type f | head -n 1)"
  if [[ -z "$produced" ]]; then
    echo "no JSON for $arm $fid $run" >&2
    rm -rf "$tmp"
    return 1
  fi
  mv "$produced" "$out"
  rm -rf "$tmp"
}

run_arm() {
  local cli="$1" arm="$2"
  if [[ ! -x "$cli" ]]; then
    echo "not executable: $cli" >&2
    return 1
  fi
  local role split fid rttm_speakers rttm_end_s rttm_speech_s relpath wav
  while IFS=$'\t' read -r role split fid rttm_speakers rttm_end_s rttm_speech_s relpath; do
    relpath="${relpath%$'\r'}"
    wav="$VOXCONVERSE_ROOT/$relpath"
    if [[ ! -f "$wav" ]]; then
      echo "missing wav: $wav" >&2
      return 1
    fi
    run_one "$cli" "$arm" "$wav" "$fid" unconstrained
    case "$role" in
      exact1*)
        run_one "$cli" "$arm" "$wav" "$fid" exact1 --speaker-count 1
        ;;
      max2_ceiling)
        run_one "$cli" "$arm" "$wav" "$fid" max2 --speaker-min 1 --speaker-max 2
        ;;
    esac
  done < <(tail -n +2 "$SELECTED")
}

if [[ -n "${BASELINE_CLI:-}" ]]; then
  run_arm "$BASELINE_CLI" baseline
fi
if [[ -n "${CANDIDATE_CLI:-}" ]]; then
  run_arm "$CANDIDATE_CLI" candidate
fi

echo
if [[ -d "$RESULTS_DIR/baseline" ]]; then
  echo "Score baseline:"
  python3 "$ROOT/scripts/score_speaker_count.py" --results-dir "$RESULTS_DIR" --arm baseline
fi
if [[ -d "$RESULTS_DIR/candidate" ]]; then
  echo "Score candidate:"
  python3 "$ROOT/scripts/score_speaker_count.py" --results-dir "$RESULTS_DIR" --arm candidate
fi
