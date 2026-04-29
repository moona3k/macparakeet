#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMOKE_DIR="${TMPDIR:-/tmp}/macparakeet-whisper-language-smoke"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_voice() {
  local voice="$1"
  if ! say -v '?' | grep -q "^${voice}[[:space:]]"; then
    echo "Missing required macOS voice: ${voice}" >&2
    exit 1
  fi
}

make_clip() {
  local language="$1"
  local voice="$2"
  local text="$3"
  say -v "$voice" -o "${SMOKE_DIR}/${language}.aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 "${SMOKE_DIR}/${language}.aiff" "${SMOKE_DIR}/${language}.wav"
}

run_clip() {
  local language="$1"
  local output="${SMOKE_DIR}/${language}.json"
  local log="${SMOKE_DIR}/${language}.log"

  MACPARAKEET_TELEMETRY=0 swift run --package-path "$ROOT_DIR" macparakeet-cli \
    transcribe "${SMOKE_DIR}/${language}.wav" \
    --engine whisper \
    --language "$language" \
    --format json \
    --database "${SMOKE_DIR}/smoke.db" \
    --no-diarize \
    >"$output" 2>"$log"

  python3 - "$output" "$language" <<'PY'
import json
import sys

path, expected_language = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    raw = f.read()
start = raw.find("{")
end = raw.rfind("}")
if start == -1 or end == -1 or end < start:
    raise SystemExit(f"{expected_language}: no JSON object in CLI output")

payload = json.loads(raw[start:end + 1])
language = payload.get("language")
transcript = (payload.get("rawTranscript") or "").strip()
if language != expected_language:
    raise SystemExit(f"{expected_language}: expected language {expected_language!r}, got {language!r}")
if not transcript:
    raise SystemExit(f"{expected_language}: empty transcript")

print(f"{expected_language}: {transcript}")
PY
}

require_command say
require_command afconvert
require_command swift
require_command python3
require_voice Samantha
require_voice Kyoko
require_voice Yuna

rm -rf "$SMOKE_DIR"
mkdir -p "$SMOKE_DIR"

make_clip en Samantha "This is an English Whisper language smoke test."
make_clip ja Kyoko "これは日本語のテストです。"
make_clip ko Yuna "이것은 한국어 테스트입니다."

run_clip en
run_clip ja
run_clip ko

echo "Whisper language smoke clips and logs: ${SMOKE_DIR}"
