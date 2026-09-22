#!/bin/bash
# Standalone file-copy regression fixture. Uses only its newly created directory.
set -euo pipefail
QA_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QA_FIXTURE_ROOT="$(mktemp -d "$QA_SCRIPT_DIR/fixture.XXXXXX")"
QA_PRODUCTS="$QA_FIXTURE_ROOT/External Products"
QA_PACKAGE="$QA_PRODUCTS/PackageFrameworks"
QA_FRAMEWORK="$QA_PRODUCTS/Sparkle.framework"
mkdir -p "$QA_FRAMEWORK/Versions/B/Resources" "$QA_FRAMEWORK/Versions/B/Headers" "$QA_PACKAGE" "$QA_FIXTURE_ROOT/red/Frameworks" "$QA_FIXTURE_ROOT/green/Frameworks" "$QA_FIXTURE_ROOT/direct/Frameworks"
printf 'synthetic framework binary\n' > "$QA_FRAMEWORK/Versions/B/Sparkle"
printf 'synthetic resource\n' > "$QA_FRAMEWORK/Versions/B/Resources/Info.plist"
printf 'synthetic header\n' > "$QA_FRAMEWORK/Versions/B/Headers/Sparkle.h"
chmod 755 "$QA_FRAMEWORK/Versions/B/Sparkle"
ln -s B "$QA_FRAMEWORK/Versions/Current"
ln -s Versions/Current/Sparkle "$QA_FRAMEWORK/Sparkle"
ln -s Versions/Current/Resources "$QA_FRAMEWORK/Resources"
ln -s Versions/Current/Headers "$QA_FRAMEWORK/Headers"
ln -s "$QA_FRAMEWORK" "$QA_PACKAGE/Sparkle.framework"

assert_framework_copy() {
  local framework="$1"
  [ -d "$framework" ] && [ ! -L "$framework" ] || return 1
  [ "$(readlink "$framework/Versions/Current")" = B ] || return 1
  [ "$(readlink "$framework/Sparkle")" = Versions/Current/Sparkle ] || return 1
  [ "$(readlink "$framework/Resources")" = Versions/Current/Resources ] || return 1
  [ "$(readlink "$framework/Headers")" = Versions/Current/Headers ] || return 1
  [ -x "$framework/Sparkle" ] || return 1
  [ -f "$framework/Resources/Info.plist" ] || return 1
  [ -f "$framework/Headers/Sparkle.h" ] || return 1
}

/bin/cp -R "$QA_PACKAGE/Sparkle.framework" "$QA_FIXTURE_ROOT/red/Frameworks/"
if assert_framework_copy "$QA_FIXTURE_ROOT/red/Frameworks/Sparkle.framework"; then
  printf 'Unexpected RED pass: ordinary recursive copy did not reproduce the defect.\n' >&2
  exit 1
fi
[ -L "$QA_FIXTURE_ROOT/red/Frameworks/Sparkle.framework" ]
[ "$(readlink "$QA_FIXTURE_ROOT/red/Frameworks/Sparkle.framework")" = "$QA_FRAMEWORK" ]
printf 'RED: cp -R preserves the external absolute root symlink; self-contained framework assertion fails as expected.\n'

/bin/cp -RH "$QA_PACKAGE/Sparkle.framework" "$QA_FIXTURE_ROOT/green/Frameworks/"
assert_framework_copy "$QA_FIXTURE_ROOT/green/Frameworks/Sparkle.framework"
cmp "$QA_FRAMEWORK/Versions/B/Sparkle" "$QA_FIXTURE_ROOT/green/Frameworks/Sparkle.framework/Versions/B/Sparkle"
printf 'GREEN: cp -RH dereferences the command-line root, keeps all four internal relative links, and preserves payload and executable mode.\n'

/bin/cp -RH "$QA_FRAMEWORK" "$QA_FIXTURE_ROOT/direct/Frameworks/"
assert_framework_copy "$QA_FIXTURE_ROOT/direct/Frameworks/Sparkle.framework"
printf 'GREEN: cp -RH also accepts a real framework directory (fallback source).\n'

# Move only fixture-owned sources to demonstrate artifact independence.
mv "$QA_PRODUCTS" "$QA_FIXTURE_ROOT/External Products Moved"
[ ! -e "$QA_FIXTURE_ROOT/red/Frameworks/Sparkle.framework/Sparkle" ]
assert_framework_copy "$QA_FIXTURE_ROOT/green/Frameworks/Sparkle.framework"
assert_framework_copy "$QA_FIXTURE_ROOT/direct/Frameworks/Sparkle.framework"
printf 'GREEN: copied frameworks remain usable after generated source products move; the old copy is broken.\n'
printf 'Fixture retained at: %s\n' "$QA_FIXTURE_ROOT"
