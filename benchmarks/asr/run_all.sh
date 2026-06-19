#!/usr/bin/env bash
# Reproduce the ASR benchmark. Two tiers:
#
#   ./run_all.sh verify     # cheap, repo-only: scorer tests + re-score committed
#                           # evidence with 95% CIs (no datasets/models needed)
#   ./run_all.sh speed      # heavy: speed/memory micro-benchmark (needs assets)
#   ./run_all.sh transcribe # heavy: regenerate hypotheses from audio (needs assets)
#
# Default (no arg) = verify. The committed results/ make `verify` self-contained;
# `speed`/`transcribe` need the local assets pointed to by the env vars below.
set -euo pipefail
cd "$(dirname "$0")"

PY="${PY:-python3}"                       # set PY=venv/bin/python3 to use the venv
BOOT="${BOOT:-2000}"; SEED="${SEED:-1234}"  # bootstrap resamples / RNG seed
# Heavy-path assets (override as needed):
MP_CLI="${MP_CLI:-$HOME/code/macparakeet/.build/release/macparakeet-cli}"
FA_CLI="${FA_CLI:-$HOME/asr-bench/FluidAudio-0154/.build/release/fluidaudiocli}"
COHERE_MODEL="${COHERE_MODEL:-$HOME/asr-bench/cohere-coreml/q8}"
LS_CLEAN="${LS_CLEAN:-$HOME/asr-bench/LibriSpeech/test-clean}"

verify() {
  echo "== scorer unit tests =="
  "$PY" test_scorers.py
  echo; echo "== re-score committed multilingual (with 95% CI) =="
  "$PY" score_multi.py results/multilingual/*.jsonl --ci "$BOOT" --seed "$SEED"
  echo; echo "== re-score full-set English (with 95% CI) =="
  if ls results/full/*.jsonl >/dev/null 2>&1; then
    "$PY" score.py results/full/*.jsonl --ci "$BOOT" --seed "$SEED"
  elif [ -f results/full/full_hypotheses.tar.gz ]; then
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    tar -xzf results/full/full_hypotheses.tar.gz -C "$tmp"
    "$PY" score.py "$tmp"/*.jsonl --ci "$BOOT" --seed "$SEED"
  else
    echo "  (no full-set per-file data; see results/full/_summary_full.json)"
  fi
}

speed() {
  echo "== speed/memory micro-benchmark (one engine at a time) =="
  out=results/speed/speed_raw.jsonl; : > "$out"
  for e in parakeet-v2 parakeet-v3 parakeet-unified nemotron-en nemotron-multi whisper; do
    "$PY" speed_bench.py --engine "$e" --cli "$MP_CLI" --dataset-dir "$LS_CLEAN" --n 24 --out "$out"
  done
  "$PY" speed_bench.py --engine cohere --fa "$FA_CLI" --cohere-model "$COHERE_MODEL" --n 12 --out "$out"
}

transcribe() {
  echo "== regenerate English hypotheses via macparakeet-cli (full sets) =="
  for sub in test-clean test-other; do
    for e in parakeet-v2 parakeet-v3 parakeet-unified nemotron-en nemotron-multi whisper; do
      "$PY" run_macparakeet.py --cli "$MP_CLI" \
        --dataset-dir "$HOME/asr-bench/LibriSpeech/$sub" --dataset-name "$sub" \
        --engine "$e" --records "results/full/${e}__${sub}.jsonl"
    done
  done
  echo "Cohere via FluidAudio: fluidaudiocli cohere-benchmark --dataset librispeech \\"
  echo "  --subset test-clean --model-dir \$COHERE_MODEL --output cohere.json"
  echo "then: python3 fa_json_to_jsonl.py cohere.json --engine cohere --dataset test-clean --out ..."
}

case "${1:-verify}" in
  verify) verify ;;
  speed) speed ;;
  transcribe) transcribe ;;
  *) echo "usage: $0 {verify|speed|transcribe}"; exit 2 ;;
esac
