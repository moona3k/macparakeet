#!/usr/bin/env bash
set -euo pipefail

# Build a distributable MacParakeet.app bundle from the SwiftPM executable.
#
# This script:
# - builds the `MacParakeet` SwiftPM product in Release
# - assembles a minimal .app bundle (Info.plist + executable + bundled python package)
# - optionally bundles `uv` into Resources if it's available on PATH
#
# Outputs:
#   app/dist/MacParakeet.app
#
# Environment variables:
#   APP_NAME            (default: MacParakeet)
#   BUNDLE_ID           (default: com.macparakeet.MacParakeet)
#   VERSION             (default: 0.1.0)
#   BUILD_NUMBER        (default: 1)
#   MIN_MACOS_VERSION   (default: 14.2)
#   UNIVERSAL           (default: 0) build universal (arm64+x86_64) if 1
#   SKIP_BUILD          (default: 0) reuse existing Release binary if 1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
TEMPLATE_DIR="$ROOT_DIR/scripts/dist"

APP_NAME="${APP_NAME:-MacParakeet}"
BUNDLE_ID="${BUNDLE_ID:-com.macparakeet.MacParakeet}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-14.2}"
UNIVERSAL="${UNIVERSAL:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"

APP_DIR="$DIST_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

if [[ "$SKIP_BUILD" == "1" ]]; then
  echo "[1/4] Skipping build (SKIP_BUILD=1)…"
else
  if [[ "$UNIVERSAL" == "1" ]]; then
    echo "[1/4] Building SwiftPM product (universal Release)…"
  else
    echo "[1/4] Building SwiftPM product (Release)…"
  fi
  pushd "$ROOT_DIR" >/dev/null
  if [[ "$UNIVERSAL" == "1" ]]; then
    swift build -c release --arch arm64 --arch x86_64 --product MacParakeet
  else
    swift build -c release --product MacParakeet
  fi
  popd >/dev/null
fi

pushd "$ROOT_DIR" >/dev/null
BIN_DIR="$(swift build -c release --product MacParakeet --show-bin-path)"
popd >/dev/null
BIN_PATH="$BIN_DIR/MacParakeet"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "Failed to locate Release binary at: $BIN_PATH" >&2
  exit 1
fi

echo "[2/4] Assembling app bundle…"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

# Bundle the python package sources (needed for `python -m macparakeet_stt`).
mkdir -p "$RESOURCES_DIR/python"
rsync -a --delete \
  --exclude "__pycache__/" \
  --exclude ".venv/" \
  "$ROOT_DIR/python/" "$RESOURCES_DIR/python/"

# Optionally bundle `uv` for first-run setup (PythonBootstrap prefers bundled uv).
#
# For universal builds, bundle both arch binaries as `uv-arm64` and `uv-x86_64`.
UV_VERSION="${UV_VERSION:-0.9.21}"
if command -v uv >/dev/null 2>&1; then
  UV_PATH="$(command -v uv)"
  cp "$UV_PATH" "$RESOURCES_DIR/uv"
  chmod +x "$RESOURCES_DIR/uv"
  echo "Bundled uv from: $UV_PATH"
else
  echo "uv not found on PATH; downloading uv ${UV_VERSION}…"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT

  download_uv() {
    local asset="$1"
    local out="$2"
    local tarball="$TMP/$asset"
    curl -LsSf "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${asset}" -o "$tarball"
    rm -rf "$TMP/extract"
    mkdir -p "$TMP/extract"
    tar -xzf "$tarball" -C "$TMP/extract"
    local uv_bin
    uv_bin="$(find "$TMP/extract" -maxdepth 2 -type f -name uv | head -n 1)"
    if [[ -z "${uv_bin:-}" || ! -f "$uv_bin" ]]; then
      echo "Failed to locate uv binary inside ${asset}" >&2
      exit 1
    fi
    install -m 0755 "$uv_bin" "$out"
  }

  if [[ "$UNIVERSAL" == "1" ]]; then
    download_uv "uv-aarch64-apple-darwin.tar.gz" "$RESOURCES_DIR/uv-arm64"
    download_uv "uv-x86_64-apple-darwin.tar.gz" "$RESOURCES_DIR/uv-x86_64"
  else
    ARCH="$(uname -m)"
    if [[ "$ARCH" == "arm64" ]]; then
      UV_ASSET="uv-aarch64-apple-darwin.tar.gz"
    else
      UV_ASSET="uv-x86_64-apple-darwin.tar.gz"
    fi
    download_uv "$UV_ASSET" "$RESOURCES_DIR/uv"
  fi
fi

echo "[3/4] Writing Info.plist…"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
cat >"$INFO_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_MACOS_VERSION}</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>MacParakeet needs microphone access for dictation.</string>
</dict>
</plist>
EOF

echo "[4/4] Done: $APP_DIR"
