#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_PATH="${1:-${APP_PATH:-$ROOT_DIR/dist/MacParakeet.app}}"
REQUIRE_MEETING_ECHO_ASSETS="${REQUIRE_MEETING_ECHO_ASSETS:-0}"
VERIFY_CODE_SIGNATURES="${VERIFY_CODE_SIGNATURES:-0}"

LIB_PATH="$APP_PATH/Contents/Frameworks/liblocalvqe.dylib"
MODEL_PATH="$APP_PATH/Contents/Resources/MeetingEchoSuppression/localvqe-v1.2-1.3M-f32.gguf"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Missing app bundle: $APP_PATH" >&2
  exit 1
fi

lib_present=0
model_present=0
[[ -f "$LIB_PATH" ]] && lib_present=1
[[ -f "$MODEL_PATH" ]] && model_present=1

if [[ "$lib_present" == "0" && "$model_present" == "0" ]]; then
  if [[ "$REQUIRE_MEETING_ECHO_ASSETS" == "1" ]]; then
    echo "Error: meeting echo assets are required but not bundled." >&2
    exit 1
  fi
  echo "Meeting echo assets not bundled; runtime will use passthrough."
  exit 0
fi

if [[ "$lib_present" != "$model_present" ]]; then
  echo "Error: meeting echo assets must be bundled together." >&2
  echo "  Library: $LIB_PATH ($lib_present)" >&2
  echo "  Model:   $MODEL_PATH ($model_present)" >&2
  exit 1
fi

if [[ ! -x "$LIB_PATH" ]]; then
  echo "Error: meeting echo runtime is not executable: $LIB_PATH" >&2
  exit 1
fi

if [[ -n "${MACPARAKEET_MEETING_ECHO_MODEL_SHA256:-}" ]]; then
  actual_sha="$(shasum -a 256 "$MODEL_PATH" | awk '{print $1}')"
  if [[ "$actual_sha" != "$MACPARAKEET_MEETING_ECHO_MODEL_SHA256" ]]; then
    echo "Error: bundled meeting echo model SHA256 mismatch." >&2
    echo "  Expected: $MACPARAKEET_MEETING_ECHO_MODEL_SHA256" >&2
    echo "  Actual:   $actual_sha" >&2
    exit 1
  fi
  echo "Meeting echo model SHA256 verified: $actual_sha"
fi

if command -v otool >/dev/null 2>&1; then
  unresolved_deps="$(
    otool -L "$LIB_PATH" |
      tail -n +2 |
      awk '{print $1}' |
      grep -Ev '^@rpath/|^@loader_path/|^/System/Library/|^/usr/lib/|^\(' || true
  )"
  if [[ -n "$unresolved_deps" ]]; then
    echo "Warning: meeting echo runtime has non-system dylib references; ensure they are bundled and use @rpath/@loader_path:" >&2
    echo "$unresolved_deps" >&2
  fi
fi

if [[ "$VERIFY_CODE_SIGNATURES" == "1" ]]; then
  codesign --verify --strict --verbose=2 "$LIB_PATH"
fi

echo "Meeting echo assets verified."
