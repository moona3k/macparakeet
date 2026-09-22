#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY_SCRIPT="$ROOT_DIR/scripts/dist/verify_release_version.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

make_app() {
  local name="$1"
  local short_version="${2-}"
  local build_number="${3-42}"
  local include_short_version="${4-1}"
  local app_path="$TMP_DIR/${name}.app"
  local plist_path="$app_path/Contents/Info.plist"

  mkdir -p "$app_path/Contents"
  /usr/libexec/PlistBuddy -c 'Clear dict' "$plist_path" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.macparakeet.fixture' "$plist_path"
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $build_number" "$plist_path"
  if [[ "$include_short_version" == "1" ]]; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $short_version" "$plist_path"
  fi

  printf '%s\n' "$app_path"
}

assert_pass() {
  local label="$1"
  local app_path="$2"
  local output

  if ! output="$("$VERIFY_SCRIPT" "$app_path" 2>&1)"; then
    printf 'FAIL: %s should pass\n%s\n' "$label" "$output" >&2
    exit 1
  fi

  if [[ "$output" != *"Verified release version:"* ]]; then
    printf 'FAIL: %s did not print success output\n%s\n' "$label" "$output" >&2
    exit 1
  fi
}

assert_fail_contains() {
  local label="$1"
  local app_path="$2"
  local expected="$3"
  local output

  if output="$("$VERIFY_SCRIPT" "$app_path" 2>&1)"; then
    printf 'FAIL: %s should fail\n%s\n' "$label" "$output" >&2
    exit 1
  fi

  if [[ "$output" != *"$expected"* ]]; then
    printf 'FAIL: %s expected error containing %q\n%s\n' "$label" "$expected" "$output" >&2
    exit 1
  fi
}

assert_pass "valid semver" "$(make_app valid '1.2.3')"
assert_pass "valid semver with surrounding whitespace" "$(make_app valid-spaced $' \t1.2.3  ')"

assert_fail_contains "sentinel 0.0.0" "$(make_app zero '0.0.0')" "Refusing to sign dev/sentinel app version"
assert_fail_contains "dev version" "$(make_app dev 'dev')" "Refusing to sign dev/sentinel app version"
assert_fail_contains "pdx version" "$(make_app pdx '0.6.0-pdx')" "Refusing to sign dev/sentinel app version"
assert_fail_contains "missing short version" "$(make_app missing '' '42' '0')" "CFBundleShortVersionString is missing or empty"
assert_fail_contains "empty short version" "$(make_app empty '')" "CFBundleShortVersionString is missing or empty"
assert_fail_contains "malformed semver" "$(make_app malformed '1.2')" "CFBundleShortVersionString must be X.Y.Z"
assert_fail_contains "quoted malformed version" "$(make_app quoted '\"1.2.3')" "CFBundleShortVersionString must be X.Y.Z"
assert_fail_contains "backslash malformed version" "$(make_app backslash '1.2.\\')" "CFBundleShortVersionString must be X.Y.Z"

echo "verify_release_version fixture tests passed"
