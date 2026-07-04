#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-dist/MacParakeet.app}"
ALLOW_DEV_VERSION_SIGNING="${MACPARAKEET_ALLOW_DEV_VERSION_SIGNING:-0}"

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

if [[ -z "$build_number" ]]; then
  fail "CFBundleVersion is missing or empty; rebuild before signing."
fi

if [[ "$ALLOW_DEV_VERSION_SIGNING" == "1" ]]; then
  echo "Warning: MACPARAKEET_ALLOW_DEV_VERSION_SIGNING=1; allowing diagnostic signing for version '$short_version'." >&2
  echo "Verified diagnostic signing version override: $short_version ($build_number)"
  exit 0
fi

normalized="$(printf '%s' "$short_version" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [[ -z "$normalized" ]]; then
  fail "CFBundleShortVersionString is missing or empty; rebuild with VERSION=X.Y.Z before signing."
fi

if [[ "$normalized" == "0.0.0" || "$normalized" == "dev" || "$normalized" == *"pdx"* ]]; then
  fail "Refusing to sign dev/sentinel app version '$short_version'; rebuild with VERSION=X.Y.Z."
fi

if ! [[ "$normalized" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "CFBundleShortVersionString must be X.Y.Z for release signing; got '$short_version'."
fi

echo "Verified release version: $short_version ($build_number)"
