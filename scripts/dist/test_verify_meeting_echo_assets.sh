#!/usr/bin/env bash
set -euo pipefail

# Regression coverage for the LocalVQE bundled-dylib deployment-target check
# added to scripts/dist/verify_meeting_echo_assets.sh: every bundled LocalVQE
# dylib and architecture slice must carry a minimum-OS-version load command
# no higher than the app's LSMinimumSystemVersion, malformed/missing versions
# are rejected, and missing inspection tools are only tolerated outside
# strict mode. Existing missing-asset passthrough and model checks must keep
# working.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY_SCRIPT="$ROOT_DIR/scripts/dist/verify_meeting_echo_assets.sh"
TMP_DIR="$(mktemp -d)"
SRC_C="$TMP_DIR/localvqe_stub.c"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cat >"$SRC_C" <<'EOF'
int localvqe_new(void) { return 0; }
int localvqe_process_frame_f32(void) { return 0; }
int localvqe_reset(void) { return 0; }
int localvqe_free(void) { return 0; }
EOF

# A full clone of the system PATH (every /usr/bin and /bin executable
# symlinked in), minus any tool names passed after $dir. Used as a
# stand-alone PATH (not prepended) so specific tools (otool, lipo) can be made
# truly absent -- not merely shadowed -- to exercise the missing-tool paths
# without disturbing every other real tool (nm, file, shasum, codesign, bash
# itself via the script's `#!/usr/bin/env bash` shebang, etc).
make_restricted_path() {
  local dir="$1"
  shift
  local omit=("$@")
  mkdir -p "$dir"
  local src f base o skip
  for src in /usr/bin /bin; do
    for f in "$src"/*; do
      [[ -f "$f" ]] || continue
      base="$(basename "$f")"
      skip=0
      for o in "${omit[@]}"; do
        [[ "$o" == "$base" ]] && skip=1
      done
      [[ "$skip" == "1" ]] && continue
      ln -sf "$f" "$dir/$base"
    done
  done
}

# make_dylib <out_path> <arch:minos> [<arch:minos> ...]
make_dylib() {
  local out="$1"
  shift
  local slices=()
  local spec arch minos slice_path
  for spec in "$@"; do
    arch="${spec%%:*}"
    minos="${spec#*:}"
    slice_path="$TMP_DIR/slice-$(basename "$out")-$arch-$RANDOM.dylib"
    clang -arch "$arch" -shared -o "$slice_path" "$SRC_C" -mmacosx-version-min="$minos"
    slices+=("$slice_path")
  done
  if [[ "${#slices[@]}" -eq 1 ]]; then
    cp "${slices[0]}" "$out"
  else
    lipo -create "${slices[@]}" -output "$out"
  fi
  install_name_tool -id "@rpath/$(basename "$out")" "$out"
  chmod +x "$out"
}

# make_app <name> writes a minimal fixture bundle (no dylib/model yet) and
# prints its path. Space in the default name exercises path-with-spaces
# handling end to end.
make_app() {
  local name="${1:-My Fixture}"
  local app_path="$TMP_DIR/${name}.app"
  mkdir -p "$app_path/Contents/Frameworks" "$app_path/Contents/Resources/MeetingEchoSuppression"
  printf '%s\n' "$app_path"
}

write_info_plist_min_version() {
  local app_path="$1" version="$2"
  local plist="$app_path/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Clear dict' "$plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $version" "$plist"
}

add_fixture_model() {
  local app_path="$1"
  printf 'fixture model content\n' >"$app_path/Contents/Resources/MeetingEchoSuppression/fixture-model.gguf"
}

run_verifier() {
  local app_path="$1"
  shift
  "$@" "$VERIFY_SCRIPT" "$app_path" 2>&1
}

assert_pass() {
  local label="$1" app_path="$2"
  shift 2
  local output
  if ! output="$(run_verifier "$app_path" "$@")"; then
    printf 'FAIL: %s should pass\n%s\n' "$label" "$output" >&2
    exit 1
  fi
  printf '%s\n' "$output"
}

assert_fail_contains() {
  local label="$1" app_path="$2" expected="$3"
  shift 3
  local output
  if output="$(run_verifier "$app_path" "$@")"; then
    printf 'FAIL: %s should fail\n%s\n' "$label" "$output" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    printf 'FAIL: %s expected error containing %q\n%s\n' "$label" "$expected" "$output" >&2
    exit 1
  fi
}

# --- Baseline: exactly-at-minimum passes ------------------------------------
APP1="$(make_app "Fixture Exact")"
make_dylib "$APP1/Contents/Frameworks/liblocalvqe.dylib" "arm64:14.2"
add_fixture_model "$APP1"
out="$(assert_pass "dylib minos equal to app minimum" "$APP1" env MACPARAKEET_MEETING_ECHO_MIN_MACOS_VERSION=14.2)"
[[ "$out" == *"deployment targets verified against app minimum: 14.2"* ]] || {
  printf 'FAIL: expected deployment target success message\n%s\n' "$out" >&2
  exit 1
}
echo "PASS: dylib minos exactly at app minimum passes"

# --- A dylib above the app minimum is rejected ------------------------------
APP2="$(make_app "Fixture Too New")"
make_dylib "$APP2/Contents/Frameworks/liblocalvqe.dylib" "arm64:15.7"
add_fixture_model "$APP2"
assert_fail_contains \
  "dylib above app minimum is rejected" \
  "$APP2" \
  "requires a newer macOS than the app supports" \
  env MACPARAKEET_MEETING_ECHO_MIN_MACOS_VERSION=14.2
echo "PASS: dylib above app minimum is rejected"

# --- Universal dylib with mixed per-arch minimums: only the offending slice
# is rejected, both slices are actually inspected. ---------------------------
APP3="$(make_app "Fixture Universal")"
make_dylib "$APP3/Contents/Frameworks/liblocalvqe.dylib" "arm64:14.2" "x86_64:15.7"
add_fixture_model "$APP3"
assert_fail_contains \
  "universal dylib with one over-limit slice is rejected" \
  "$APP3" \
  "Architecture: x86_64" \
  env MACPARAKEET_MEETING_ECHO_MIN_MACOS_VERSION=14.2

APP3b="$(make_app "Fixture Universal OK")"
make_dylib "$APP3b/Contents/Frameworks/liblocalvqe.dylib" "arm64:14.2" "x86_64:14.2"
add_fixture_model "$APP3b"
assert_pass "universal dylib with both slices at the limit passes" "$APP3b" env MACPARAKEET_MEETING_ECHO_MIN_MACOS_VERSION=14.2 >/dev/null
echo "PASS: universal dylibs are inspected per architecture slice"

# --- Numeric comparison, not lexical: 14.10 dylib against 14.2 app minimum
# must be rejected (14.10 > 14.2 numerically). -------------------------------
APP4="$(make_app "Fixture Numeric")"
make_dylib "$APP4/Contents/Frameworks/liblocalvqe.dylib" "arm64:14.10"
add_fixture_model "$APP4"
assert_fail_contains \
  "numeric comparison rejects 14.10 against app minimum 14.2" \
  "$APP4" \
  "requires a newer macOS than the app supports" \
  env MACPARAKEET_MEETING_ECHO_MIN_MACOS_VERSION=14.2
echo "PASS: version comparison is numeric, not lexical"

# --- Every bundled LocalVQE dependency is inspected, not just liblocalvqe ---
APP5="$(make_app "Fixture Dependency")"
make_dylib "$APP5/Contents/Frameworks/liblocalvqe.dylib" "arm64:14.2"
make_dylib "$APP5/Contents/Frameworks/libggml-cpu.dylib" "arm64:15.7"
add_fixture_model "$APP5"
assert_fail_contains \
  "a bundled dependency other than liblocalvqe.dylib is also inspected" \
  "$APP5" \
  "libggml-cpu.dylib" \
  env MACPARAKEET_MEETING_ECHO_MIN_MACOS_VERSION=14.2
echo "PASS: every bundled LocalVQE dylib is inspected, not only liblocalvqe.dylib"

# --- Malformed/corrupt dylib (no parseable version) is rejected ------------
APP6="$(make_app "Fixture Malformed")"
make_dylib "$APP6/Contents/Frameworks/liblocalvqe.dylib" "arm64:14.2"
head -c 64 "$APP6/Contents/Frameworks/liblocalvqe.dylib" >"$APP6/Contents/Frameworks/libggml-corrupt.dylib"
add_fixture_model "$APP6"
assert_fail_contains \
  "a corrupt/unparseable bundled dylib is rejected" \
  "$APP6" \
  "could not determine a minimum OS version" \
  env MACPARAKEET_MEETING_ECHO_MIN_MACOS_VERSION=14.2
echo "PASS: malformed/unparseable dylib version is rejected"

# --- Expected minimum resolution: explicit override wins; Info.plist is the
# fallback; absent both, verification fails clearly (never silently passes).
APP7="$(make_app "Fixture Plist")"
make_dylib "$APP7/Contents/Frameworks/liblocalvqe.dylib" "arm64:14.2"
add_fixture_model "$APP7"
write_info_plist_min_version "$APP7" "14.2"
assert_pass "expected minimum read from Info.plist LSMinimumSystemVersion" "$APP7" >/dev/null
write_info_plist_min_version "$APP7" "14.0"
assert_fail_contains \
  "override takes precedence over a looser Info.plist minimum" \
  "$APP7" \
  "requires a newer macOS than the app supports" \
  env MACPARAKEET_MEETING_ECHO_MIN_MACOS_VERSION=14.0
echo "PASS: MACPARAKEET_MEETING_ECHO_MIN_MACOS_VERSION overrides, Info.plist is the fallback"

APP8="$(make_app "Fixture No Minimum")"
make_dylib "$APP8/Contents/Frameworks/liblocalvqe.dylib" "arm64:14.2"
add_fixture_model "$APP8"
assert_fail_contains \
  "no override and no Info.plist minimum fails clearly rather than silently passing" \
  "$APP8" \
  "could not determine a valid app LSMinimumSystemVersion"
echo "PASS: an unresolvable app minimum is a hard failure, not a silent pass"

# --- Missing inspection tools: strict mode rejects, non-strict warns/skips -
RESTRICTED_BIN="$TMP_DIR/bin-no-otool-lipo"
make_restricted_path "$RESTRICTED_BIN" otool lipo
APP9="$(make_app "Fixture No Tools")"
make_dylib "$APP9/Contents/Frameworks/liblocalvqe.dylib" "arm64:14.2"
add_fixture_model "$APP9"

run_restricted() {
  PATH="$RESTRICTED_BIN" "$@" "$VERIFY_SCRIPT" "$APP9" 2>&1
}
FIXTURE_MODEL_SHA256="$(shasum -a 256 "$APP9/Contents/Resources/MeetingEchoSuppression/fixture-model.gguf" | awk '{print $1}')"
if out="$(run_restricted env MACPARAKEET_MEETING_ECHO_MIN_MACOS_VERSION=14.2 STRICT_MEETING_ECHO_ASSETS=1 MACPARAKEET_MEETING_ECHO_MODEL_SHA256="$FIXTURE_MODEL_SHA256")"; then
  printf 'FAIL: strict mode should fail when otool/lipo are unavailable\n%s\n' "$out" >&2
  exit 1
fi
[[ "$out" == *"is not available"* ]] || {
  printf 'FAIL: expected a missing-tool error\n%s\n' "$out" >&2
  exit 1
}
echo "PASS: strict mode rejects when otool/lipo are unavailable"

if ! out="$(run_restricted env MACPARAKEET_MEETING_ECHO_MIN_MACOS_VERSION=14.2 STRICT_MEETING_ECHO_ASSETS=0)"; then
  printf 'FAIL: non-strict mode should tolerate missing otool/lipo\n%s\n' "$out" >&2
  exit 1
fi
[[ "$out" == *"Warning: skipped"* ]] || {
  printf 'FAIL: expected a skip warning in non-strict mode\n%s\n' "$out" >&2
  exit 1
}
echo "PASS: non-strict mode warns and skips when otool/lipo are unavailable"

# --- Preserve existing behavior: no assets bundled is still a passthrough --
APP10="$(make_app "Fixture Passthrough")"
out="$(assert_pass "no assets bundled remains a passthrough pass" "$APP10")"
[[ "$out" == *"passthrough"* ]] || {
  printf 'FAIL: expected passthrough message\n%s\n' "$out" >&2
  exit 1
}
echo "PASS: bundles with no meeting echo assets remain a passthrough pass"

echo "test_verify_meeting_echo_assets fixture tests passed"
