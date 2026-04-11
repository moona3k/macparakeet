#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/.build/xcode-dev"
PRODUCT_DIR="$DERIVED_DATA_DIR/Build/Products/Debug"
APP_BIN="$PRODUCT_DIR/MacParakeet"
APP_BUNDLE="$PRODUCT_DIR/MacParakeet-Dev.app"
LOG_FILE="${TMPDIR:-/tmp}/macparakeet-dev.log"
BUILD_LOG_FILE="${TMPDIR:-/tmp}/macparakeet-dev-build.log"
APP_MACOS_BIN="$APP_BUNDLE/Contents/MacOS/MacParakeet"

pick_codesign_identity() {
  local preferred="${MACPARAKEET_CODESIGN_IDENTITY:-}"
  if [[ -n "$preferred" ]]; then
    printf '%s\n' "$preferred"
    return
  fi

  local identities
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

  while IFS= read -r candidate; do
    if grep -Fq "\"$candidate" <<<"$identities"; then
      printf '%s\n' "$candidate"
      return
    fi
  done < <(printf '%s\n' "Apple Development" "Mac Development")

  local developer_id
  developer_id="$(sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p' <<<"$identities" | head -n 1)"
  if [[ -n "$developer_id" ]]; then
    printf '%s\n' "$developer_id"
    return
  fi

  # Ad-hoc signing keeps the bundle launchable even on machines without a
  # development certificate. It is enough for local debugging, but TCC may be
  # less sticky across rebuilds than a real signing identity.
  printf '%s\n' "-"
}

CODESIGN_IDENTITY="$(pick_codesign_identity)"

sync_frameworks_into_bundle() {
  local source_dir="$1"
  local bundle_fw_dir="$2"

  [[ -d "$source_dir" ]] || return 0

  for fw in "$source_dir"/*.framework; do
    [[ -e "$fw" ]] || continue
    local fw_name
    local resolved_fw
    fw_name="$(basename "$fw")"
    resolved_fw="$(realpath "$fw")"
    rm -rf "$bundle_fw_dir/$fw_name"
    rsync -a --delete "$resolved_fw/" "$bundle_fw_dir/$fw_name/"
  done
}

echo "[1/5] Building debug app bundle (xcodebuild, target signing disabled)…"
if ! xcodebuild build \
  -scheme MacParakeet \
  -configuration Debug \
  -destination "platform=OS X,arch=arm64" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO >"$BUILD_LOG_FILE" 2>&1; then
  echo "xcodebuild failed. Last 120 log lines from $BUILD_LOG_FILE:" >&2
  tail -n 120 "$BUILD_LOG_FILE" >&2 || true
  exit 1
fi

if [[ ! -x "$APP_BIN" ]]; then
  echo "Build succeeded but app binary not found at: $APP_BIN" >&2
  exit 1
fi

# The raw xcodebuild product carries an absolute rpath into
# $PRODUCT_DIR/PackageFrameworks. Keep that layout available before we rewrite
# the wrapped app binary to use bundle-local Frameworks.
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
cp -f "$APP_BIN" "$APP_MACOS_BIN"

# Copy resource bundle (contains discover-fallback.json etc.)
RESOURCE_BUNDLE="$PRODUCT_DIR/MacParakeet_MacParakeet.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
  mkdir -p "$RESOURCES_DIR"
  rsync -a --delete "$RESOURCE_BUNDLE" "$RESOURCES_DIR/"
fi

# Copy frameworks into the bundle so dyld loads only bundle-local paths.
BUNDLE_FW_DIR="$APP_BUNDLE/Contents/Frameworks"
rm -rf "$BUNDLE_FW_DIR"
mkdir -p "$BUNDLE_FW_DIR"
sync_frameworks_into_bundle "$PRODUCT_DIR" "$BUNDLE_FW_DIR"
sync_frameworks_into_bundle "$PKGFW_DIR" "$BUNDLE_FW_DIR"

# The xcodebuild-produced binary carries an absolute PackageFrameworks rpath that
# works in-place but fails once the app is launched as a signed bundle. Rewrite
# it to use the embedded Frameworks directory instead.
install_name_tool -delete_rpath "$PKGFW_DIR" "$APP_MACOS_BIN" 2>/dev/null || true
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_MACOS_BIN" 2>/dev/null || true

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
    <key>NSAudioCaptureUsageDescription</key>
    <string>MacParakeet needs system audio recording access for meeting recording.</string>
</dict>
</plist>
PLIST

# Re-sign the bundle so TCC can identify the dev build consistently.
codesign --force --sign "$CODESIGN_IDENTITY" --deep "$APP_BUNDLE"

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
echo "  codesign: $CODESIGN_IDENTITY"
echo "  log: $LOG_FILE"
echo "  build-log: $BUILD_LOG_FILE"
if [[ -n "$INSTALLED_PID" ]]; then
  echo "  warning: /Applications/MacParakeet.app is also running (pid $INSTALLED_PID)"
fi
