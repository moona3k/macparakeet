#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY_SCRIPT="$ROOT_DIR/scripts/dist/verify_app_privacy_surface.sh"
TMP_DIR="$(mktemp -d)"
FAKE_BIN="$TMP_DIR/bin"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/codesign" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

if [[ " $* " == *" --entitlements "* ]]; then
  cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key>
  <true/>
  <key>com.apple.security.personal-information.calendars</key>
  <true/>
  <key>com.apple.security.network.client</key>
  <true/>
</dict>
</plist>
PLIST
else
  printf '%s\n' 'TeamIdentifier=TESTTEAM' 'Authority=Fixture Authority' >&2
fi
SCRIPT
chmod +x "$FAKE_BIN/codesign"

# make_app builds a fixture .app whose Info.plist carries the fixed privacy
# strings plus the given NSAppTransportSecurity fragment (a JSON object), or
# no NSAppTransportSecurity key at all when ats_json is empty. Building the
# whole ATS dict as JSON — rather than issuing PlistBuddy `Add` commands per
# key — lets each fixture describe an arbitrary shape (extra domains, extra
# attributes) in one line.
make_app() {
  local name="$1"
  local ats_json="$2"
  local app_path="$TMP_DIR/${name}.app"
  local plist_path="$app_path/Contents/Info.plist"
  local json_path="$TMP_DIR/${name}.json"

  mkdir -p "$app_path/Contents"

  python3 - "$json_path" "$ats_json" <<'PY'
import json
import sys

json_path, ats_json = sys.argv[1], sys.argv[2]
doc = {
    "CFBundleIdentifier": "com.macparakeet.fixture",
    "NSMicrophoneUsageDescription": "Microphone",
    "NSAudioCaptureUsageDescription": "System audio",
    "NSCalendarsFullAccessUsageDescription": "Calendar",
}
if ats_json:
    doc["NSAppTransportSecurity"] = json.loads(ats_json)
with open(json_path, "w") as f:
    json.dump(doc, f)
PY
  plutil -convert xml1 -o "$plist_path" "$json_path"

  printf '%s\n' "$app_path"
}

run_verifier() {
  PATH="$FAKE_BIN:$PATH" \
    EXPECTED_BUNDLE_ID="com.macparakeet.fixture" \
    EXPECTED_TEAM_ID="TESTTEAM" \
    EXPECTED_AUTHORITY="Fixture Authority" \
    "$VERIFY_SCRIPT" "$1" 2>&1
}

assert_pass() {
  local label="$1"
  local app_path="$2"
  local output

  if ! output="$(run_verifier "$app_path")"; then
    printf 'FAIL: %s should pass\n%s\n' "$label" "$output" >&2
    exit 1
  fi
  if [[ "$output" != *"Verified app privacy surface:"* ]]; then
    printf 'FAIL: %s did not print success output\n%s\n' "$label" "$output" >&2
    exit 1
  fi
}

assert_fail_contains() {
  local label="$1"
  local app_path="$2"
  local expected="$3"
  local output

  if output="$(run_verifier "$app_path")"; then
    printf 'FAIL: %s should fail\n%s\n' "$label" "$output" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    printf 'FAIL: %s expected error containing %q\n%s\n' "$label" "$expected" "$output" >&2
    exit 1
  fi
}

ATS_MISMATCH="does not match the approved allowlist"

# The one intended shape: local networking on, exactly one CGNAT exception
# domain carrying exactly one attribute.
ATS_OK='{"NSAllowsLocalNetworking": true, "NSExceptionDomains": {"100.64.0.0/10": {"NSExceptionAllowsInsecureHTTPLoads": true}}}'

# Arbitrary-loads keys are allowed only when explicitly false (equivalent to absent).
ATS_ARBITRARY_EXPLICITLY_FALSE='{"NSAllowsLocalNetworking": true, "NSExceptionDomains": {"100.64.0.0/10": {"NSExceptionAllowsInsecureHTTPLoads": true}}, "NSAllowsArbitraryLoads": false, "NSAllowsArbitraryLoadsInWebContent": false, "NSAllowsArbitraryLoadsForMedia": false}'

ATS_LOCAL_NETWORKING_FALSE='{"NSAllowsLocalNetworking": false, "NSExceptionDomains": {"100.64.0.0/10": {"NSExceptionAllowsInsecureHTTPLoads": true}}}'
ATS_CGNAT_MISSING='{"NSAllowsLocalNetworking": true}'
ATS_CGNAT_FALSE='{"NSAllowsLocalNetworking": true, "NSExceptionDomains": {"100.64.0.0/10": {"NSExceptionAllowsInsecureHTTPLoads": false}}}'
ATS_ARBITRARY_LOADS='{"NSAllowsLocalNetworking": true, "NSExceptionDomains": {"100.64.0.0/10": {"NSExceptionAllowsInsecureHTTPLoads": true}}, "NSAllowsArbitraryLoads": true}'
ATS_ARBITRARY_LOADS_WEB='{"NSAllowsLocalNetworking": true, "NSExceptionDomains": {"100.64.0.0/10": {"NSExceptionAllowsInsecureHTTPLoads": true}}, "NSAllowsArbitraryLoadsInWebContent": true}'
ATS_ARBITRARY_LOADS_MEDIA='{"NSAllowsLocalNetworking": true, "NSExceptionDomains": {"100.64.0.0/10": {"NSExceptionAllowsInsecureHTTPLoads": true}}, "NSAllowsArbitraryLoadsForMedia": true}'
ATS_EXTRA_EXCEPTION_DOMAIN='{"NSAllowsLocalNetworking": true, "NSExceptionDomains": {"100.64.0.0/10": {"NSExceptionAllowsInsecureHTTPLoads": true}, "example.com": {"NSExceptionAllowsInsecureHTTPLoads": true}}}'
ATS_OVERPERMISSIVE_DOMAIN_ENTRY='{"NSAllowsLocalNetworking": true, "NSExceptionDomains": {"100.64.0.0/10": {"NSExceptionAllowsInsecureHTTPLoads": true, "NSExceptionAllowsInsecureHTTPSLoads": true}}}'

assert_pass "exact approved ATS surface" "$(make_app allowed "$ATS_OK")"
assert_pass "arbitrary-loads keys explicitly false" "$(make_app allowed_false_explicit "$ATS_ARBITRARY_EXPLICITLY_FALSE")"

assert_fail_contains \
  "NSAppTransportSecurity key missing entirely" \
  "$(make_app missing "")" \
  "$ATS_MISMATCH"
assert_fail_contains \
  "local networking explicitly denied" \
  "$(make_app denied "$ATS_LOCAL_NETWORKING_FALSE")" \
  "$ATS_MISMATCH"
assert_fail_contains \
  "CGNAT http exception missing" \
  "$(make_app no_cgnat "$ATS_CGNAT_MISSING")" \
  "$ATS_MISMATCH"
assert_fail_contains \
  "CGNAT http exception explicitly denied" \
  "$(make_app cgnat_denied "$ATS_CGNAT_FALSE")" \
  "$ATS_MISMATCH"
assert_fail_contains \
  "arbitrary loads must stay disabled" \
  "$(make_app arbitrary "$ATS_ARBITRARY_LOADS")" \
  "$ATS_MISMATCH"
# Regression for the Greptile P1 (thread PRRT_kwDORMx8l86fvfg1): a presence
# check on the CGNAT exception and the base NSAllowsArbitraryLoads key let an
# extra insecure exception domain, or the web/media arbitrary-loads keys,
# through undetected. The allowlist comparison must reject each of them.
assert_fail_contains \
  "extra exception domain rejected" \
  "$(make_app extra_domain "$ATS_EXTRA_EXCEPTION_DOMAIN")" \
  "$ATS_MISMATCH"
assert_fail_contains \
  "NSAllowsArbitraryLoadsInWebContent rejected" \
  "$(make_app arbitrary_web "$ATS_ARBITRARY_LOADS_WEB")" \
  "$ATS_MISMATCH"
assert_fail_contains \
  "NSAllowsArbitraryLoadsForMedia rejected" \
  "$(make_app arbitrary_media "$ATS_ARBITRARY_LOADS_MEDIA")" \
  "$ATS_MISMATCH"
assert_fail_contains \
  "over-permissive attribute inside the approved domain entry rejected" \
  "$(make_app overpermissive_domain "$ATS_OVERPERMISSIVE_DOMAIN_ENTRY")" \
  "$ATS_MISMATCH"

echo "verify_app_privacy_surface fixture tests passed"
