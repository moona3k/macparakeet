#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-dist/MacParakeet.app}"

fail() {
  echo "error: $*" >&2
  exit 1
}

if [[ ! -d "$APP_PATH" ]]; then
  fail "Missing app bundle: $APP_PATH"
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  fail "Missing Info.plist: $INFO_PLIST"
fi

short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null || true)"

normalized="$(printf '%s' "$short_version" | tr '[:upper:]' '[:lower:]' | xargs)"
if [[ -z "$normalized" ]]; then
  fail "CFBundleShortVersionString is missing or empty; rebuild with VERSION=X.Y.Z before signing."
fi

if [[ "$normalized" == "0.0.0" || "$normalized" == "dev" || "$normalized" == *"pdx"* ]]; then
  fail "Refusing to sign dev/sentinel app version '$short_version'; rebuild with VERSION=X.Y.Z."
fi

if ! [[ "$normalized" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "CFBundleShortVersionString must be X.Y.Z for release signing; got '$short_version'."
fi

if [[ -z "$build_number" ]]; then
  fail "CFBundleVersion is missing or empty; rebuild before signing."
fi

echo "Verified release version: $short_version ($build_number)"
