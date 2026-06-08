#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_DEFAULT="$ROOT_DIR/.build/arm64-apple-macosx/release/macparakeet-cli"
BIN="${BIN:-$BIN_DEFAULT}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/output/benchmarks/stt}"
STAMP="${STAMP:-$(date +%Y%m%d-%H%M%S)}"
REPS="${REPS:-1}"
ENGINES="${ENGINES:-parakeet-v3 nemotron whisper}"
PHASE_LABEL="${PHASE_LABEL:-}"

if [[ $# -ne 1 ]]; then
  cat >&2 <<'EOF'
usage: scripts/dev/benchmark_stt_engines.sh CORPUS_TSV

CORPUS_TSV columns:
  sample_id<TAB>path<TAB>language<TAB>sample_type<TAB>reference_path<TAB>notes

language may be "auto". reference_path may be empty or "-".

Environment:
  BIN      release macparakeet-cli path
  OUT_DIR  output directory, default output/benchmarks/stt
  REPS     repetitions per engine/sample, default 1
  ENGINES  space-separated selectors, default "parakeet-v3 nemotron whisper"
  PHASE_LABEL  override phase label, e.g. cold or warm
EOF
  exit 1
fi

CORPUS_TSV="$1"

if [[ ! -x "$BIN" ]]; then
  echo "error: binary not found or not executable: $BIN" >&2
  echo "hint: swift build -c release --product macparakeet-cli" >&2
  exit 1
fi

if [[ ! -f "$CORPUS_TSV" ]]; then
  echo "error: corpus TSV not found: $CORPUS_TSV" >&2
  exit 1
fi

if ! [[ "$REPS" =~ ^[0-9]+$ ]] || [[ "$REPS" -lt 1 ]]; then
  echo "error: REPS must be a positive integer (got: $REPS)" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required for JSON parsing and WER scoring" >&2
  exit 1
fi

mkdir -p "$OUT_DIR/transcripts" "$OUT_DIR/json" "$OUT_DIR/logs"

RESULTS_TSV="$OUT_DIR/stt-engine-benchmark-$STAMP.tsv"
SUMMARY_TSV="$OUT_DIR/stt-engine-benchmark-$STAMP-summary.tsv"
DB_PATH="$OUT_DIR/stt-benchmark-$STAMP.sqlite"

expand_path() {
  local value="$1"
  case "$value" in
    "~"/*) printf '%s/%s\n' "$HOME" "${value#~/}" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

now_seconds() {
  perl -MTime::HiRes=time -e 'printf "%.6f\n", time' 2>/dev/null || \
    python3 -c 'import time; print(f"{time.time():.6f}")'
}

audio_duration_s() {
  local path="$1"
  if command -v ffprobe >/dev/null 2>&1; then
    ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$path" 2>/dev/null | head -n1
    return
  fi
  if command -v afinfo >/dev/null 2>&1; then
    afinfo "$path" 2>/dev/null | awk -F': ' '/estimated duration/ {gsub(/ sec/, "", $2); print $2; exit}'
    return
  fi
  echo "NA"
}

safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

engine_args() {
  local selector="$1"
  local language="$2"
  case "$selector" in
    parakeet|parakeet-v3)
      printf '%s\n' "--engine" "parakeet" "--parakeet-model" "v3"
      ;;
    parakeet-v2)
      printf '%s\n' "--engine" "parakeet" "--parakeet-model" "v2"
      ;;
    nemotron)
      printf '%s\n' "--engine" "nemotron"
      if [[ -n "$language" && "$language" != "auto" ]]; then
        printf '%s\n' "--language" "$language"
      fi
      ;;
    whisper)
      printf '%s\n' "--engine" "whisper"
      if [[ -n "$language" && "$language" != "auto" ]]; then
        printf '%s\n' "--language" "$language"
      fi
      ;;
    *)
      echo "error: unsupported engine selector: $selector" >&2
      exit 1
      ;;
  esac
}

analyze_result() {
  local json_file="$1"
  local transcript_file="$2"
  local reference_path="$3"
  python3 - "$json_file" "$transcript_file" "$reference_path" <<'PY'
import json
import re
import sys
from pathlib import Path

json_path = Path(sys.argv[1])
transcript_path = Path(sys.argv[2])
reference_arg = sys.argv[3]

def empty():
    print("\t".join(["NA"] * 10))

try:
    raw_json = json_path.read_text()
    start = raw_json.find("{")
    end = raw_json.rfind("}")
    if start < 0 or end < start:
        raise ValueError("JSON object not found")
    data = json.loads(raw_json[start:end + 1])
except Exception:
    transcript_path.write_text("")
    empty()
    raise SystemExit(0)

text = (data.get("cleanTranscript") or data.get("rawTranscript") or "").strip()
transcript_path.write_text(text + ("\n" if text else ""))

def tokens(value):
    return re.findall(r"[\w']+", value.lower(), flags=re.UNICODE)

def wer(ref, hyp):
    r = tokens(ref)
    h = tokens(hyp)
    if not r:
        return None
    prev = list(range(len(h) + 1))
    for i, rw in enumerate(r, start=1):
        curr = [i]
        for j, hw in enumerate(h, start=1):
            cost = 0 if rw == hw else 1
            curr.append(min(curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost))
        prev = curr
    return prev[-1] / len(r)

def boundary_match(ref_words, hyp_words, from_end=False):
    if not ref_words or not hyp_words:
        return "NA"
    limit = min(5, len(ref_words), len(hyp_words))
    count = 0
    for idx in range(limit):
        ref_idx = -1 - idx if from_end else idx
        hyp_idx = -1 - idx if from_end else idx
        if ref_words[ref_idx] == hyp_words[hyp_idx]:
            count += 1
        else:
            break
    return str(count)

word_count = len(tokens(text))
punct_count = len(re.findall(r"[,.?!;:]", text))
punct_per_100 = None if word_count == 0 else punct_count * 100.0 / word_count

reference_text = None
if reference_arg and reference_arg != "-":
    ref_path = Path(reference_arg)
    if ref_path.exists():
        reference_text = ref_path.read_text()

wer_value = wer(reference_text, text) if reference_text is not None else None
ref_words = tokens(reference_text or "")
hyp_words = tokens(text)

fields = [
    str((data.get("durationMs") or "NA")),
    data.get("engine") or "NA",
    data.get("engineVariant") or "NA",
    data.get("language") or "NA",
    str(word_count),
    str(len(text)),
    "NA" if wer_value is None else f"{wer_value:.4f}",
    "NA" if punct_per_100 is None else f"{punct_per_100:.2f}",
    boundary_match(ref_words, hyp_words, from_end=False),
    boundary_match(ref_words, hyp_words, from_end=True),
]
print("\t".join(fields))
PY
}

echo -e "engine_selector\trun_index\tphase\tsample_id\tsample_type\tlanguage_hint\taudio_duration_s\ttranscript_duration_ms\tjson_engine\tjson_engine_variant\tjson_language\ttranscript_words\ttranscript_chars\twer\tpunctuation_per_100_words\tprefix_ref_words_matched\tsuffix_ref_words_matched\tfinal_wall_s\trealtime_factor\tfirst_progress_s\tfirst_partial_s\tmax_rss_bytes\tpeak_memory_bytes\texit_code\ttranscript_file\tjson_file\tstderr_file\terror" > "$RESULTS_TSV"

run_case() {
  local engine="$1"
  local run_index="$2"
  local sample_id="$3"
  local sample_path="$4"
  local language="$5"
  local sample_type="$6"
  local reference_path="$7"

  local phase="${PHASE_LABEL:-warm}"
  if [[ -z "$PHASE_LABEL" && "$run_index" -eq 1 ]]; then
    phase="cold"
  fi

  local safe_engine safe_sample
  safe_engine="$(safe_name "$engine")"
  safe_sample="$(safe_name "$sample_id")"
  local json_file="$OUT_DIR/json/${STAMP}-${safe_engine}-${safe_sample}-${run_index}.json"
  local stderr_file="$OUT_DIR/logs/${STAMP}-${safe_engine}-${safe_sample}-${run_index}.stderr.tsv"
  local transcript_file="$OUT_DIR/transcripts/${STAMP}-${safe_engine}-${safe_sample}-${run_index}.txt"
  local duration
  duration="$(audio_duration_s "$sample_path")"

  local args=()
  while IFS= read -r arg; do
    args+=("$arg")
  done < <(engine_args "$engine" "$language")

  local start_s
  start_s="$(now_seconds)"
  set +e
  MACPARAKEET_TELEMETRY=0 DO_NOT_TRACK=1 \
    /usr/bin/time -lp "$BIN" transcribe "$sample_path" \
      --format json \
      --no-history \
      --speaker-detection off \
      --database "$DB_PATH" \
      "${args[@]}" \
      >"$json_file" \
      2> >(while IFS= read -r line || [[ -n "$line" ]]; do printf '%s\t%s\n' "$(now_seconds)" "$line"; done > "$stderr_file")
  local ec=$?
  set -e

  for _ in $(seq 1 100); do
    if grep -q "peak memory footprint" "$stderr_file"; then
      break
    fi
    sleep 0.05
  done

  local final_wall_s max_rss_bytes peak_memory_bytes first_progress_s
  final_wall_s="$(awk -F '\t' '$2 ~ /^real / {if (match($2, /[0-9.]+/)) print substr($2, RSTART, RLENGTH); exit}' "$stderr_file")"
  max_rss_bytes="$(awk -F '\t' '$2 ~ /maximum resident set size/ {if (match($2, /[0-9.]+/)) print substr($2, RSTART, RLENGTH); exit}' "$stderr_file")"
  peak_memory_bytes="$(awk -F '\t' '$2 ~ /peak memory footprint/ {if (match($2, /[0-9.]+/)) print substr($2, RSTART, RLENGTH); exit}' "$stderr_file")"
  first_progress_s="$(awk -v start="$start_s" -F '\t' '$2 ~ /^(Converting audio|Downloading audio|Transcribing\.\.\.|Identifying speakers|Finalizing)/ {printf "%.3f", $1 - start; exit}' "$stderr_file")"

  [[ -n "$final_wall_s" ]] || final_wall_s="NA"
  [[ -n "$max_rss_bytes" ]] || max_rss_bytes="NA"
  [[ -n "$peak_memory_bytes" ]] || peak_memory_bytes="NA"
  [[ -n "$first_progress_s" ]] || first_progress_s="NA"

  local transcript_duration_ms json_engine json_engine_variant json_language transcript_words transcript_chars wer punct prefix suffix
  IFS=$'\t' read -r transcript_duration_ms json_engine json_engine_variant json_language transcript_words transcript_chars wer punct prefix suffix < <(
    analyze_result "$json_file" "$transcript_file" "$reference_path"
  )

  local realtime_factor="NA"
  if [[ "$duration" != "NA" && "$final_wall_s" != "NA" ]]; then
    realtime_factor="$(python3 - "$final_wall_s" "$duration" <<'PY'
import sys
wall = float(sys.argv[1])
duration = float(sys.argv[2])
print("NA" if duration <= 0 else f"{wall / duration:.4f}")
PY
)"
  fi

  local error="none"
  if [[ "$ec" -ne 0 ]]; then
    error="$(awk -F '\t' 'NF >= 2 {line=$2} END {print line}' "$stderr_file" | tr '\t' ' ' | sed 's/[[:space:]]\+/ /g')"
    [[ -n "$error" ]] || error="command_failed"
  fi

  echo -e "$engine\t$run_index\t$phase\t$sample_id\t$sample_type\t$language\t$duration\t$transcript_duration_ms\t$json_engine\t$json_engine_variant\t$json_language\t$transcript_words\t$transcript_chars\t$wer\t$punct\t$prefix\t$suffix\t$final_wall_s\t$realtime_factor\t$first_progress_s\tNA\t$max_rss_bytes\t$peak_memory_bytes\t$ec\t$transcript_file\t$json_file\t$stderr_file\t$error" >> "$RESULTS_TSV"
}

while IFS=$'\t' read -r sample_id raw_path language sample_type reference_path notes; do
  [[ -n "${sample_id:-}" ]] || continue
  [[ "$sample_id" == \#* ]] && continue
  [[ "$sample_id" == "sample_id" ]] && continue

  sample_path="$(expand_path "$raw_path")"
  reference_path="$(expand_path "${reference_path:-}")"
  [[ -n "${language:-}" ]] || language="auto"
  [[ -n "${sample_type:-}" ]] || sample_type="unknown"
  [[ -n "${reference_path:-}" ]] || reference_path="-"

  if [[ ! -f "$sample_path" ]]; then
    echo "error: sample file not found for $sample_id: $sample_path" >&2
    exit 1
  fi

  for engine in $ENGINES; do
    for run_index in $(seq 1 "$REPS"); do
      echo "benchmark: engine=$engine sample=$sample_id run=$run_index/$REPS" >&2
      run_case "$engine" "$run_index" "$sample_id" "$sample_path" "$language" "$sample_type" "$reference_path"
    done
  done
done < "$CORPUS_TSV"

python3 - "$RESULTS_TSV" > "$SUMMARY_TSV" <<'PY'
import csv
import statistics
import sys
from collections import defaultdict

path = sys.argv[1]
rows = []
with open(path, newline="") as handle:
    reader = csv.DictReader(handle, delimiter="\t")
    rows = list(reader)

groups = defaultdict(list)
for row in rows:
    if row["exit_code"] == "0":
        groups[(row["engine_selector"], row["sample_type"], row["phase"])].append(row)

fields = [
    "engine_selector", "sample_type", "phase", "n",
    "avg_final_wall_s", "avg_realtime_factor",
    "avg_first_progress_s", "avg_peak_memory_gb",
    "avg_wer", "avg_punctuation_per_100_words",
]
writer = csv.DictWriter(sys.stdout, fieldnames=fields, delimiter="\t")
writer.writeheader()

def numbers(values):
    result = []
    for value in values:
        if value in ("", "NA", None):
            continue
        try:
            result.append(float(value))
        except ValueError:
            pass
    return result

for key in sorted(groups):
    rows_for_key = groups[key]
    wall = numbers(row["final_wall_s"] for row in rows_for_key)
    rtf = numbers(row["realtime_factor"] for row in rows_for_key)
    first_progress = numbers(row["first_progress_s"] for row in rows_for_key)
    peak = numbers(row["peak_memory_bytes"] for row in rows_for_key)
    wer = numbers(row["wer"] for row in rows_for_key)
    punct = numbers(row["punctuation_per_100_words"] for row in rows_for_key)

    def avg(values, scale=1.0):
        return "NA" if not values else f"{statistics.fmean(values) / scale:.4f}"

    writer.writerow({
        "engine_selector": key[0],
        "sample_type": key[1],
        "phase": key[2],
        "n": len(rows_for_key),
        "avg_final_wall_s": avg(wall),
        "avg_realtime_factor": avg(rtf),
        "avg_first_progress_s": avg(first_progress),
        "avg_peak_memory_gb": avg(peak, 1024 ** 3),
        "avg_wer": avg(wer),
        "avg_punctuation_per_100_words": avg(punct),
    })
PY

echo "RESULTS_TSV=$RESULTS_TSV"
echo "SUMMARY_TSV=$SUMMARY_TSV"
echo "DB_PATH=$DB_PATH"
