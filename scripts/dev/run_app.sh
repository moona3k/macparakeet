#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/.build/xcode-dev"
PRODUCT_DIR="$DERIVED_DATA_DIR/Build/Products/Debug"
APP_BIN="$PRODUCT_DIR/MacParakeet"
LOG_FILE="${TMPDIR:-/tmp}/macparakeet-dev.log"

echo "[1/4] Building debug app bundle (xcodebuild)…"
xcodebuild build \
  -scheme MacParakeet \
  -configuration Debug \
  -destination "platform=OS X,arch=arm64" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGNING_ALLOWED=NO >/dev/null

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

echo "[2/4] Stopping existing MacParakeet processes…"
pkill -f "/Applications/MacParakeet.app/Contents/MacOS/MacParakeet" || true
pkill -f "$ROOT_DIR/dist/MacParakeet.app/Contents/MacOS/MacParakeet" || true
pkill -f "$DERIVED_DATA_DIR/Build/Products/Debug/MacParakeet" || true
pkill -f "$ROOT_DIR/.build/debug/MacParakeet" || true
pkill -f "$ROOT_DIR/.build/arm64-apple-macosx/debug/MacParakeet" || true
sleep 1

GIT_COMMIT="$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
BUILD_DATE_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BUILD_SOURCE="dev-run-xcodebuild-debug"

echo "[3/4] Launching debug app…"
MACPARAKEET_GIT_COMMIT="$GIT_COMMIT" \
MACPARAKEET_BUILD_DATE_UTC="$BUILD_DATE_UTC" \
MACPARAKEET_BUILD_SOURCE="$BUILD_SOURCE" \
nohup "$APP_BIN" >"$LOG_FILE" 2>&1 &

sleep 1
PID="$(pgrep -f "$DERIVED_DATA_DIR/Build/Products/Debug/MacParakeet" | head -n 1 || true)"
INSTALLED_PID="$(pgrep -f "/Applications/MacParakeet.app/Contents/MacOS/MacParakeet" | head -n 1 || true)"

echo "[4/4] Running"
echo "  pid: ${PID:-unknown}"
echo "  source: $BUILD_SOURCE"
echo "  commit: $GIT_COMMIT"
echo "  built-at: $BUILD_DATE_UTC"
echo "  log: $LOG_FILE"
if [[ -n "$INSTALLED_PID" ]]; then
  echo "  warning: /Applications/MacParakeet.app is also running (pid $INSTALLED_PID)"
fi
