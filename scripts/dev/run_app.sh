#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/.build/xcode-dev"
PRODUCT_DIR="$DERIVED_DATA_DIR/Build/Products/Debug"
APP_BIN="$PRODUCT_DIR/MacParakeet"
APP_BUNDLE="$PRODUCT_DIR/MacParakeet-Dev.app"
LOG_FILE="${TMPDIR:-/tmp}/macparakeet-dev.log"

echo "[1/5] Building debug app bundle (xcodebuild)…"
xcodebuild build \
  -scheme MacParakeet \
  -configuration Debug \
  -destination "platform=OS X,arch=arm64" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-FYAF2ZD7RM}" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES >/dev/null

if [[ ! -x "$APP_BIN" ]]; then
  echo "Build succeeded but app binary not found at: $APP_BIN" >&2
  exit 1
fi

# Sparkle.framework is built to $PRODUCT_DIR but the binary's @rpath looks in
# $PRODUCT_DIR/PackageFrameworks. Symlink so dyld can find it at runtime.
PKGFW_DIR="$PRODUCT_DIR/PackageFrameworks"
mkdir -p "$PKGFW_DIR"
if [[ -d "$PRODUCT_DIR/Sparkle.framework" && ! -e "$PKGFW_DIR/Sparkle.framework" ]]; then
  ln -s "$PRODUCT_DIR/Sparkle.framework" "$PKGFW_DIR/Sparkle.framework"
fi

echo "[2/5] Wrapping in .app bundle for macOS permissions…"
# Create a minimal .app bundle so macOS TCC (Accessibility, Microphone) can
# identify and remember permissions for the dev build across rebuilds.
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
mkdir -p "$MACOS_DIR"
cp -f "$APP_BIN" "$MACOS_DIR/MacParakeet"

# Copy resource bundle (contains discover-fallback.json etc.)
RESOURCE_BUNDLE="$PRODUCT_DIR/MacParakeet_MacParakeet.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
  mkdir -p "$RESOURCES_DIR"
  rsync -a --delete "$RESOURCE_BUNDLE" "$RESOURCES_DIR/"
fi

# Symlink frameworks into the bundle so dyld @rpath resolves
BUNDLE_FW_DIR="$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$BUNDLE_FW_DIR"
for fw in "$PRODUCT_DIR"/*.framework; do
  [[ -d "$fw" ]] || continue
  fw_name="$(basename "$fw")"
  if [[ ! -e "$BUNDLE_FW_DIR/$fw_name" ]]; then
    ln -s "$fw" "$BUNDLE_FW_DIR/$fw_name"
  fi
done
# Also link PackageFrameworks for SPM module frameworks
BUNDLE_PKGFW_DIR="$MACOS_DIR/../Frameworks/PackageFrameworks"
mkdir -p "$BUNDLE_PKGFW_DIR"
for fw in "$PKGFW_DIR"/*.framework; do
  [[ -d "$fw" ]] || continue
  fw_name="$(basename "$fw")"
  if [[ ! -e "$BUNDLE_PKGFW_DIR/$fw_name" ]]; then
    ln -s "$fw" "$BUNDLE_PKGFW_DIR/$fw_name"
  fi
done

cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.macparakeet.dev</string>
    <key>CFBundleName</key>
    <string>MacParakeet Dev</string>
    <key>CFBundleExecutable</key>
    <string>MacParakeet</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.0.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>MacParakeet needs microphone access for voice dictation.</string>
</dict>
</plist>
PLIST

# Re-sign the bundle with entitlements so TCC trusts it and Core Audio Taps work
DEV_ENTITLEMENTS="$ROOT_DIR/scripts/dist/MacParakeet.entitlements"
SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep 'Apple Development' | head -1 | awk '{print $2}')"
# Sign frameworks first
find "$APP_BUNDLE/Contents/Frameworks" -name "*.framework" -maxdepth 2 -exec \
  codesign --force --sign "$SIGN_IDENTITY" {} \; 2>/dev/null || true
# Sign the main executable with entitlements
codesign --force --sign "$SIGN_IDENTITY" --entitlements "$DEV_ENTITLEMENTS" "$APP_BUNDLE" 2>/dev/null || true

echo "[3/5] Stopping existing MacParakeet processes…"
pkill -f "/Applications/MacParakeet.app/Contents/MacOS/MacParakeet" || true
pkill -f "$ROOT_DIR/dist/MacParakeet.app/Contents/MacOS/MacParakeet" || true
pkill -f "MacParakeet-Dev.app/Contents/MacOS/MacParakeet" || true
pkill -f "$DERIVED_DATA_DIR/Build/Products/Debug/MacParakeet" || true
pkill -f "$ROOT_DIR/.build/debug/MacParakeet" || true
pkill -f "$ROOT_DIR/.build/arm64-apple-macosx/debug/MacParakeet" || true
sleep 1

GIT_COMMIT="$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
BUILD_DATE_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BUILD_SOURCE="dev-run-xcodebuild-debug"

echo "[4/5] Launching debug app…"
MACPARAKEET_GIT_COMMIT="$GIT_COMMIT" \
MACPARAKEET_BUILD_DATE_UTC="$BUILD_DATE_UTC" \
MACPARAKEET_BUILD_SOURCE="$BUILD_SOURCE" \
nohup open "$APP_BUNDLE" --env MACPARAKEET_GIT_COMMIT="$GIT_COMMIT" \
  --env MACPARAKEET_BUILD_DATE_UTC="$BUILD_DATE_UTC" \
  --env MACPARAKEET_BUILD_SOURCE="$BUILD_SOURCE" >"$LOG_FILE" 2>&1 &

sleep 2
PID="$(pgrep -f "MacParakeet-Dev.app/Contents/MacOS/MacParakeet" | head -n 1 || true)"
INSTALLED_PID="$(pgrep -f "/Applications/MacParakeet.app/Contents/MacOS/MacParakeet" | head -n 1 || true)"

echo "[5/5] Running"
echo "  pid: ${PID:-unknown}"
echo "  bundle: $APP_BUNDLE"
echo "  source: $BUILD_SOURCE"
echo "  commit: $GIT_COMMIT"
echo "  built-at: $BUILD_DATE_UTC"
echo "  log: $LOG_FILE"
if [[ -n "$INSTALLED_PID" ]]; then
  echo "  warning: /Applications/MacParakeet.app is also running (pid $INSTALLED_PID)"
fi
