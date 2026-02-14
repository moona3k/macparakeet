#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_DEFAULT="$ROOT_DIR/.build/arm64-apple-macosx/release/macparakeet-cli"
BIN="${BIN:-$BIN_DEFAULT}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/output/benchmarks}"
STAMP="${STAMP:-$(date +%Y%m%d-%H%M%S)}"

if [[ ! -x "$BIN" ]]; then
  echo "error: binary not found or not executable: $BIN" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

RESULTS_TSV="$OUT_DIR/qwen-quality-eval-$STAMP.tsv"

TRANSCRIPT_FILE="$OUT_DIR/quality-transcript-$STAMP.txt"
cat > "$TRANSCRIPT_FILE" <<'TXT'
[00:00] Maya: Thanks everyone. Quick planning sync for the transcription app release.
[00:58] Maya: Decision one: keep preset list fixed for this release. Owner Priya to update docs by Tuesday.
[01:19] Ethan: Decision two: command mode stays text-only in v1. No rich-text formatting transforms.
[01:33] Maya: Owner Ethan for that implementation and tests by Wednesday.
[02:05] Maya: Decision three: launch requires analytics dashboard parity with baseline metrics. Owner Noah, target Thursday end of day.
[03:50] Maya: Reliability beats schedule. We slip if blockers are unresolved.
TXT

echo -e "model\tcase_id\tpass\tdetail\toutput_file" > "$RESULTS_TSV"

trim_output() {
  local file="$1"
  sed '/^model=/d;/^duration=/d' "$file"
}

run_case() {
  local model="$1"
  local case_id="$2"
  shift 2
  local out_file="$OUT_DIR/${STAMP}-${model//\//_}-${case_id}.out.txt"

  set +e
  "$@" >"$out_file" 2>&1
  local ec=$?
  set -e

  if [[ "$ec" -ne 0 ]]; then
    echo -e "$model\t$case_id\t0\tcommand_failed:$ec\t$out_file" >> "$RESULTS_TSV"
    return
  fi

  local cleaned
  cleaned="$(trim_output "$out_file")"
  local pass="0"
  local detail=""

  case "$case_id" in
    qa_decisions)
      if grep -qi 'Priya' <<<"$cleaned" && grep -qi 'Tuesday' <<<"$cleaned" && \
         grep -qi 'Ethan' <<<"$cleaned" && grep -qi 'Wednesday' <<<"$cleaned" && \
         grep -qi 'Noah' <<<"$cleaned" && grep -qi 'Thursday' <<<"$cleaned"; then
        pass="1"; detail="all_decision_triples_present"
      else
        detail="missing_decision_triples"
      fi
      ;;
    qa_unknown_date)
      local normalized
      normalized="$(echo "$cleaned" | tr '\n' ' ' | sed 's/[[:space:]]\\+/ /g;s/^ //;s/ $//')"
      if [[ "$normalized" == "NOT SPECIFIED" ]]; then
        pass="1"; detail="exact_not_specified"
      else
        detail="possible_hallucination"
      fi
      ;;
    refine_no_chatter)
      if grep -Eqi 'Certainly|Here.s|Let me know|---|As requested|Subject:|Dear Team|Best regards' <<<"$cleaned"; then
        detail="has_wrapper_chatter"
      else
        pass="1"; detail="clean_output_no_wrapper"
      fi
      ;;
    strict_json)
      if command -v jq >/dev/null 2>&1 && jq -e . >/dev/null 2>&1 <<<"$cleaned"; then
        if jq -e 'has("action") and has("owner") and has("deadline")' >/dev/null 2>&1 <<<"$cleaned"; then
          pass="1"; detail="valid_json_required_keys"
        else
          detail="json_missing_required_keys"
        fi
      else
        detail="invalid_json_or_extra_text"
      fi
      ;;
    exact_12_words)
      local wc_count
      wc_count="$(tr '\n' ' ' <<<"$cleaned" | sed 's/[[:space:]]\+/ /g;s/^ //;s/ $//' | wc -w | tr -d ' ')"
      if [[ "$wc_count" == "12" ]]; then
        pass="1"; detail="word_count_12"
      else
        detail="word_count_${wc_count}"
      fi
      ;;
    bullet_owners)
      local bullet_count
      bullet_count="$(grep -Ec '^[[:space:]]*[-*]' <<<"$cleaned" || true)"
      if [[ "$bullet_count" -ge 3 ]] && grep -qi 'Engineering' <<<"$cleaned" && grep -qi 'Design' <<<"$cleaned"; then
        pass="1"; detail="bullets_and_owners_present"
      else
        detail="missing_bullets_or_owners"
      fi
      ;;
    terse_answer)
      if grep -Eq '^.{1,80}$' <<<"$(echo "$cleaned" | tr -d '\n')" && ! grep -Eqi 'because|however|additionally' <<<"$cleaned"; then
        pass="1"; detail="terse_response_ok"
      else
        detail="too_verbose"
      fi
      ;;
    command_preserve_facts)
      if grep -qi 'March' <<<"$cleaned" && grep -qi 'analytics parity' <<<"$cleaned" && grep -qi 'accessibility' <<<"$cleaned"; then
        pass="1"; detail="core_facts_preserved"
      else
        detail="facts_missing"
      fi
      ;;
    *)
      detail="unknown_case"
      ;;
  esac

  echo -e "$model\t$case_id\t$pass\t$detail\t$out_file" >> "$RESULTS_TSV"
}

SHORT_TEXT="hey team quick update i shipped the fix for the menu bar crash this morning and i still need to add the regression test and post release notes can you review after lunch"
LONG_TEXT="yesterday we wrapped the first pass of the onboarding rewrite and the core flow works, but the copy still feels uneven and the handoff between setup screens is abrupt. several users said they understood the value only after the third screen, which means we are front loading details instead of outcomes. we will keep the launch date for march, but only if we close three risks this week: analytics parity, keyboard shortcut conflicts, and one accessibility bug in the dictation overlay. engineering owns analytics parity and shortcut conflict checks. design owns content polish and visual hierarchy updates. i own final review and launch go no go decision."

for model in "mlx-community/Qwen3-4B-4bit" "mlx-community/Qwen3-8B-4bit"; do
  run_case "$model" "qa_decisions" \
    "$BIN" llm chat "List the three release decisions with owner and due date." \
      --transcript-file "$TRANSCRIPT_FILE" --model "$model" --stats --temperature 0.2 --max-tokens 220

  run_case "$model" "qa_unknown_date" \
    "$BIN" llm chat "What calendar launch date is confirmed in the transcript? If no date is present, reply with exactly: NOT SPECIFIED" \
      --transcript-file "$TRANSCRIPT_FILE" --model "$model" --stats --temperature 0.0 --max-tokens 80

  run_case "$model" "refine_no_chatter" \
    "$BIN" llm refine formal "$SHORT_TEXT" --model "$model" --stats --temperature 0.2 --max-tokens 140

  run_case "$model" "strict_json" \
    "$BIN" llm generate "Output ONLY valid JSON with keys action, owner, deadline extracted from: 'Priya updates docs by Tuesday'. No markdown." \
      --model "$model" --stats --temperature 0.0 --max-tokens 80

  run_case "$model" "exact_12_words" \
    "$BIN" llm generate "Rewrite this in exactly 12 words and output only that sentence: reliability beats schedule so we slip if blockers remain" \
      --model "$model" --stats --temperature 0.0 --max-tokens 40

  run_case "$model" "bullet_owners" \
    "$BIN" llm command "Convert to bullet release notes with explicit owners." "$LONG_TEXT" \
      --model "$model" --stats --temperature 0.2 --max-tokens 260

  run_case "$model" "terse_answer" \
    "$BIN" llm chat "In at most 12 words: what is the launch gating principle?" \
      --transcript-file "$TRANSCRIPT_FILE" --model "$model" --stats --temperature 0.0 --max-tokens 24

  run_case "$model" "command_preserve_facts" \
    "$BIN" llm command "Rewrite as an executive update paragraph." "$LONG_TEXT" \
      --model "$model" --stats --temperature 0.2 --max-tokens 220
done

echo "RESULTS_TSV=$RESULTS_TSV"
