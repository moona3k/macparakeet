#!/usr/bin/env bash
# Build MacParakeet.app and wrap it in a drag-to-Applications DMG.
#
# The resulting app is self-contained: Node.js, FFmpeg and yt-dlp are bundled
# inside it, so the person installing it needs nothing else. Node.js is only
# required here, on the build machine; if it is missing, a private copy is
# downloaded once into ~/tools/node (nothing is installed system-wide).
#
# Signing:
#   - default: ad hoc. Runs on this Mac (and other Macs after right-click → Open,
#     or `xattr -dr com.apple.quarantine /Applications/MacParakeet.app`).
#   - SIGN_IDENTITY="Developer ID Application: ..." + NOTARYTOOL_PROFILE=...:
#     uses scripts/dist/sign_notarize.sh for a notarized DMG that opens on any Mac
#     without warnings (requires a paid Apple Developer account).
#
# Usage (from the repository root):
#   scripts/dist/make_local_dmg.sh            # version 0.0.0
#   VERSION=1.0.0 scripts/dist/make_local_dmg.sh
#
# Output: dist/MacParakeet.dmg

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

NODE_VERSION="24.13.1"
NODE_DIR="$HOME/tools/node/node-v${NODE_VERSION}-darwin-arm64"
APP="dist/MacParakeet.app"
DMG="dist/MacParakeet.dmg"
VOLUME_NAME="MacParakeet"

# 1. Xcode toolchain (this Mac's default is the Command Line Tools).
if ! xcodebuild -version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  xcodebuild -version >/dev/null 2>&1 || { echo "Xcode not found in /Applications." >&2; exit 1; }
fi

# 2. Node.js for the build only.
if ! command -v npm >/dev/null 2>&1; then
  if [[ ! -x "$NODE_DIR/bin/npm" ]]; then
    echo "[setup] Downloading Node.js $NODE_VERSION for the build (one time)…"
    mkdir -p "$HOME/tools/node"
    curl -fL --progress-bar -o "$HOME/tools/node/node.tar.gz" \
      "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-darwin-arm64.tar.gz"
    tar xzf "$HOME/tools/node/node.tar.gz" -C "$HOME/tools/node"
    rm -f "$HOME/tools/node/node.tar.gz"
  fi
  export PATH="$NODE_DIR/bin:$PATH"
fi

# 3. Build the self-contained app.
echo "[1/3] Building MacParakeet.app…"
scripts/dist/build_app_bundle.sh

# 4. Sign.
if [[ -n "${SIGN_IDENTITY:-}" && -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  echo "[2/3] Signing and notarizing with $SIGN_IDENTITY…"
  CREATE_DMG=1 scripts/dist/sign_notarize.sh
  echo "Done: $DMG (notarized)"
  exit 0
fi

echo "[2/3] Signing ad hoc…"
ENTITLEMENTS="$(mktemp -t mp-ent)"
cp scripts/dist/MacParakeet.entitlements "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS" 2>/dev/null || true
codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" --deep "$APP"
rm -f "$ENTITLEMENTS"
codesign --verify --deep --strict "$APP"

# 5. DMG with an Applications shortcut to drag onto.
echo "[3/3] Creating $DMG…"
STAGE="$(mktemp -d -t mp-dmg)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

echo
echo "Done: $ROOT/$DMG ($(du -h "$DMG" | cut -f1))"
echo "Open it and drag MacParakeet onto Applications."
echo "First launch on another Mac: right-click the app → Open (it is not notarized)."
