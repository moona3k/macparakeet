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
#
# Outputs:
#   dist/MacParakeet.app (signed + stapled)
#   dist/MacParakeet.dmg (signed + stapled) if CREATE_DMG=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_NAME="${APP_NAME:-MacParakeet}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_PATH="$DIST_DIR/${APP_NAME}.app"

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Daniel Moon (FYAF2ZD7RM)}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"
CREATE_DMG="${CREATE_DMG:-1}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Missing app bundle: $APP_PATH" >&2
  echo "Run: $ROOT_DIR/scripts/dist/build_app_bundle.sh" >&2
  exit 1
fi

echo "[1/8] Clearing extended attributes…"
xattr -cr "$APP_PATH" || true

echo "[2/8] Signing nested executables (if any)…"
# Sign inside-out. Helper binaries under Resources must be signed for notarization.
NODE_RUNTIME_ENTITLEMENTS="$ROOT_DIR/scripts/dist/NodeRuntime.entitlements"
while IFS= read -r -d '' bin; do
  base="$(basename "$bin")"
  echo "Signing: $bin"
  if [[ "$base" == "node" || "$base" == "node-arm64" || "$base" == "node-x86_64" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
      --entitlements "$NODE_RUNTIME_ENTITLEMENTS" "$bin"
  else
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$bin"
  fi
done < <(
  find "$APP_PATH/Contents/Resources" -maxdepth 1 -type f -perm -111 \
    \( -name "ffmpeg" -o -name "node" -o -name "node-arm64" -o -name "node-x86_64" \) -print0 2>/dev/null || true
)

ENTITLEMENTS="$ROOT_DIR/scripts/dist/MacParakeet.entitlements"

echo "[3/8] Codesigning app (hardened runtime + entitlements)…"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" "$APP_PATH"

echo "[4/8] Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

ZIP_PATH="$DIST_DIR/${APP_NAME}.app.zip"
rm -f "$ZIP_PATH"

echo "[5/8] Creating notarization zip…"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

if [[ -z "$NOTARYTOOL_PROFILE" ]]; then
  echo "NOTARYTOOL_PROFILE not set; skipping notarization."
  exit 0
fi

echo "[6/8] Submitting to notarization service…"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait

echo "[7/8] Stapling app…"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "[8/8] Gatekeeper assess…"
spctl --assess --type execute --verbose=4 "$APP_PATH" || true

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
  MOUNT_DIR="$(hdiutil attach "$DMG_RW" -nobrowse -noverify | tail -1 | awk '{print $NF}')"
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
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait

  echo "Stapling DMG…"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

echo "Done."
