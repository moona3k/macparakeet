#!/usr/bin/env bash
set -euo pipefail

# Build a release-quality MacParakeet.app, ad-hoc sign it correctly, and
# install it to /Applications/MacParakeet.app — replacing the current
# install (which is backed up to a timestamped folder for rollback).
#
# Use this when you want the latest code from `main` to be the version
# that opens from Spotlight / Finder / "Open With" dialogs on your Mac.
#
# This is the local-only path. For production releases use the proper
# `build_app_bundle.sh` + `sign_notarize.sh` flow with a Developer ID cert.
#
# Why ad-hoc signing matters: an app with only the linker's default
# signature has an unstable identifier ("MacParakeet" instead of
# "com.macparakeet.MacParakeet") and no sealed resources. macOS TCC
# refuses to persistently grant Accessibility permission to such bundles,
# and Keychain rejects API key writes because the ACL can't bind to a
# stable signature. Proper inside-out ad-hoc signing fixes both.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DEST="/Applications/MacParakeet.app"
ENTITLEMENTS="$ROOT_DIR/scripts/dist/MacParakeet.entitlements"

# 1. Build the release bundle (downloads helpers on first run, fast after).
VERSION="${VERSION:-0.6.7-dev}" \
BUILD_SOURCE="${BUILD_SOURCE:-dist-local-installed}" \
    "$ROOT_DIR/scripts/dist/build_app_bundle.sh"

SRC_APP="$ROOT_DIR/dist/MacParakeet.app"
if [[ ! -d "$SRC_APP" ]]; then
    echo "build produced no $SRC_APP — aborting" >&2
    exit 1
fi

# 2. Ad-hoc sign inside-out. Each bundled helper, then framework, then app.
echo "Signing bundled binaries..."
for helper in ffmpeg yt-dlp node macparakeet-cli; do
    target="$SRC_APP/Contents/Resources/$helper"
    [[ -f "$target" ]] || target="$SRC_APP/Contents/MacOS/$helper"
    if [[ -f "$target" ]]; then
        codesign --force --sign - "$target"
    fi
done

if [[ -d "$SRC_APP/Contents/Frameworks/Sparkle.framework" ]]; then
    codesign --force --sign - "$SRC_APP/Contents/Frameworks/Sparkle.framework"
fi

echo "Signing main app..."
codesign --force --sign - \
    --identifier com.macparakeet.MacParakeet \
    --entitlements "$ENTITLEMENTS" \
    "$SRC_APP"

codesign --verify --deep --strict "$SRC_APP"
echo "Signature OK."

# 3. Stop any running instance.
pkill -x MacParakeet 2>/dev/null || true
sleep 1

# 4. Back up existing install (rename, don't delete — easy rollback).
if [[ -d "$APP_DEST" ]]; then
    ts="$(date +%Y%m%d-%H%M%S)"
    backup="/Applications/MacParakeet-backup-$ts.app"
    echo "Moving existing $APP_DEST → $backup"
    mv "$APP_DEST" "$backup"
fi

# 5. Install fresh build, clear quarantine, launch.
cp -R "$SRC_APP" "$APP_DEST"
xattr -cr "$APP_DEST"
echo "Installed: $APP_DEST"
codesign -dv "$APP_DEST" 2>&1 | grep -E "Identifier|Signature|Sealed" || true

open "$APP_DEST"
echo "Launched."
echo
echo "Reminder: the new code signature is treated as a new app by macOS."
echo "Re-grant Accessibility permission once in System Settings → Privacy & Security."
echo "API keys saved under the previous signature are not readable; re-enter them once."
