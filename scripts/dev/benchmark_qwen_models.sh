#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_DEFAULT="$ROOT_DIR/.build/arm64-apple-macosx/release/macparakeet-cli"
BIN="${BIN:-$BIN_DEFAULT}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/output/benchmarks}"
REPS="${REPS:-5}"
STAMP="${STAMP:-$(date +%Y%m%d-%H%M%S)}"

if [[ ! -x "$BIN" ]]; then
  echo "error: binary not found or not executable: $BIN" >&2
  echo "hint: swift build -c release --product macparakeet-cli" >&2
  exit 1
fi

if ! [[ "$REPS" =~ ^[0-9]+$ ]] || [[ "$REPS" -lt 1 ]]; then
  echo "error: REPS must be a positive integer (got: $REPS)" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

RESULTS_TSV="$OUT_DIR/qwen-model-benchmark-$STAMP.tsv"
SUMMARY_TSV="$OUT_DIR/qwen-model-benchmark-$STAMP-summary.tsv"

SHORT_TEXT="hey team quick update i shipped the fix for the menu bar crash this morning and i still need to add the regression test and post release notes can you review after lunch"
LONG_TEXT="yesterday we wrapped the first pass of the onboarding rewrite and the core flow works, but the copy still feels uneven and the handoff between setup screens is abrupt. several users said they understood the value only after the third screen, which means we are front loading details instead of outcomes. i want this rewritten in a clearer, calmer tone that still sounds like us. keep the meaning, but tighten the language, remove repetition, and keep specific commitments. we will keep the launch date for march, but only if we close three risks this week: analytics parity, keyboard shortcut conflicts, and one accessibility bug in the dictation overlay. engineering owns analytics parity and shortcut conflict checks. design owns content polish and visual hierarchy updates. i own final review and launch go no go decision. if any risk slips, we cut non critical polish and preserve reliability first."

TRANSCRIPT_FILE="$OUT_DIR/transcript-sample-$STAMP.txt"
cat > "$TRANSCRIPT_FILE" <<'TXT'
[00:00] Maya: Thanks everyone. Quick planning sync for the transcription app release.
[00:15] Ethan: Current build is stable on M-series laptops, but we still see occasional UI lag when users trigger command mode repeatedly.
[00:33] Priya: For scope, we agreed to ship with three AI refinement presets only: formal, email, and code. We are deferring custom presets.
[00:58] Maya: Right. Decision one: keep preset list fixed for this release. Owner Priya to update docs by Tuesday.
[01:19] Ethan: Decision two: command mode stays text-only in v1. No rich-text formatting transforms.
[01:33] Maya: Owner Ethan for that implementation and tests by Wednesday.
[01:50] Noah: Analytics status: event schema is ready, but dashboard filters are incomplete.
[02:05] Maya: Decision three: launch requires analytics dashboard parity with baseline metrics. Owner Noah, target Thursday end of day.
[02:28] Priya: Customer interview notes also show confusion around the phrase "auto-polish." We should rename that label.
[02:46] Maya: Good catch. Not a release blocker, but we should update copy before final RC.
[03:04] Ethan: Risk list recap: command mode latency spikes, dashboard parity gap, and one accessibility issue with voiceover focus in settings.
[03:23] Maya: Accessibility bug is a blocker. Owner Maya with support from Ethan. Patch by Wednesday morning.
[03:42] Noah: If one blocker slips, do we move date?
[03:50] Maya: Yes, reliability beats schedule. We slip if blockers are unresolved.
[04:02] Priya: Action recap: Priya docs Tuesday, Ethan command-mode tests Wednesday, Noah analytics parity Thursday, Maya accessibility patch Wednesday.
TXT

echo -e "model\tscenario\trun_index\tphase\tcli_duration_s\treal_s\tuser_s\tsys_s\tmax_rss_kb\tpeak_mem_bytes\texit_code\toutput_file\ttime_file" > "$RESULTS_TSV"

run_case() {
  local model="$1"
  local scenario="$2"
  local run_index="$3"
  shift 3

  local phase="warm"
  if [[ "$run_index" -eq 1 ]]; then
    phase="cold"
  fi

  local safe_model="${model//\//_}"
  local out_file="$OUT_DIR/${STAMP}-${safe_model}-${scenario}-${run_index}.out.txt"
  local time_file="$OUT_DIR/${STAMP}-${safe_model}-${scenario}-${run_index}.time.txt"

  set +e
  /usr/bin/time -lp "$@" >"$out_file" 2>"$time_file"
  local ec=$?
  set -e

  local cli_duration
  cli_duration=$( (rg -o "duration=[0-9]+(\\.[0-9]+)?s" "$out_file" || true) | head -n1 | sed 's/duration=//;s/s//')
  local real_s
  real_s=$( (rg '^real ' "$time_file" || true) | awk '{print $2}' | head -n1)
  local user_s
  user_s=$( (rg '^user ' "$time_file" || true) | awk '{print $2}' | head -n1)
  local sys_s
  sys_s=$( (rg '^sys ' "$time_file" || true) | awk '{print $2}' | head -n1)
  local max_rss_kb
  max_rss_kb=$( (rg 'maximum resident set size' "$time_file" || true) | awk '{print $1}' | head -n1)
  local peak_mem_bytes
  peak_mem_bytes=$( (rg 'peak memory footprint' "$time_file" || true) | awk '{print $1}' | head -n1)

  [[ -n "$cli_duration" ]] || cli_duration="NA"
  [[ -n "$real_s" ]] || real_s="NA"
  [[ -n "$user_s" ]] || user_s="NA"
  [[ -n "$sys_s" ]] || sys_s="NA"
  [[ -n "$max_rss_kb" ]] || max_rss_kb="NA"
  [[ -n "$peak_mem_bytes" ]] || peak_mem_bytes="NA"

  echo -e "$model\t$scenario\t$run_index\t$phase\t$cli_duration\t$real_s\t$user_s\t$sys_s\t$max_rss_kb\t$peak_mem_bytes\t$ec\t$out_file\t$time_file" >> "$RESULTS_TSV"
}

run_suite_for_model() {
  local model="$1"
  for run_index in $(seq 1 "$REPS"); do
    run_case "$model" "refine-short" "$run_index" \
      "$BIN" llm refine formal "$SHORT_TEXT" \
      --model "$model" --stats --temperature 0.2 --max-tokens 180

    run_case "$model" "refine-long" "$run_index" \
      "$BIN" llm refine formal "$LONG_TEXT" \
      --model "$model" --stats --temperature 0.2 --max-tokens 280

    run_case "$model" "command" "$run_index" \
      "$BIN" llm command "Rewrite this as release notes with concise bullet points and explicit owners." "$LONG_TEXT" \
      --model "$model" --stats --temperature 0.2 --max-tokens 260

    run_case "$model" "transcript-qa" "$run_index" \
      "$BIN" llm chat "What are the three release decisions, their owners, and due dates?" \
      --transcript-file "$TRANSCRIPT_FILE" \
      --model "$model" --stats --temperature 0.2 --max-tokens 240
  done
}

run_suite_for_model "mlx-community/Qwen3-4B-4bit"
run_suite_for_model "mlx-community/Qwen3-8B-4bit"

awk -F '\t' '
  NR == 1 { next }
  $11 != 0 { next }
  {
    key = $1 FS $2 FS $4
    n[key]++
    sum_cli[key] += $5
    sum_cli_sq[key] += ($5 * $5)
    sum_real[key] += $6
    sum_real_sq[key] += ($6 * $6)
    sum_rss[key] += $9
    sum_peak[key] += $10
    if (!(key in min_cli) || $5 < min_cli[key]) min_cli[key] = $5
    if (!(key in max_cli) || $5 > max_cli[key]) max_cli[key] = $5
    if (!(key in min_real) || $6 < min_real[key]) min_real[key] = $6
    if (!(key in max_real) || $6 > max_real[key]) max_real[key] = $6
    if (!(key in min_peak) || $10 < min_peak[key]) min_peak[key] = $10
    if (!(key in max_peak) || $10 > max_peak[key]) max_peak[key] = $10
    if (!(key in min_rss) || $9 < min_rss[key]) min_rss[key] = $9
    if (!(key in max_rss) || $9 > max_rss[key]) max_rss[key] = $9
  }
END {
  print "model\tscenario\tphase\tn\tavg_cli_s\tstd_cli_s\tmin_cli_s\tmax_cli_s\tavg_real_s\tstd_real_s\tmin_real_s\tmax_real_s\tavg_rss_gb\tavg_peak_mem_gb\tmin_peak_mem_gb\tmax_peak_mem_gb"
  for (k in n) {
    avg_cli = sum_cli[k] / n[k]
    var_cli = (sum_cli_sq[k] / n[k]) - (avg_cli * avg_cli)
    if (var_cli < 0) var_cli = 0
    std_cli = sqrt(var_cli)
    avg_real = sum_real[k] / n[k]
    var_real = (sum_real_sq[k] / n[k]) - (avg_real * avg_real)
    if (var_real < 0) var_real = 0
    std_real = sqrt(var_real)
    avg_rss_gb = (sum_rss[k] / n[k]) / 1024 / 1024 / 1024
    avg_peak_gb = (sum_peak[k] / n[k]) / 1024 / 1024 / 1024
    min_peak_gb = min_peak[k] / 1024 / 1024 / 1024
    max_peak_gb = max_peak[k] / 1024 / 1024 / 1024
    split(k, p, FS)
    printf "%s\t%s\t%s\t%d\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.2f\t%.2f\t%.2f\t%.2f\n",
      p[1], p[2], p[3], n[k], avg_cli, std_cli, min_cli[k], max_cli[k], avg_real, std_real, min_real[k], max_real[k], avg_rss_gb, avg_peak_gb, min_peak_gb, max_peak_gb
  }
}' "$RESULTS_TSV" | sort > "$SUMMARY_TSV"

echo "RESULTS_TSV=$RESULTS_TSV"
echo "SUMMARY_TSV=$SUMMARY_TSV"
echo "TRANSCRIPT_FILE=$TRANSCRIPT_FILE"
