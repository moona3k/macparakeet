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

echo "[2/8] Codesigning (hardened runtime)…"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP_PATH"

echo "[3/8] Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

ZIP_PATH="$DIST_DIR/${APP_NAME}.app.zip"
rm -f "$ZIP_PATH"

echo "[4/8] Creating notarization zip…"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

if [[ -z "$NOTARYTOOL_PROFILE" ]]; then
  echo "NOTARYTOOL_PROFILE not set; skipping notarization."
  exit 0
fi

echo "[5/8] Submitting to notarization service…"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait

echo "[6/8] Stapling app…"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "[7/8] Gatekeeper assess…"
spctl --assess --type execute --verbose=4 "$APP_PATH" || true

if [[ "$CREATE_DMG" == "1" ]]; then
  DMG_PATH="$DIST_DIR/${APP_NAME}.dmg"
  rm -f "$DMG_PATH"

  echo "[8/8] Creating DMG…"
  hdiutil create -volname "$APP_NAME" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH" >/dev/null

  echo "Signing DMG…"
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

  echo "Notarizing DMG…"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait

  echo "Stapling DMG…"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

echo "Done."

