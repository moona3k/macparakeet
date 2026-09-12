#!/usr/bin/env bash
set -euo pipefail

# Regression coverage for scripts/dist/macho_min_version.sh: numeric macOS
# version comparison (patch levels, "14.10" > "14.2" not lexical), and
# per-architecture Mach-O minimum-OS-version extraction against real
# synthetic dylibs (thin and universal), plus malformed-input handling.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT_DIR/scripts/dist/macho_min_version.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# shellcheck source=scripts/dist/macho_min_version.sh
. "$HELPER"

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s: expected %q, got %q\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_true() {
  local label="$1"
  shift
  if ! "$@"; then
    printf 'FAIL: %s expected true\n' "$label" >&2
    exit 1
  fi
}

assert_false() {
  local label="$1"
  shift
  if "$@"; then
    printf 'FAIL: %s expected false\n' "$label" >&2
    exit 1
  fi
}

# --- is_macos_version --------------------------------------------------
assert_true "14.2 is a valid version" is_macos_version "14.2"
assert_true "14 is a valid version" is_macos_version "14"
assert_true "14.2.3 is a valid version" is_macos_version "14.2.3"
assert_false "empty string is invalid" is_macos_version ""
assert_false "trailing dot is invalid" is_macos_version "14."
assert_false "four components is invalid" is_macos_version "1.2.3.4"
assert_false "non-numeric is invalid" is_macos_version "abc"
assert_false "leading v is invalid" is_macos_version "v14.2"
echo "PASS: is_macos_version accepts 1-3 numeric dot components only"

# --- version_compare / version_gt: numeric, not lexical -----------------
assert_eq "14.10 vs 14.2" "$(version_compare 14.10 14.2)" "1"
assert_eq "14.2 vs 14.10" "$(version_compare 14.2 14.10)" "-1"
assert_eq "14.2 vs 14.2" "$(version_compare 14.2 14.2)" "0"
assert_eq "14 vs 14.0 (missing trailing components pad as zero)" "$(version_compare 14 14.0)" "0"
assert_eq "14.2.1 vs 14.2 (patch beats missing patch)" "$(version_compare 14.2.1 14.2)" "1"
assert_eq "14.2 vs 14.2.1" "$(version_compare 14.2 14.2.1)" "-1"

assert_true "14.10 > 14.2" version_gt 14.10 14.2
assert_false "14.2 > 14.10" version_gt 14.2 14.10
assert_false "14.2 > 14.2 (equal is not greater)" version_gt 14.2 14.2
assert_true "26.0 > 14.2 (the pre-fix regression case)" version_gt 26.0 14.2
echo "PASS: version_compare/version_gt compare numerically by dot component, not lexically"

command -v clang >/dev/null 2>&1 || {
  echo "SKIP: clang unavailable; skipping real Mach-O synthetic dylib coverage" >&2
  echo "test_macho_min_version fixture tests passed (partial: clang unavailable)"
  exit 0
}

cat >"$TMP_DIR/stub.c" <<'EOF'
int localvqe_stub(void) { return 0; }
EOF

# --- macho_minos: thin dylib ---------------------------------------------
clang -arch arm64 -shared -o "$TMP_DIR/thin.dylib" "$TMP_DIR/stub.c" -mmacosx-version-min=14.2
thin_out="$(macho_minos "$TMP_DIR/thin.dylib")"
assert_eq "thin dylib reports its single slice" "$thin_out" "$(printf 'arm64\t14.2')"
echo "PASS: macho_minos reports the minos for a thin dylib"

# --- macho_minos: universal dylib with mixed per-arch minimums, including
# a patch-level value, and a path containing spaces. ----------------------
SPACED_DIR="$TMP_DIR/dir with spaces"
mkdir -p "$SPACED_DIR"
clang -arch arm64 -shared -o "$TMP_DIR/arm.dylib" "$TMP_DIR/stub.c" -mmacosx-version-min=14.2
clang -arch x86_64 -shared -o "$TMP_DIR/x86.dylib" "$TMP_DIR/stub.c" -mmacosx-version-min=15.7
lipo -create "$TMP_DIR/arm.dylib" "$TMP_DIR/x86.dylib" -output "$SPACED_DIR/universal lib.dylib"

universal_out="$(macho_minos "$SPACED_DIR/universal lib.dylib")"
[[ "$universal_out" == *$'arm64\t14.2'* ]] || {
  printf 'FAIL: universal output missing arm64 slice: %s\n' "$universal_out" >&2
  exit 1
}
[[ "$universal_out" == *$'x86_64\t15.7'* ]] || {
  printf 'FAIL: universal output missing x86_64 slice: %s\n' "$universal_out" >&2
  exit 1
}
echo "PASS: macho_minos reports mixed per-architecture minimums for a universal dylib at a path with spaces"

# --- macho_minos: malformed/non-Mach-O input is a hard failure, not a
# silently empty/successful result. ---------------------------------------
echo "not a mach-o file" >"$TMP_DIR/bogus.dylib"
if bogus_out="$(macho_minos "$TMP_DIR/bogus.dylib" 2>/dev/null)"; then
  printf 'FAIL: macho_minos should fail on a non-Mach-O file, got: %s\n' "$bogus_out" >&2
  exit 1
fi
echo "PASS: macho_minos fails (rather than silently succeeding) on a non-Mach-O file"

# Truncated/corrupted Mach-O: lipo -info fails outright, still a hard failure.
head -c 32 "$TMP_DIR/thin.dylib" >"$TMP_DIR/truncated.dylib"
if truncated_out="$(macho_minos "$TMP_DIR/truncated.dylib" 2>/dev/null)"; then
  printf 'FAIL: macho_minos should fail on a truncated Mach-O file, got: %s\n' "$truncated_out" >&2
  exit 1
fi
echo "PASS: macho_minos fails on a truncated/corrupt Mach-O file"

echo "test_macho_min_version fixture tests passed"
