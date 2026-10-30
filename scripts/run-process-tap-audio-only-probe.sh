#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 && ( $# -ne 3 || "$2" != --observe-seconds ) ]]; then
  echo "usage: $0 OUTPUT_DIRECTORY [--observe-seconds N]" >&2
  exit 64
fi

observe_seconds=${3:-}
if [[ $# -eq 3 ]] && ! /usr/bin/awk -v n="$observe_seconds" \
  'BEGIN { exit !(n ~ /^[0-9]+([.][0-9]+)?$/ && n >= 1 && n <= 300) }'; then
  echo "observation duration must be between 1 and 300 seconds" >&2
  exit 64
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_dir=$1
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)

binary="$output_dir/process-tap-audio-only-probe"
result="$output_dir/result.json"
tone="$output_dir/generated-997hz.wav"
cycles=${MACPARAKEET_PROCESS_TAP_PROBE_CYCLES:-1}
tone_duration_seconds=${MACPARAKEET_PROCESS_TAP_PROBE_TONE_SECONDS:-2}
deadline_seconds=${MACPARAKEET_PROCESS_TAP_PROBE_DEADLINE_SECONDS:-20}
if [[ -n "$observe_seconds" && -z "${MACPARAKEET_PROCESS_TAP_PROBE_DEADLINE_SECONDS:-}" ]]; then
  deadline_seconds=$(/usr/bin/awk -v n="$observe_seconds" 'BEGIN { print int(n) + 30 }')
fi
info_plist="$output_dir/Info.plist"

managed_outputs=(
  "$binary"
  "$result"
  "$tone"
  "$output_dir/environment.txt"
  "$output_dir/stdout.txt"
  "$output_dir/stderr.txt"
  "$output_dir/deadline.txt"
  "$output_dir/result-after-deadline.json"
  "$output_dir/result-after-signal.json"
  "$info_plist"
)
for managed_output in "${managed_outputs[@]}"; do
  if [[ -e "$managed_output" || -L "$managed_output" ]]; then
    echo "output directory already contains probe artifact: $managed_output" >&2
    echo "use a fresh output directory so a failed run cannot retain prior PASS data" >&2
    exit 73
  fi
done

cat >"$info_plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.pocketstation.macparakeet-process-tap-probe</string>
<key>CFBundleName</key><string>MacParakeet Audio Probe</string>
<key>NSAudioCaptureUsageDescription</key><string>Measure system audio locally to investigate missing call audio. No audio is saved or uploaded.</string>
</dict></plist>
PLIST

swiftc \
  -parse-as-library \
  -O \
  -framework AudioToolbox \
  -framework CoreAudio \
  -framework Foundation \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$info_plist" \
  "$repo_root/scripts/process-tap-audio-only-probe.swift" \
  -o "$binary"

codesign --force --sign - \
  --identifier io.pocketstation.macparakeet-process-tap-probe \
  "$binary"

{
  sw_vers
  uname -m
  swift --version
  codesign -dv --verbose=4 "$binary" 2>&1
} >"$output_dir/environment.txt" 2>&1

probe_pid=""

probe_children() {
  /usr/bin/pgrep -P "$probe_pid" 2>/dev/null || true
}

terminate_processes() {
  local process_pid
  while IFS= read -r process_pid; do
    [[ -n "$process_pid" ]] && kill -TERM "$process_pid" 2>/dev/null || true
  done
}

wait_for_probe_exit() {
  local attempts=$1
  local attempt=0
  while kill -0 "$probe_pid" 2>/dev/null && (( attempt < attempts )); do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  ! kill -0 "$probe_pid" 2>/dev/null
}

stop_probe_tree() {
  [[ -n "$probe_pid" ]] || return 0

  # Let the probe finish checked teardown after its player stops. The probe
  # creates its own process group before launching children, so even an
  # orphaned player remains addressable without matching unrelated playback.
  terminate_processes < <(probe_children)
  if ! wait_for_probe_exit 20; then
    kill -TERM "$probe_pid" 2>/dev/null || true
  fi
  kill -TERM -- "-$probe_pid" 2>/dev/null || true
  for _ in {1..20}; do
    kill -0 -- "-$probe_pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL -- "-$probe_pid" 2>/dev/null || true
  if kill -0 "$probe_pid" 2>/dev/null; then
    kill -KILL "$probe_pid" 2>/dev/null || true
  fi
  wait "$probe_pid" 2>/dev/null || true
}

write_runner_failure_result() {
  local failure_type=$1
  local raw_result=$2
  local message=$3
  local runner_exit_code=$4
  local raw_result_preserved=NO

  if [[ -e "$result" ]]; then
    mv "$result" "$raw_result"
    raw_result_preserved=YES
  fi

  /usr/bin/plutil -create xml1 "$result"
  /usr/bin/plutil -insert schemaVersion -integer 2 "$result"
  /usr/bin/plutil -insert status -string FAIL "$result"
  /usr/bin/plutil -insert failureType -string "$failure_type" "$result"
  /usr/bin/plutil -insert error -string "$message" "$result"
  /usr/bin/plutil -insert runnerExitCode -integer "$runner_exit_code" "$result"
  if [[ -n "$observe_seconds" ]]; then
    /usr/bin/plutil -replace schemaVersion -integer 3 "$result"
    /usr/bin/plutil -insert mode -string external_audio_observation "$result"
    /usr/bin/plutil -insert requestedSeconds -float "$observe_seconds" "$result"
    /usr/bin/plutil -insert generatedPlayback -bool NO "$result"
  else
    /usr/bin/plutil -insert requestedCycles -integer "$cycles" "$result"
  fi
  /usr/bin/plutil -insert deadlineSeconds -integer "$deadline_seconds" "$result"
  /usr/bin/plutil -insert microphoneRequested -bool NO "$result"
  /usr/bin/plutil -insert screenPixelsRequested -bool NO "$result"
  /usr/bin/plutil -insert rawResultPreserved -bool "$raw_result_preserved" "$result"
  /usr/bin/plutil -convert json "$result"
}

handle_signal() {
  local signal_name=$1
  local runner_exit_code=$2
  trap - EXIT INT TERM
  stop_probe_tree
  probe_pid=""
  write_runner_failure_result \
    "cancelled_by_${signal_name}" \
    "$output_dir/result-after-signal.json" \
    "process-tap probe runner received ${signal_name}" \
    "$runner_exit_code"
  exit "$runner_exit_code"
}

trap stop_probe_tree EXIT
trap 'handle_signal SIGINT 130' INT
trap 'handle_signal SIGTERM 143' TERM

probe_arguments=(--output "$result")
if [[ -n "$observe_seconds" ]]; then
  probe_arguments+=(--observe-seconds "$observe_seconds")
else
  probe_arguments+=(--tone "$tone" --cycles "$cycles" --tone-duration-seconds "$tone_duration_seconds")
fi
"$binary" "${probe_arguments[@]}" \
  >"$output_dir/stdout.txt" 2>"$output_dir/stderr.txt" &
probe_pid=$!

deadline=$((SECONDS + deadline_seconds))
readiness_announced=false
while kill -0 "$probe_pid" 2>/dev/null; do
  if [[ -n "$observe_seconds" && "$readiness_announced" == false && -s "$output_dir/stdout.txt" ]]; then
    cat "$output_dir/stdout.txt"
    readiness_announced=true
  fi
  if (( SECONDS >= deadline )); then
    echo "process-tap probe exceeded ${deadline_seconds}-second deadline" >"$output_dir/deadline.txt"
    stop_probe_tree
    probe_pid=""
    write_runner_failure_result \
      deadline_exceeded \
      "$output_dir/result-after-deadline.json" \
      "process-tap probe exceeded ${deadline_seconds}-second deadline" \
      124
    exit 124
  fi
  sleep 0.1
done
if wait "$probe_pid"; then
  probe_status=0
else
  probe_status=$?
fi
stop_probe_tree
probe_pid=""

test -s "$result"
/usr/bin/plutil -convert xml1 -o /dev/null "$result"

result_field() {
  /usr/bin/plutil -extract "$1" raw -o - "$result"
}

test "$(result_field microphoneRequested)" = "false"
test "$(result_field screenPixelsRequested)" = "false"

if [[ -n "$observe_seconds" ]]; then
  test "$probe_status" -eq 0
  test "$(result_field schemaVersion)" = "3"
  test "$(result_field mode)" = "external_audio_observation"
  test "$(result_field status)" = "OBSERVED"
  test "$(result_field generatedPlayback)" = "false"
  test "$(result_field teardownVerified)" = "true"
  test "$(result_field capturedFrames)" -gt 0
  exit 0
fi

test "$(result_field schemaVersion)" = "2"
if [[ "$(result_field status)" == "PASS" ]]; then
  test "$(result_field permissionOutcome)" = "process_tap_created"
  test "$(result_field completedCycles)" = "$(result_field requestedCycles)"
  test "$(result_field completedCycles)" = "$cycles"
  test "$(result_field capturedFrames)" -gt 0
  /usr/bin/awk -v value="$(result_field minimumCycleRMS)" \
    'BEGIN { exit !(value >= 0.005) }'
  /usr/bin/awk -v value="$(result_field minimumCycleTargetAmplitude)" \
    'BEGIN { exit !(value >= 0.005) }'
  for ((cycle_index = 0; cycle_index < cycles; cycle_index += 1)); do
    test "$(result_field "cycles.${cycle_index}.teardownVerified")" = "true"
    test "$(result_field "cycles.${cycle_index}.capturedFrames")" -gt 0
    /usr/bin/awk -v value="$(result_field "cycles.${cycle_index}.rms")" \
      'BEGIN { exit !(value >= 0.005) }'
    /usr/bin/awk -v value="$(result_field "cycles.${cycle_index}.targetAmplitude")" \
      'BEGIN { exit !(value >= 0.005) }'
  done
fi

exit "$probe_status"
