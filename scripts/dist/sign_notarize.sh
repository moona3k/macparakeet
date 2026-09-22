#!/usr/bin/env bash
set -euo pipefail

# Sign + notarize MacParakeet.app and optionally produce a notarized DMG.
#
# Prereqs:
# - Developer ID Application certificate installed in Keychain.
# - notarytool credentials stored in Keychain:
#     xcrun notarytool store-credentials "$NOTARYTOOL_PROFILE" --apple-id ... --team-id ... --password ...
#
# Environment variables:
#   APP_NAME              (default: MacParakeet)
#   DIST_DIR              (default: ./dist)
#   SIGN_IDENTITY         (default: Developer ID Application: Daniel Moon (FYAF2ZD7RM))
#   NOTARYTOOL_PROFILE    (required to notarize)
#   CREATE_DMG            (default: 1)
#   NOTARY_TIMEOUT_SECONDS       (default: 1800)
#   NOTARY_POLL_INTERVAL_SECONDS (default: 15)
#   MACPARAKEET_ALLOW_DEV_VERSION_SIGNING (default: 0; set 1 only for diagnostic signing)
#
# notarytool submit on this Mac SIGBUS-crashes (exit 138) with the default
# --progress / S3-acceleration path. A crashed submit can still appear in
# `notarytool history` as In Progress forever because the upload never
# finished. Always submit with --no-wait --no-progress --no-s3-acceleration
# and JSON output. Never use --wait. See docs/distribution.md gotcha #1.
#
# Outputs:
#   dist/MacParakeet.app (signed + stapled)
#   dist/MacParakeet.dmg (signed + stapled) if CREATE_DMG=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_NAME="${APP_NAME:-MacParakeet}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_PATH="$DIST_DIR/${APP_NAME}.app"

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Daniel Moon (FYAF2ZD7RM)}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-AC_PASSWORD}"
CREATE_DMG="${CREATE_DMG:-1}"
NOTARY_TIMEOUT_SECONDS="${NOTARY_TIMEOUT_SECONDS:-1800}"
NOTARY_POLL_INTERVAL_SECONDS="${NOTARY_POLL_INTERVAL_SECONDS:-15}"

if ! [[ "$NOTARY_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$NOTARY_TIMEOUT_SECONDS" -le 0 ]]; then
  echo "NOTARY_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 1
fi

if ! [[ "$NOTARY_POLL_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || [[ "$NOTARY_POLL_INTERVAL_SECONDS" -le 0 ]]; then
  echo "NOTARY_POLL_INTERVAL_SECONDS must be a positive integer" >&2
  exit 1
fi

poll_notarization() {
  local submission_id="$1"
  local artifact_label="$2"
  local started_at
  started_at="$(date +%s)"

  echo "Polling ${artifact_label} notarization status for $submission_id..."
  while true; do
    local status
    status="$(xcrun notarytool info "$submission_id" --keychain-profile "$NOTARYTOOL_PROFILE" 2>&1)"

    if echo "$status" | grep -q "status: Accepted"; then
      echo "${artifact_label} notarization accepted!"
      return 0
    elif echo "$status" | grep -Eq "status: (Invalid|Rejected)"; then
      echo "${artifact_label} notarization REJECTED:"
      echo "$status"
      exit 1
    fi

    local now elapsed status_line
    now="$(date +%s)"
    elapsed=$((now - started_at))
    if [[ "$elapsed" -ge "$NOTARY_TIMEOUT_SECONDS" ]]; then
      echo "${artifact_label} notarization timed out after ${elapsed}s:"
      echo "$status"
      echo "If this submit crashed locally (SIGBUS / exit 138) before" >&2
      echo "'Successfully uploaded file', this ID is an incomplete upload." >&2
      echo "Resubmit the same artifact; do not keep polling. See docs/distribution.md gotcha #1." >&2
      exit 1
    fi

    status_line="$(echo "$status" | grep 'status:' | head -1 | sed 's/^ *//')"
    if [[ -n "$status_line" ]]; then
      echo "  ${status_line} (${elapsed}s elapsed)"
    fi
    sleep "$NOTARY_POLL_INTERVAL_SECONDS"
  done
}

extract_notary_id() {
  python3 -c '
import json, re, sys
raw = sys.stdin.read()
for candidate in [raw] + list(reversed(raw.splitlines())):
    text = candidate.strip()
    if not text.startswith("{") or not text.endswith("}"):
        continue
    try:
        ident = json.loads(text).get("id")
    except json.JSONDecodeError:
        continue
    if ident:
        print(ident)
        raise SystemExit(0)
match = re.search(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
    raw,
)
if match:
    print(match.group(0))
'
}

submit_notarization() {
  local artifact="$1"
  local label="$2"
  local submit_out rc=0 submission_id=""

  echo "Submitting ${label} with --no-wait --no-progress --no-s3-acceleration..."
  set +e
  submit_out="$(
    xcrun notarytool submit "$artifact" \
      --keychain-profile "$NOTARYTOOL_PROFILE" \
      --no-wait --no-progress --no-s3-acceleration \
      --output-format json 2>&1
  )"
  rc=$?
  set -e
  echo "$submit_out"

  if [[ "$rc" -ne 0 ]]; then
    echo "Error: ${label} notarytool submit exited ${rc}." >&2
    echo "A history row that stays In Progress after a crash is an incomplete upload, not a slow Apple job." >&2
    echo "Resubmit this same artifact with --no-wait --no-progress --no-s3-acceleration --output-format json." >&2
    echo "Do not rebuild dist/. See docs/distribution.md gotcha #1." >&2
    exit 1
  fi

  submission_id="$(printf '%s' "$submit_out" | extract_notary_id)"
  if [[ -z "$submission_id" ]]; then
    echo "Error: Failed to extract ${label} submission ID from JSON output" >&2
    exit 1
  fi
  if ! printf '%s' "$submit_out" | grep -q 'Successfully uploaded file'; then
    echo "Error: ${label} submit returned an ID without 'Successfully uploaded file'." >&2
    echo "Do not poll this ID as if the upload finished." >&2
    exit 1
  fi

  poll_notarization "$submission_id" "$label"
}

if [[ ! -d "$APP_PATH" ]]; then
  echo "Missing app bundle: $APP_PATH" >&2
  echo "Run: $ROOT_DIR/scripts/dist/build_app_bundle.sh" >&2
  exit 1
fi

"$ROOT_DIR/scripts/dist/verify_release_version.sh" "$APP_PATH"

echo "[1/8] Clearing extended attributes…"
xattr -cr "$APP_PATH" || true

echo "[2/8] Signing nested frameworks and executables (if any)…"
# Sign inside-out: frameworks first, then helper binaries, then the app itself.

# Sign Sparkle.framework (auto-update framework) if embedded.
# Must sign inside-out: XPC services and nested apps first, then the framework itself.
SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
  echo "Signing: Sparkle.framework (inside-out)…"
  # Sign XPC services
  while IFS= read -r -d '' xpc; do
    echo "  Signing XPC: $(basename "$xpc")"
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$xpc"
  done < <(find "$SPARKLE_FW" -name "*.xpc" -type d -print0 2>/dev/null || true)
  # Sign nested apps (Updater.app)
  while IFS= read -r -d '' app; do
    echo "  Signing app: $(basename "$app")"
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$app"
  done < <(find "$SPARKLE_FW" -name "*.app" -type d -print0 2>/dev/null || true)
  # Sign standalone executables (Autoupdate)
  while IFS= read -r -d '' bin; do
    echo "  Signing binary: $(basename "$bin")"
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$bin"
  done < <(find "$SPARKLE_FW/Versions/B" -maxdepth 1 -type f -perm -111 -print0 2>/dev/null || true)
  # Sign the framework itself
  echo "  Signing: Sparkle.framework"
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$SPARKLE_FW"
fi

# Sign optional model-backed meeting echo-suppression dylibs.
while IFS= read -r -d '' dylib; do
  echo "Signing bundled dylib: $dylib"
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$dylib"
done < <(
  find "$APP_PATH/Contents/Frameworks" -maxdepth 1 -type f -name "*.dylib" -print0 2>/dev/null || true
)

# Sign helper binaries under Resources.
NODE_RUNTIME_ENTITLEMENTS="$ROOT_DIR/scripts/dist/NodeRuntime.entitlements"
YTDLP_RUNTIME_ENTITLEMENTS="$ROOT_DIR/scripts/dist/YtDlpRuntime.entitlements"
while IFS= read -r -d '' bin; do
  base="$(basename "$bin")"
  echo "Signing: $bin"
  if [[ "$base" == "node" || "$base" == "node-arm64" || "$base" == "node-x86_64" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
      --entitlements "$NODE_RUNTIME_ENTITLEMENTS" "$bin"
  elif [[ "$base" == "yt-dlp" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
      --entitlements "$YTDLP_RUNTIME_ENTITLEMENTS" "$bin"
  else
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$bin"
  fi
done < <(
  find "$APP_PATH/Contents/Resources" -maxdepth 1 -type f -perm -111 \
    \( -name "ffmpeg" -o -name "yt-dlp" -o -name "node" -o -name "node-arm64" -o -name "node-x86_64" \) -print0 2>/dev/null || true
)

while IFS= read -r -d '' bin; do
  base="$(basename "$bin")"
  if [[ "$base" == "$APP_NAME" ]]; then
    continue
  fi
  echo "Signing bundled executable: $bin"
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$bin"
done < <(
  find "$APP_PATH/Contents/MacOS" -maxdepth 1 -type f -perm -111 -print0 2>/dev/null || true
)

ENTITLEMENTS="$ROOT_DIR/scripts/dist/MacParakeet.entitlements"

echo "[3/8] Codesigning app (hardened runtime + entitlements)…"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" "$APP_PATH"

echo "[4/8] Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
"$ROOT_DIR/scripts/dist/verify_app_privacy_surface.sh" "$APP_PATH"
VERIFY_CODE_SIGNATURES=1 "$ROOT_DIR/scripts/dist/verify_meeting_echo_assets.sh" "$APP_PATH"

ZIP_PATH="$DIST_DIR/${APP_NAME}.app.zip"
rm -f "$ZIP_PATH"

echo "[5/8] Creating notarization zip…"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
  echo "SKIP_NOTARIZE=1; skipping notarization."
  exit 0
fi

echo "[6/8] Submitting to notarization service…"
submit_notarization "$ZIP_PATH" "App"

echo "[7/8] Stapling app…"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "[8/8] Gatekeeper assess…"
spctl --assess --type execute --verbose=4 "$APP_PATH"

if [[ "$CREATE_DMG" == "1" ]]; then
  DMG_PATH="$DIST_DIR/${APP_NAME}.dmg"
  rm -f "$DMG_PATH"

  echo "Creating DMG…"
  # Stage a folder with the app + Applications symlink for drag-to-install experience.
  DMG_STAGING="$DIST_DIR/.dmg-staging"
  DMG_RW="$DIST_DIR/${APP_NAME}-rw.dmg"
  rm -rf "$DMG_STAGING" "$DMG_RW"
  mkdir -p "$DMG_STAGING"
  cp -R "$APP_PATH" "$DMG_STAGING/"
  ln -s /Applications "$DMG_STAGING/Applications"

  # Create a read-write DMG first so we can customize the Finder layout.
  hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDRW "$DMG_RW" >/dev/null
  rm -rf "$DMG_STAGING"

  # Mount and apply Finder layout: app on left, Applications on right.
  # hdiutil output is tab-delimited; mount points may contain spaces.
  MOUNT_DIR="$(hdiutil attach "$DMG_RW" -nobrowse -noverify | tail -1 | awk -F '\t' 'NF>=3 {print $3}')"
  if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
    echo "Warning: Failed to mount DMG for layout customization; skipping."
  else
    OSA_OK=0

    if command -v timeout >/dev/null 2>&1; then
      timeout 30 osascript <<APPLESCRIPT && OSA_OK=1 || true
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {120, 120, 900, 560}
    set opts to icon view options of container window
    set icon size of opts to 128
    set text size of opts to 14
    set arrangement of opts to not arranged
    set position of item "${APP_NAME}.app" of container window to {220, 260}
    set position of item "Applications" of container window to {560, 260}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
    else
      echo "Notice: 'timeout' not found; running osascript without timeout."
      osascript <<APPLESCRIPT && OSA_OK=1 || true
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {120, 120, 900, 560}
    set opts to icon view options of container window
    set icon size of opts to 128
    set text size of opts to 14
    set arrangement of opts to not arranged
    set position of item "${APP_NAME}.app" of container window to {220, 260}
    set position of item "Applications" of container window to {560, 260}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
    fi

    if [[ "$OSA_OK" -eq 0 ]]; then
      echo "Warning: Finder layout customization failed; skipping."
    fi

    sync
    sleep 1
    hdiutil detach "$MOUNT_DIR" -quiet
  fi

  # Convert to compressed read-only DMG.
  hdiutil convert "$DMG_RW" -format UDZO -o "$DMG_PATH" >/dev/null
  rm -f "$DMG_RW"

  echo "Signing DMG…"
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

  echo "Notarizing DMG…"
  submit_notarization "$DMG_PATH" "DMG"

  echo "Stapling DMG…"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

echo "Done."
