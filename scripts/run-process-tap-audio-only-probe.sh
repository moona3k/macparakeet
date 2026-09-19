#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 OUTPUT_DIRECTORY" >&2
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

swiftc \
  -parse-as-library \
  -O \
  -framework AudioToolbox \
  -framework CoreAudio \
  -framework Foundation \
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
} >"$output_dir/environment.txt"

set +e
"$binary" \
  --output "$result" \
  --tone "$tone" \
  --cycles "$cycles" \
  --tone-duration-seconds "$tone_duration_seconds" \
  >"$output_dir/stdout.txt" 2>"$output_dir/stderr.txt" &
probe_pid=$!

deadline=$((SECONDS + deadline_seconds))
while kill -0 "$probe_pid" 2>/dev/null; do
  if (( SECONDS >= deadline )); then
    kill -TERM "$probe_pid" 2>/dev/null || true
    wait "$probe_pid" 2>/dev/null
    echo "process-tap probe exceeded ${deadline_seconds}-second deadline" >"$output_dir/deadline.txt"
    exit 124
  fi
  sleep 0.1
done
wait "$probe_pid"
probe_status=$?
set -e

test -s "$result"
jq -e '
  .schemaVersion == 2 and
  .microphoneRequested == false and
  .screenPixelsRequested == false and
  (if .status == "PASS" then
    .permissionOutcome == "process_tap_created" and
    .completedCycles == .requestedCycles and
    (.cycles | length) == .requestedCycles and
    .capturedFrames > 0 and
    .minimumCycleRMS >= 0.005 and
    .minimumCycleTargetAmplitude >= 0.005 and
    ([.cycles[] | select(
      .capturedFrames <= 0 or
      .rms < 0.005 or
      .targetAmplitude < 0.005
    )] | length) == 0
  else true end)
' "$result" >/dev/null

exit "$probe_status"
