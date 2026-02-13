#!/usr/bin/env bash
set -euo pipefail

# Build a distributable MacParakeet.app bundle from the SwiftPM executable.
#
# This script:
# - builds the `MacParakeet` SwiftPM product in Release
# - assembles a minimal .app bundle (Info.plist + executable + bundled python package)
# - optionally bundles `uv` and `node` into Resources (downloading if needed)
#
# Outputs:
#   dist/MacParakeet.app
#
# Environment variables:
#   APP_NAME            (default: MacParakeet)
#   BUNDLE_ID           (default: com.macparakeet.MacParakeet)
#   VERSION             (default: 0.1.0)
#   BUILD_NUMBER        (default: 1)
#   MIN_MACOS_VERSION   (default: 14.2)
#   UNIVERSAL           (default: 0) build universal (arm64+x86_64) if 1
#   SKIP_BUILD          (default: 0) reuse existing Release binary if 1
#   BUILD_SYSTEM        (default: xcodebuild) 'xcodebuild' or 'swiftpm'
#   XCODE_DERIVED_DATA  (default: .build/xcode-dist) derived data path for xcodebuild
#   BUNDLE_NODE        (default: 1) bundle Node runtime for yt-dlp
#   NODE_VERSION       (default: 24.13.1) Node version used when downloading

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"

APP_NAME="${APP_NAME:-MacParakeet}"
BUNDLE_ID="${BUNDLE_ID:-com.macparakeet.MacParakeet}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-14.2}"
UNIVERSAL="${UNIVERSAL:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
BUILD_SYSTEM="${BUILD_SYSTEM:-xcodebuild}"
XCODE_DERIVED_DATA="${XCODE_DERIVED_DATA:-$ROOT_DIR/.build/xcode-dist}"

APP_DIR="$DIST_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

build_swiftpm() {
  if [[ "$SKIP_BUILD" == "1" ]]; then
    echo "[1/4] Skipping build (SKIP_BUILD=1)…"
    return 0
  fi

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
}

build_xcodebuild() {
  # Prefer xcodebuild so SwiftPM resource bundles are produced (notably mlx-swift_Cmlx.bundle with default.metallib).
  if [[ "$SKIP_BUILD" == "1" ]]; then
    echo "[1/4] Skipping build (SKIP_BUILD=1)…"
    return 0
  fi

  if [[ "$UNIVERSAL" == "1" ]]; then
    echo "[1/4] Building via xcodebuild (universal Release)…"
    local dd_arm="$XCODE_DERIVED_DATA-arm64"
    local dd_x86="$XCODE_DERIVED_DATA-x86_64"

    xcodebuild build -scheme MacParakeet -configuration Release -destination "platform=OS X,arch=arm64" \
      -derivedDataPath "$dd_arm" CODE_SIGNING_ALLOWED=NO >/dev/null
    xcodebuild build -scheme MacParakeet -configuration Release -destination "platform=OS X,arch=x86_64" \
      -derivedDataPath "$dd_x86" CODE_SIGNING_ALLOWED=NO >/dev/null

    local bin_arm="$dd_arm/Build/Products/Release/MacParakeet"
    local bin_x86="$dd_x86/Build/Products/Release/MacParakeet"
    if [[ ! -f "$bin_arm" || ! -f "$bin_x86" ]]; then
      echo "Failed to locate xcodebuild Release binaries." >&2
      exit 1
    fi

    lipo -create "$bin_arm" "$bin_x86" -output "$MACOS_DIR/$APP_NAME"
    chmod +x "$MACOS_DIR/$APP_NAME"

    # Copy resource bundles from arm build output (they are data-only).
    local product_dir="$dd_arm/Build/Products/Release"
    copy_resource_bundles "$product_dir"
  else
    echo "[1/4] Building via xcodebuild (Release)…"
    local dd="$XCODE_DERIVED_DATA"
    # Apple Silicon is the supported shipping target; lock to arm64 to avoid ambiguous destinations.
    xcodebuild build -scheme MacParakeet -configuration Release -destination "platform=OS X,arch=arm64" \
      -derivedDataPath "$dd" CODE_SIGNING_ALLOWED=NO >/dev/null

    local product_dir="$dd/Build/Products/Release"
    local bin="$product_dir/MacParakeet"
    if [[ ! -f "$bin" ]]; then
      echo "Failed to locate xcodebuild Release binary at: $bin" >&2
      exit 1
    fi

    cp "$bin" "$MACOS_DIR/$APP_NAME"
    chmod +x "$MACOS_DIR/$APP_NAME"

    copy_resource_bundles "$product_dir"
  fi
}

copy_resource_bundles() {
  local product_dir="$1"
  # Copy SwiftPM-generated resource bundles alongside the executable. This is required for some dependencies.
  if [[ -d "$product_dir" ]]; then
    while IFS= read -r -d '' bundle; do
      local name
      name="$(basename "$bundle")"
      rm -rf "$RESOURCES_DIR/$name"
      cp -R "$bundle" "$RESOURCES_DIR/"
    done < <(find "$product_dir" -maxdepth 1 -type d -name '*.bundle' -print0 2>/dev/null || true)
  fi
}

if [[ "$BUILD_SYSTEM" == "swiftpm" ]]; then
  build_swiftpm
  # Locate the release binary produced by SwiftPM.
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
else
  build_xcodebuild
  echo "[2/4] Assembling app bundle…"
fi

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



# Optionally bundle `node` for yt-dlp JavaScript runtime support.
#
# We always download official Node builds here. Homebrew-installed `node`
# links to external dylibs and is not reliably portable inside app bundles.
#
# For universal builds, bundle both arch binaries as `node-arm64` and `node-x86_64`.
BUNDLE_NODE="${BUNDLE_NODE:-1}"
NODE_VERSION="${NODE_VERSION:-24.13.1}"
if [[ "$BUNDLE_NODE" == "1" ]]; then
  echo "Bundling Node.js ${NODE_VERSION}…"
  TMP_NODE="$(mktemp -d)"

  download_node() {
    local asset="$1"
    local out="$2"
    local tarball="$TMP_NODE/$asset"
    local extract_dir="$TMP_NODE/extract"
    local shasums="$TMP_NODE/SHASUMS256.txt"
    curl -LsSf "https://nodejs.org/dist/v${NODE_VERSION}/${asset}" -o "$tarball"
    if [[ ! -f "$shasums" ]]; then
      curl -LsSf "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" -o "$shasums"
    fi
    local expected_sha
    expected_sha="$(awk -v target="$asset" '$2 == target {print $1}' "$shasums" | head -n 1)"
    local actual_sha
    actual_sha="$(shasum -a 256 "$tarball" | awk '{print $1}')"
    if [[ -z "$expected_sha" || "$expected_sha" != "$actual_sha" ]]; then
      echo "Node SHA256 verification failed for $asset" >&2
      exit 1
    fi
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    tar -xzf "$tarball" -C "$extract_dir"
    local node_bin
    node_bin="$(find "$extract_dir" -maxdepth 3 -type f -path '*/bin/node' | head -n 1)"
    if [[ -z "${node_bin:-}" || ! -f "$node_bin" ]]; then
      echo "Failed to locate node binary inside ${asset}" >&2
      exit 1
    fi
    install -m 0755 "$node_bin" "$out"
  }

  if [[ "$UNIVERSAL" == "1" ]]; then
    download_node "node-v${NODE_VERSION}-darwin-arm64.tar.gz" "$RESOURCES_DIR/node-arm64"
    download_node "node-v${NODE_VERSION}-darwin-x64.tar.gz" "$RESOURCES_DIR/node-x86_64"
  else
    ARCH="$(uname -m)"
    if [[ "$ARCH" == "arm64" ]]; then
      NODE_ASSET="node-v${NODE_VERSION}-darwin-arm64.tar.gz"
    else
      NODE_ASSET="node-v${NODE_VERSION}-darwin-x64.tar.gz"
    fi
    download_node "$NODE_ASSET" "$RESOURCES_DIR/node"
  fi

  rm -rf "$TMP_NODE"
else
  echo "Skipping Node bundling (BUNDLE_NODE=0)"
fi

# Copy app icon into Resources.
ICON_SRC="$ROOT_DIR/Assets/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$RESOURCES_DIR/AppIcon.icns"
  echo "Bundled AppIcon.icns"
else
  echo "Error: Assets/AppIcon.icns not found. Cannot build production app without icon." >&2
  exit 1
fi

echo "[3/4] Writing Info.plist…"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
CHECKOUT_URL="${MACPARAKEET_CHECKOUT_URL:-}"
LS_VARIANT_ID="${MACPARAKEET_LS_VARIANT_ID:-}"
LICENSING_PLIST=""
if [[ -n "$CHECKOUT_URL" ]]; then
  LICENSING_PLIST+="  <key>MacParakeetCheckoutURL</key>\n"
  LICENSING_PLIST+="  <string>${CHECKOUT_URL}</string>\n"
fi
if [[ -n "$LS_VARIANT_ID" && "$LS_VARIANT_ID" =~ ^[0-9]+$ ]]; then
  LICENSING_PLIST+="  <key>MacParakeetLemonSqueezyVariantID</key>\n"
  LICENSING_PLIST+="  <integer>${LS_VARIANT_ID}</integer>\n"
fi
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
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
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
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>MacParakeet needs microphone access for dictation.</string>
$(printf "%b" "$LICENSING_PLIST")
</dict>
</plist>
EOF

echo "[4/4] Done: $APP_DIR"
