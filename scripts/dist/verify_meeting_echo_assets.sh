#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

. "$ROOT_DIR/scripts/dist/meeting_echo_asset_defaults.sh"
. "$ROOT_DIR/scripts/dist/macho_min_version.sh"

APP_PATH="${1:-${APP_PATH:-$ROOT_DIR/dist/MacParakeet.app}}"
REQUIRE_MEETING_ECHO_ASSETS="${REQUIRE_MEETING_ECHO_ASSETS:-0}"
VERIFY_CODE_SIGNATURES="${VERIFY_CODE_SIGNATURES:-0}"
STRICT_MEETING_ECHO_ASSETS="${STRICT_MEETING_ECHO_ASSETS:-$REQUIRE_MEETING_ECHO_ASSETS}"

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
LIB_PATH="$FRAMEWORKS_DIR/liblocalvqe.dylib"
MODEL_DIR="$APP_PATH/Contents/Resources/MeetingEchoSuppression"
MODEL_PATH=""
REQUIRED_SYMBOLS=(
  "_localvqe_new"
  "_localvqe_process_frame_f32"
  "_localvqe_reset"
  "_localvqe_free"
)

missing_tool() {
  local tool="$1"
  local check="$2"
  if [[ "$STRICT_MEETING_ECHO_ASSETS" == "1" ]]; then
    echo "Error: cannot verify ${check}; '${tool}' is not available." >&2
    exit 1
  fi
  echo "Warning: skipped ${check}; '${tool}' is not available." >&2
}

# Rejects any bundled LocalVQE dylib/architecture slice whose Mach-O minimum
# OS version load command exceeds the app's LSMinimumSystemVersion. A dylib
# built for a newer macOS than the app advertises support for can crash at
# launch on older, "supported" systems. This check is a hard failure (not
# gated by STRICT_MEETING_ECHO_ASSETS) whenever otool/lipo are available and
# the expected minimum can be determined; only the availability of otool/lipo
# themselves is gated by strict mode, consistent with the other checks below.
verify_deployment_targets() {
  local override_min="${MACPARAKEET_MEETING_ECHO_MIN_MACOS_VERSION:-}"
  local plist="$APP_PATH/Contents/Info.plist"
  local plist_min=""
  if [[ -f "$plist" ]]; then
    plist_min="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist" 2>/dev/null || true)"
  fi

  if [[ -n "$override_min" ]] && ! is_macos_version "$override_min"; then
    echo "Error: MACPARAKEET_MEETING_ECHO_MIN_MACOS_VERSION must be a valid macOS version." >&2
    exit 1
  fi
  if [[ -e "$plist" ]] && ! is_macos_version "$plist_min"; then
    echo "Error: bundle Info.plist must carry a valid LSMinimumSystemVersion." >&2
    exit 1
  fi

  # Before app assembly the override stands alone; afterward it can only
  # tighten the minimum advertised by the bundle.
  local expected_min="$plist_min"
  if [[ -n "$override_min" ]]; then
    if [[ -z "$expected_min" ]] || version_gt "$expected_min" "$override_min"; then
      expected_min="$override_min"
    fi
  fi
  if [[ -z "$expected_min" ]]; then
    echo "Error: could not determine a valid app LSMinimumSystemVersion to verify bundled LocalVQE dylib deployment targets against." >&2
    echo "  Set MACPARAKEET_MEETING_ECHO_MIN_MACOS_VERSION, or ensure $APP_PATH/Contents/Info.plist carries a valid LSMinimumSystemVersion." >&2
    exit 1
  fi

  if ! command -v otool >/dev/null 2>&1; then
    missing_tool "otool" "meeting echo runtime deployment target"
    return 0
  fi
  if ! command -v lipo >/dev/null 2>&1; then
    missing_tool "lipo" "meeting echo runtime deployment target"
    return 0
  fi

  local failed=0
  local dylib
  for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    if [[ ! -f "$dylib" && ! -L "$dylib" ]]; then
      echo "Error: could not enumerate bundled LocalVQE dylibs: $FRAMEWORKS_DIR" >&2
      exit 1
    fi
    local minos_output
    if ! minos_output="$(macho_minos "$dylib")"; then
      echo "Error: could not determine a minimum OS version for bundled LocalVQE dylib: $dylib" >&2
      echo "$minos_output" >&2
      failed=1
      continue
    fi
    local arch minos
    while IFS=$'\t' read -r arch minos; do
      [[ -z "$arch" ]] && continue
      if version_gt "$minos" "$expected_min"; then
        echo "Error: bundled LocalVQE dylib requires a newer macOS than the app supports." >&2
        echo "  Dylib:        $dylib" >&2
        echo "  Architecture: $arch" >&2
        echo "  Dylib minos:  $minos" >&2
        echo "  App minimum:  $expected_min" >&2
        failed=1
      fi
    done <<<"$minos_output"
  done

  if [[ "$failed" == "1" ]]; then
    exit 1
  fi
  echo "Meeting echo runtime deployment targets verified against app minimum: $expected_min"
}

if [[ ! -d "$APP_PATH" ]]; then
  echo "Missing app bundle: $APP_PATH" >&2
  exit 1
fi

lib_present=0
model_present=0
[[ -f "$LIB_PATH" ]] && lib_present=1

if [[ -d "$MODEL_DIR" ]]; then
  discovered_count=0
  while IFS= read -r -d '' candidate; do
    MODEL_PATH="$candidate"
    discovered_count=$((discovered_count + 1))
  done < <(find "$MODEL_DIR" -maxdepth 1 -type f -iname '*.gguf' -print0)
  if [[ "$discovered_count" -gt 1 ]]; then
    echo "Error: exactly one meeting echo model must be bundled." >&2
    exit 1
  fi
fi

if [[ -n "${MACPARAKEET_MEETING_ECHO_MODEL_NAME:-}" ]]; then
  model_name_lc="$(printf '%s' "$MACPARAKEET_MEETING_ECHO_MODEL_NAME" | tr '[:upper:]' '[:lower:]')"
  if [[ "$MACPARAKEET_MEETING_ECHO_MODEL_NAME" == */* ||
        "$model_name_lc" != *.gguf ]]; then
    echo "Error: MACPARAKEET_MEETING_ECHO_MODEL_NAME must be a GGUF filename, not a path." >&2
    exit 1
  fi
  MODEL_PATH="$MODEL_DIR/$MACPARAKEET_MEETING_ECHO_MODEL_NAME"
fi

[[ -n "$MODEL_PATH" && -f "$MODEL_PATH" ]] && model_present=1

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
  echo "  Model:   ${MODEL_PATH:-$MODEL_DIR/*.gguf} ($model_present)" >&2
  exit 1
fi

if command -v file >/dev/null 2>&1; then
  if ! file "$LIB_PATH" | grep -Fq "Mach-O"; then
    echo "Error: meeting echo runtime is not a Mach-O binary: $LIB_PATH" >&2
    exit 1
  fi
else
  missing_tool "file" "meeting echo runtime Mach-O type"
fi

if [[ ! -x "$LIB_PATH" ]]; then
  echo "Error: meeting echo runtime is not executable: $LIB_PATH" >&2
  exit 1
fi

if command -v nm >/dev/null 2>&1; then
  exported_symbols="$(nm -gU "$LIB_PATH" 2>/dev/null | awk '{print $NF}' || true)"
  missing_symbols=()
  for symbol in "${REQUIRED_SYMBOLS[@]}"; do
    if ! grep -qFx "$symbol" <<<"$exported_symbols"; then
      missing_symbols+=("$symbol")
    fi
  done
  if [[ "${#missing_symbols[@]}" -gt 0 ]]; then
    echo "Error: meeting echo runtime is missing required LocalVQE symbols:" >&2
    printf '  %s\n' "${missing_symbols[@]}" >&2
    exit 1
  fi
else
  missing_tool "nm" "meeting echo runtime LocalVQE symbols"
fi

expected_model_sha="${MACPARAKEET_MEETING_ECHO_MODEL_SHA256:-}"
if [[ -z "$expected_model_sha" ]]; then
  bundled_model_name="$(basename "$MODEL_PATH")"
  bundled_model_name_lc="$(printf '%s' "$bundled_model_name" | tr '[:upper:]' '[:lower:]')"
  default_model_name_lc="$(printf '%s' "$DEFAULT_MEETING_ECHO_MODEL_NAME" | tr '[:upper:]' '[:lower:]')"
  if [[ "$bundled_model_name_lc" == "$default_model_name_lc" ]]; then
    expected_model_sha="$DEFAULT_MEETING_ECHO_MODEL_SHA256"
  elif [[ "$STRICT_MEETING_ECHO_ASSETS" == "1" ]]; then
    echo "Error: strict meeting echo asset verification requires MACPARAKEET_MEETING_ECHO_MODEL_SHA256 for non-default models." >&2
    echo "  Bundled model: $bundled_model_name" >&2
    echo "  Default model: $DEFAULT_MEETING_ECHO_MODEL_NAME" >&2
    echo "  Set MACPARAKEET_MEETING_ECHO_MODEL_SHA256 to the expected SHA256 for this model." >&2
    exit 1
  fi
fi

if [[ -n "$expected_model_sha" ]]; then
  actual_sha="$(shasum -a 256 "$MODEL_PATH" | awk '{print $1}')"
  expected_sha_lc="$(printf '%s' "$expected_model_sha" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  if [[ "$actual_sha" != "$expected_sha_lc" ]]; then
    echo "Error: bundled meeting echo model SHA256 mismatch." >&2
    echo "  Expected: $expected_model_sha" >&2
    echo "  Actual:   $actual_sha" >&2
    exit 1
  fi
  echo "Meeting echo model SHA256 verified: $actual_sha"
fi

if command -v otool >/dev/null 2>&1; then
  # otool -L emits an unindented header per arch (e.g. "lib (architecture arm64):"),
  # followed by tab-indented dependency lines. Select only indented lines so
  # universal (fat) binaries with multiple arch headers parse correctly; a plain
  # `tail -n +2` drops only the first header and misreads later arch headers as
  # non-portable references, wrongly failing strict verification.
  unresolved_deps="$(
    otool -L "$LIB_PATH" |
      awk '/^[[:space:]]/ {print $1}' |
      grep -Ev '^@rpath/|^@loader_path/|^/System/Library/|^/usr/lib/' || true
  )"
  if [[ -n "$unresolved_deps" ]]; then
    if [[ "$STRICT_MEETING_ECHO_ASSETS" == "1" ]]; then
      echo "Error: meeting echo runtime has non-portable dylib references:" >&2
      echo "$unresolved_deps" >&2
      exit 1
    else
      echo "Warning: meeting echo runtime has non-system dylib references; ensure they are bundled and use @rpath/@loader_path:" >&2
      echo "$unresolved_deps" >&2
    fi
  fi
else
  missing_tool "otool" "meeting echo runtime dylib references"
fi

verify_deployment_targets

if [[ "$VERIFY_CODE_SIGNATURES" == "1" ]]; then
  codesign --verify --strict --verbose=2 "$LIB_PATH"
fi

echo "Meeting echo assets verified: $(basename "$MODEL_PATH")"
