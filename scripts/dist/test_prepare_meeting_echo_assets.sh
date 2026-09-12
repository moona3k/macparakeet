#!/usr/bin/env bash
set -euo pipefail

# Regression coverage for the LocalVQE deployment-target propagation added to
# scripts/dist/prepare_meeting_echo_assets.sh: CMAKE_OSX_DEPLOYMENT_TARGET
# must reach cmake, the runtime cache stamp must key on it so stale (e.g.
# pre-fix) caches rebuild, and a malformed app minimum must fail before any
# tool/network use.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREPARE_SCRIPT="$ROOT_DIR/scripts/dist/prepare_meeting_echo_assets.sh"
TMP_DIR="$(mktemp -d)"
FAKE_BIN="$TMP_DIR/bin"
CMAKE_LOG="$TMP_DIR/cmake.log"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN"

# A real (tiny) local upstream repo with a submodule at ggml/vendor/ggml, so
# ensure_localvqe_source/localvqe_source_is_current exercise real git rather
# than a git double. cmake itself is faked below so the "build" never touches
# the fixture's (nonexistent) CMakeLists.
make_upstream_repo() {
  local sub_dir="$TMP_DIR/upstream-sub"
  local upstream_dir="$TMP_DIR/upstream.git"

  git init -q --initial-branch=main "$sub_dir"
  printf 'sub\n' >"$sub_dir/file.txt"
  git -C "$sub_dir" add file.txt
  git -C "$sub_dir" -c user.email=test@example.com -c user.name=test commit -q -m init

  git init -q --initial-branch=main "$upstream_dir"
  mkdir -p "$upstream_dir/ggml"
  printf 'root\n' >"$upstream_dir/root.txt"
  git -C "$upstream_dir" add root.txt
  git -C "$upstream_dir" -c user.email=test@example.com -c user.name=test commit -q -m root
  GIT_ALLOW_PROTOCOL=file git -C "$upstream_dir" submodule add -q "$sub_dir" ggml/vendor/ggml
  git -C "$upstream_dir" -c user.email=test@example.com -c user.name=test commit -q -m submodule

  printf '%s\n' "$upstream_dir"
}

UPSTREAM_REPO="$(make_upstream_repo)"
UPSTREAM_REF="$(git -C "$UPSTREAM_REPO" rev-parse HEAD)"

cat >"$FAKE_BIN/cmake" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
: "${CMAKE_LOG:?}"

{
  printf '%s\n' "--- cmake call ---"
  for a in "$@"; do printf '%s\n' "$a"; done
} >>"$CMAKE_LOG"

mode="configure"
build_dir=""
target=""
argc=$#
i=1
while [[ $i -le $argc ]]; do
  a="${!i}"
  case "$a" in
    --build)
      i=$((i + 1))
      mode="build"
      build_dir="${!i}"
      ;;
    -B)
      i=$((i + 1))
      build_dir="${!i}"
      ;;
    -DCMAKE_OSX_DEPLOYMENT_TARGET=*)
      target="${a#-DCMAKE_OSX_DEPLOYMENT_TARGET=}"
      ;;
  esac
  i=$((i + 1))
done

if [[ "$mode" == "build" ]]; then
  if [[ -n "${FAKE_CMAKE_FAIL_ONCE_MARKER:-}" && ! -f "$FAKE_CMAKE_FAIL_ONCE_MARKER" ]]; then
    touch "$FAKE_CMAKE_FAIL_ONCE_MARKER"
    echo "fake cmake: simulated parallel build failure" >&2
    exit 1
  fi
  mkdir -p "$build_dir"
  target="$(cat "$build_dir/.fake_deployment_target" 2>/dev/null || echo 11.0)"
  clang -shared -o "$build_dir/liblocalvqe.dylib" "$FAKE_CMAKE_SRC" -mmacosx-version-min="$target"
  exit 0
fi

mkdir -p "$build_dir"
printf '%s' "$target" >"$build_dir/.fake_deployment_target"
exit 0
SCRIPT
chmod +x "$FAKE_BIN/cmake"

cat >"$FAKE_BIN/curl" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_CURL_CONTENT:?}"
output=""
argc=$#
i=1
while [[ $i -le $argc ]]; do
  a="${!i}"
  if [[ "$a" == "--output" ]]; then
    i=$((i + 1))
    output="${!i}"
  fi
  i=$((i + 1))
done
: "${output:?fake curl: no --output path given}"
printf '%s' "$FAKE_CURL_CONTENT" >"$output"
SCRIPT
chmod +x "$FAKE_BIN/curl"

FAKE_CMAKE_SRC="$TMP_DIR/localvqe_stub.c"
cat >"$FAKE_CMAKE_SRC" <<'EOF'
int localvqe_new(void) { return 0; }
int localvqe_process_frame_f32(void) { return 0; }
int localvqe_reset(void) { return 0; }
int localvqe_free(void) { return 0; }
EOF

FAKE_CURL_CONTENT="synthetic localvqe model fixture"
FAKE_MODEL_SHA256="$(printf '%s' "$FAKE_CURL_CONTENT" | shasum -a 256 | awk '{print $1}')"

run_prepare() {
  local assets_dir="$1"
  local source_dir="$2"
  shift 2
  PATH="$FAKE_BIN:$PATH" \
    GIT_ALLOW_PROTOCOL=file \
    CMAKE_LOG="$CMAKE_LOG" \
    FAKE_CMAKE_SRC="$FAKE_CMAKE_SRC" \
    FAKE_CURL_CONTENT="$FAKE_CURL_CONTENT" \
    MACPARAKEET_MEETING_ECHO_ASSETS_DIR="$assets_dir" \
    LOCALVQE_SOURCE_DIR="$source_dir" \
    LOCALVQE_REPO_URL="$UPSTREAM_REPO" \
    LOCALVQE_REF="$UPSTREAM_REF" \
    LOCALVQE_FETCH_REF="refs/heads/main" \
    MACPARAKEET_MEETING_ECHO_MODEL_SHA256="$FAKE_MODEL_SHA256" \
    "$@" \
    "$PREPARE_SCRIPT" 2>&1
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'FAIL: %s expected output containing %q\n%s\n' "$label" "$needle" "$haystack" >&2
    exit 1
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'FAIL: %s expected output NOT to contain %q\n%s\n' "$label" "$needle" "$haystack" >&2
    exit 1
  fi
}

# --- CMake receives an explicit, non-default deployment target -------------
: >"$CMAKE_LOG"
ASSETS_1="$TMP_DIR/assets-1"
SRC_1="$TMP_DIR/src-1"
out="$(run_prepare "$ASSETS_1" "$SRC_1" env MACPARAKEET_MEETING_ECHO_APP_MIN_MACOS_VERSION=15.5)"
if [[ ! -f "$ASSETS_1/lib/liblocalvqe.dylib" ]]; then
  printf 'FAIL: first prepare run did not produce liblocalvqe.dylib\n%s\n' "$out" >&2
  exit 1
fi
assert_contains "cmake configure args" "$(cat "$CMAKE_LOG")" "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.5"
built_minos="$("$ROOT_DIR/scripts/dist/macho_min_version.sh" "$ASSETS_1/lib/liblocalvqe.dylib")"
assert_contains "built dylib honors requested deployment target" "$built_minos" $'\t15.5'
echo "PASS: cmake receives explicit CMAKE_OSX_DEPLOYMENT_TARGET"

# --- Re-running with identical inputs is a cache hit (no rebuild) ----------
first_build_calls="$(grep -c -- '--build' "$CMAKE_LOG")"
out="$(run_prepare "$ASSETS_1" "$SRC_1" env MACPARAKEET_MEETING_ECHO_APP_MIN_MACOS_VERSION=15.5)"
second_build_calls="$(grep -c -- '--build' "$CMAKE_LOG")"
if [[ "$second_build_calls" != "$first_build_calls" ]]; then
  printf 'FAIL: unchanged inputs should be a cache hit (no extra cmake --build calls)\n%s\n' "$out" >&2
  exit 1
fi
assert_contains "unchanged inputs report cache hit" "$out" "already present"
echo "PASS: identical re-run is a cache hit"

# --- A stale/pre-fix stamp (no min_macos_version key) forces a rebuild -----
ASSETS_2="$TMP_DIR/assets-2"
SRC_2="$TMP_DIR/src-2"
mkdir -p "$ASSETS_2/lib"
clang -shared -o "$ASSETS_2/lib/liblocalvqe.dylib" "$FAKE_CMAKE_SRC" -mmacosx-version-min=26.0
printf 'repo=%s\nref=%s\nbuild_type=Release\nuniversal=0\n' "$UPSTREAM_REPO" "$UPSTREAM_REF" >"$ASSETS_2/lib/.localvqe-runtime.stamp"
printf 'liblocalvqe.dylib\n' >"$ASSETS_2/lib/.localvqe-runtime.dylibs"
: >"$CMAKE_LOG"
out="$(run_prepare "$ASSETS_2" "$SRC_2" env MACPARAKEET_MEETING_ECHO_APP_MIN_MACOS_VERSION=14.2)"
assert_not_contains "stale pre-fix stamp is not treated as current" "$out" "already present"
assert_contains "stale pre-fix stamp triggers a real build" "$(cat "$CMAKE_LOG")" "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.2"
rebuilt_minos="$("$ROOT_DIR/scripts/dist/macho_min_version.sh" "$ASSETS_2/lib/liblocalvqe.dylib")"
assert_contains "rebuilt dylib no longer carries the stale 26.0 minimum" "$rebuilt_minos" $'\t14.2'
echo "PASS: stale stamp without min_macos_version forces a rebuild"

# --- Parallel build failure retries once with -j1 --------------------------
ASSETS_3="$TMP_DIR/assets-3"
SRC_3="$TMP_DIR/src-3"
: >"$CMAKE_LOG"
FAIL_MARKER="$TMP_DIR/fail-once-marker"
rm -f "$FAIL_MARKER"
out="$(run_prepare "$ASSETS_3" "$SRC_3" env MACPARAKEET_MEETING_ECHO_APP_MIN_MACOS_VERSION=14.2 LOCALVQE_CMAKE_BUILD_JOBS=4 FAKE_CMAKE_FAIL_ONCE_MARKER="$FAIL_MARKER")"
assert_contains "parallel failure is retried at -j1" "$out" "retrying once with LOCALVQE_CMAKE_BUILD_JOBS=1"
if [[ ! -f "$ASSETS_3/lib/liblocalvqe.dylib" ]]; then
  printf 'FAIL: retried build did not eventually produce liblocalvqe.dylib\n%s\n' "$out" >&2
  exit 1
fi
echo "PASS: failed parallel build retries once at -j1"

# --- Override validation fails before any tool/network use -----------------
assert_fail_contains_no_tools() {
  local label="$1" expected="$2"
  shift 2
  local out
  if out="$(env "$@" "$PREPARE_SCRIPT" 2>&1)"; then
    printf 'FAIL: %s should fail\n%s\n' "$label" "$out" >&2
    exit 1
  fi
  assert_contains "$label" "$out" "$expected"
}

assert_fail_contains_no_tools \
  "malformed app minimum is rejected" \
  "must be a macOS version like 14.2" \
  MACPARAKEET_MEETING_ECHO_APP_MIN_MACOS_VERSION=not-a-version \
  MACPARAKEET_MEETING_ECHO_ASSETS_DIR="$TMP_DIR/assets-reject-4" LOCALVQE_SOURCE_DIR="$TMP_DIR/src-reject-4"

echo "PASS: a malformed app minimum is rejected before tool use"

echo "test_prepare_meeting_echo_assets fixture tests passed"
