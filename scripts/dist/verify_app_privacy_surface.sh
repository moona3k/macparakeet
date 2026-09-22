#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-dist/MacParakeet.app}"
EXPECTED_BUNDLE_ID="${EXPECTED_BUNDLE_ID:-com.macparakeet.MacParakeet}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-FYAF2ZD7RM}"
EXPECTED_AUTHORITY="${EXPECTED_AUTHORITY:-Developer ID Application: Daniel Moon (FYAF2ZD7RM)}"

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

require_info_string() {
  local key="$1"
  local value
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    fail "Missing Info.plist privacy string: $key"
  fi
}

require_info_value() {
  local key="$1"
  local expected="$2"
  local value
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" 2>/dev/null || true)"
  if [[ "$value" != "$expected" ]]; then
    fail "Unexpected Info.plist value for $key: got '$value', expected '$expected'"
  fi
}

ENTITLEMENTS_PLIST="$(mktemp)"
CODESIGN_ERR="$(mktemp)"
trap 'rm -f "$ENTITLEMENTS_PLIST" "$CODESIGN_ERR"' EXIT

if ! codesign -d --xml --entitlements - "$APP_PATH" >"$ENTITLEMENTS_PLIST" 2>"$CODESIGN_ERR"; then
  cat "$CODESIGN_ERR" >&2
  fail "Could not read codesign entitlements for: $APP_PATH"
fi

CODESIGN_DETAILS="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
if ! grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID" <<<"$CODESIGN_DETAILS"; then
  echo "$CODESIGN_DETAILS" >&2
  fail "Unexpected signing team. Expected TeamIdentifier=$EXPECTED_TEAM_ID"
fi
if ! grep -Fq "Authority=$EXPECTED_AUTHORITY" <<<"$CODESIGN_DETAILS"; then
  echo "$CODESIGN_DETAILS" >&2
  fail "Unexpected signing authority. Expected Authority=$EXPECTED_AUTHORITY"
fi

require_entitlement_true() {
  local key="$1"
  local value
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$ENTITLEMENTS_PLIST" 2>/dev/null || true)"
  if [[ "$value" != "true" ]]; then
    fail "Missing true app entitlement: $key"
  fi
}

require_exact_ats_surface() {
  # Allowlist, not a presence check: the intended ATS policy is
  # NSAllowsLocalNetworking plus exactly one CGNAT exception domain
  # carrying exactly one attribute. Anything else — an extra exception
  # domain, an over-permissive attribute inside the approved domain (e.g.
  # NSExceptionAllowsInsecureHTTPSLoads, NSIncludesSubdomains, a lowered
  # TLS minimum), or NSAllowsArbitraryLoads/…InWebContent/…ForMedia set to
  # true — must fail the gate rather than pass silently.
  local surface
  surface="$(plutil -extract NSAppTransportSecurity json -o - "$INFO_PLIST" 2>/dev/null || echo '{}')"
  python3 - "$surface" <<'PY' || fail "NSAppTransportSecurity does not match the approved allowlist"
import json
import sys

surface = json.loads(sys.argv[1])

# These three may be present as an explicit false, but never true or absent-with-truthy-intent elsewhere.
for key in (
    "NSAllowsArbitraryLoads",
    "NSAllowsArbitraryLoadsInWebContent",
    "NSAllowsArbitraryLoadsForMedia",
):
    if surface.get(key) is False:
        del surface[key]

expected = {
    "NSAllowsLocalNetworking": True,
    "NSExceptionDomains": {
        "100.64.0.0/10": {
            "NSExceptionAllowsInsecureHTTPLoads": True,
        },
    },
}

if surface != expected:
    print(
        "got {} expected {}".format(
            json.dumps(surface, sort_keys=True),
            json.dumps(expected, sort_keys=True),
        ),
        file=sys.stderr,
    )
    sys.exit(1)
PY
}

require_info_value "CFBundleIdentifier" "$EXPECTED_BUNDLE_ID"
require_exact_ats_surface

require_info_string "NSMicrophoneUsageDescription"
require_info_string "NSAudioCaptureUsageDescription"
require_info_string "NSCalendarsFullAccessUsageDescription"

require_entitlement_true "com.apple.security.device.audio-input"
require_entitlement_true "com.apple.security.personal-information.calendars"
require_entitlement_true "com.apple.security.network.client"

echo "Verified app privacy surface: $APP_PATH"
