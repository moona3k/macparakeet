#!/usr/bin/env bash
set -euo pipefail
case "${1:-streaming}" in
  baseline|streaming) ;;
  *) printf 'mode must be baseline or streaming\n' >&2; exit 2 ;;
esac
root=$(git rev-parse --show-toplevel)
cd "$root"
base=648d0b6f462f60520fccba402ef556c393791fd2
scratch=$(mktemp -d "${TMPDIR:-/tmp}/macparakeet-cleanup-probe.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
renderer=Sources/MacParakeetCore/Services/MeetingRecording/MeetingCleanedMicRenderer.swift
# Only type names differ, so baseline and candidate coexist in one executable.
git show "$base:$renderer" | sed \
  -e 's/MeetingCleanedMicRenderer/BaselineCleanedMicRenderer/g' \
  -e 's/UncheckedSendableBox/BaselineUncheckedSendableBox/g' > "$scratch/Baseline.swift"
swiftc -O -swift-version 6 -parse-as-library \
  docs/research/2026-10-11-bounded-meeting-cleanup/Harness.swift \
  "$scratch/Baseline.swift" "$renderer" \
  Sources/MacParakeetCore/Services/MeetingRecording/MeetingDecodedAudio.swift \
  Sources/MacParakeetCore/Services/Capture/MicConditioner.swift \
  Sources/MacParakeetCore/Services/Capture/MeetingEchoDelayEstimator.swift \
  Sources/MacParakeetCore/Audio/PCMBufferToSampleBuffer.swift \
  -o "$scratch/probe"
# Mode baseline|streaming; duration seconds; optional no-echo.
/usr/bin/time -l "$scratch/probe" "${1:-streaming}" "${2:-3600}" "${3:-echo}"
