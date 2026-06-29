#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/dev/release_demo_smoke.sh [options]

Runs a local release-demo smoke against a MacParakeet CLI binary:
  1. CLI version probe
  2. non-mutating health --json
  3. synthesized tiny WAV transcription into an isolated SQLite database
  4. markdown export from the persisted transcription

Options:
  --cli PATH           CLI binary to test. Defaults to /Applications/MacParakeet.app/Contents/MacOS/macparakeet-cli,
                       then PATH lookup for macparakeet-cli.
  --allow-swift-run   Use `swift run macparakeet-cli` if no installed CLI is found.
  --output-dir DIR    Evidence directory. Defaults to .codex/release-demo-smoke/<UTC timestamp>.
  -h, --help          Show this help.

Environment:
  MACPARAKEET_CLI     Same as --cli.
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cli_path="${MACPARAKEET_CLI:-}"
allow_swift_run=0
output_dir="$repo_root/.codex/release-demo-smoke/$(date -u +%Y%m%dT%H%M%SZ)"
summary_result=""
failure_context=""
CLI_CMD=()

configure_output_paths() {
  command_log="$output_dir/commands.log"
  summary="$output_dir/summary.md"
  fixture_text="$output_dir/fixture.txt"
  fixture_aiff="$output_dir/fixture.aiff"
  fixture_wav="$output_dir/fixture.wav"
  smoke_db="$output_dir/smoke.sqlite"
  health_json="$output_dir/health.json"
  transcribe_json="$output_dir/transcribe.json"
  export_md="$output_dir/export.md"
}

write_summary() {
  local result="$1"
  local transcription_id="${2:-}"
  local transcript_preview="${3:-}"
  summary_result="$result"

  mkdir -p "$output_dir"
  {
    printf '# MacParakeet Release Demo Smoke\n\n'
    printf '%s\n' "- Result: \`$result\`"
    printf '%s\n' "- CLI: \`${CLI_CMD[*]-<unresolved>}\`"
    printf '%s\n' "- Evidence directory: \`$output_dir\`"
    printf '%s\n' "- Isolated database: \`$smoke_db\`"
    if [[ -n "$failure_context" ]]; then
      printf '%s\n' "- Failure: \`$failure_context\`"
    fi
    if [[ -n "$transcription_id" ]]; then
      printf '%s\n' "- Transcription ID: \`$transcription_id\`"
    fi
    if [[ -n "$transcript_preview" ]]; then
      printf '%s\n' "- Transcript preview: \`$transcript_preview\`"
    fi
    printf '\n## Evidence Files\n\n'
    printf '%s\n' '- `commands.log` - executed commands and exit statuses'
    printf '%s\n' '- `health.json` / `health.stderr` - health readiness probe'
    printf '%s\n' '- `fixture.wav` - generated local audio fixture'
    printf '%s\n' '- `transcribe.json` / `transcribe.stderr` - transcription result'
    printf '%s\n' '- `export.md` / `export.stderr` - markdown export proof'
  } >"$summary"
}

fail_with_summary() {
  local status="$1"
  local message="$2"
  failure_context="$message"
  write_summary "fail"
  echo "$message" >&2
  echo "Evidence kept at: $output_dir" >&2
  exit "$status"
}

configure_output_paths

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cli)
      [[ $# -ge 2 ]] || fail_with_summary 64 "--cli requires a path"
      cli_path="$2"
      shift 2
      ;;
    --allow-swift-run)
      allow_swift_run=1
      shift
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || fail_with_summary 64 "--output-dir requires a path"
      output_dir="$2"
      configure_output_paths
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      fail_with_summary 64 "Unknown option: $1"
      ;;
  esac
done

mkdir -p "$output_dir"

resolve_cli() {
  if [[ -n "$cli_path" ]]; then
    [[ -x "$cli_path" ]] || fail_with_summary 69 "CLI is not executable: $cli_path"
    CLI_CMD=("$cli_path")
    return
  fi

  local app_cli="/Applications/MacParakeet.app/Contents/MacOS/macparakeet-cli"
  if [[ -x "$app_cli" ]]; then
    CLI_CMD=("$app_cli")
    return
  fi

  if command -v macparakeet-cli >/dev/null 2>&1; then
    CLI_CMD=("$(command -v macparakeet-cli)")
    return
  fi

  if [[ "$allow_swift_run" -eq 1 ]]; then
    CLI_CMD=("swift" "run" "--package-path" "$repo_root" "macparakeet-cli" "--")
    return
  fi

  cat >&2 <<'EOF'
No installed macparakeet-cli was found.

Install/open the released MacParakeet app, pass --cli PATH, set MACPARAKEET_CLI,
or rerun with --allow-swift-run for a development-build smoke.
EOF
  failure_context="no installed macparakeet-cli found"
  exit 69
}

quote_command() {
  printf '$'
  printf ' %q' "$@"
  printf '\n'
}

run_capture() {
  local label="$1"
  local stdout_path="$2"
  local stderr_path="$3"
  shift 3

  {
    printf '\n## %s\n' "$label"
    quote_command "$@"
  } >>"$command_log"

  if "$@" >"$stdout_path" 2>"$stderr_path"; then
    printf 'status: 0\n' >>"$command_log"
    return 0
  else
    local status=$?
    printf 'status: %s\n' "$status" >>"$command_log"
    failure_context="$label exited with status $status"
    write_summary "fail"
    echo "Command failed during $label: exit status $status" >&2
    echo "Evidence kept at: $output_dir" >&2
    exit "$status"
  fi
}

write_fail_summary_on_exit() {
  local status=$?
  if [[ "$status" -ne 0 && -z "$summary_result" ]]; then
    if [[ -z "$failure_context" ]]; then
      failure_context="unexpected exit status $status"
    fi
    write_summary "fail"
    echo "Release demo smoke failed with exit status $status." >&2
    echo "Evidence kept at: $output_dir" >&2
    echo "Summary: $summary" >&2
  fi
  return "$status"
}

write_fail_summary_on_err() {
  local status=$?
  local line="${1:-unknown}"
  if [[ "$status" -ne 0 && -z "$summary_result" ]]; then
    failure_context="unexpected error at line $line (status $status)"
    write_summary "fail"
    echo "Release demo smoke failed at line $line with exit status $status." >&2
    echo "Evidence kept at: $output_dir" >&2
    echo "Summary: $summary" >&2
  fi
}

trap 'write_fail_summary_on_err "$LINENO"' ERR
trap write_fail_summary_on_exit EXIT

require_file() {
  local path="$1"
  [[ -s "$path" ]] || {
    failure_context="missing expected non-empty file: $path"
    write_summary "fail"
    echo "Expected non-empty file missing: $path" >&2
    echo "Evidence kept at: $output_dir" >&2
    exit 1
  }
}

validate_json() {
  local path="$1"
  if /usr/bin/plutil -convert json -o /dev/null "$path" >/dev/null 2>&1; then
    return 0
  fi

  failure_context="invalid JSON: $path"
  write_summary "fail"
  echo "Invalid JSON: $path" >&2
  echo "Evidence kept at: $output_dir" >&2
  exit 1
}

: >"$command_log"
resolve_cli

printf 'MacParakeet release demo smoke fixture. This short local audio proves transcription and export.\n' >"$fixture_text"

run_capture "cli-version" "$output_dir/cli-version.txt" "$output_dir/cli-version.stderr" "${CLI_CMD[@]}" --version
run_capture "health-json" "$health_json" "$output_dir/health.stderr" env MACPARAKEET_TELEMETRY=0 "${CLI_CMD[@]}" health --json
validate_json "$health_json"

run_capture "say-fixture" "$output_dir/say.stdout" "$output_dir/say.stderr" /usr/bin/say -o "$fixture_aiff" "$(cat "$fixture_text")"
run_capture "convert-fixture" "$output_dir/afconvert.stdout" "$output_dir/afconvert.stderr" /usr/bin/afconvert -f WAVE -d LEI16@16000 "$fixture_aiff" "$fixture_wav"
require_file "$fixture_wav"

run_capture "transcribe-json" "$transcribe_json" "$output_dir/transcribe.stderr" env MACPARAKEET_TELEMETRY=0 "${CLI_CMD[@]}" transcribe "$fixture_wav" --format json --database "$smoke_db" --speaker-detection off
validate_json "$transcribe_json"

transcription_id="$(/usr/bin/plutil -extract id raw -o - "$transcribe_json")"
transcription_status="$(/usr/bin/plutil -extract status raw -o - "$transcribe_json")"
raw_transcript="$(/usr/bin/plutil -extract rawTranscript raw -o - "$transcribe_json" 2>/dev/null || true)"
clean_transcript="$(/usr/bin/plutil -extract cleanTranscript raw -o - "$transcribe_json" 2>/dev/null || true)"
transcript_preview="${clean_transcript:-$raw_transcript}"
transcript_preview="$(printf '%s' "$transcript_preview" | tr '\n' ' ' | cut -c 1-180)"

if [[ "$transcription_status" != "completed" ]]; then
  failure_context="transcription status was $transcription_status"
  write_summary "fail" "$transcription_id" "$transcript_preview"
  echo "Transcription status was not completed: $transcription_status" >&2
  echo "Evidence kept at: $output_dir" >&2
  exit 1
fi

if [[ -z "${raw_transcript}${clean_transcript}" ]]; then
  failure_context="transcription completed without transcript text"
  write_summary "fail" "$transcription_id"
  echo "Transcription completed but produced no transcript text." >&2
  echo "Evidence kept at: $output_dir" >&2
  exit 1
fi

run_capture "export-markdown" "$output_dir/export.stdout" "$output_dir/export.stderr" env MACPARAKEET_TELEMETRY=0 "${CLI_CMD[@]}" export "$transcription_id" --format markdown --output "$export_md" --database "$smoke_db"
require_file "$export_md"

write_summary "pass" "$transcription_id" "$transcript_preview"

echo "Release demo smoke passed."
echo "Evidence: $output_dir"
echo "Summary:  $summary"
