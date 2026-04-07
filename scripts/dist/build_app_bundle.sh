#!/usr/bin/env bash
set -euo pipefail

# Build a distributable MacParakeet.app bundle from the SwiftPM executable.
#
# This script:
# - builds the `MacParakeet` SwiftPM product in Release
# - assembles a minimal .app bundle (Info.plist + executable + bundled helper binaries)
# - bundles FFmpeg into Resources and optionally bundles `node` for yt-dlp JS runtime support
#
# Outputs:
#   dist/MacParakeet.app
#
# Environment variables:
#   APP_NAME            (default: MacParakeet)
#   BUNDLE_ID           (default: com.macparakeet.MacParakeet)
#   VERSION             (default: 0.1.0)
#   BUILD_NUMBER        (default: UTC timestamp, e.g. 20260213220512)
#   BUILD_GIT_COMMIT    (default: current git short SHA)
#   BUILD_DATE_UTC      (default: current UTC ISO-8601 timestamp)
#   BUILD_SOURCE        (default: dist-<build-system>-release)
#   MIN_MACOS_VERSION   (default: 14.2)
#   UNIVERSAL           (default: 0) build universal (arm64+x86_64) if 1
#   SKIP_BUILD          (default: 0) reuse existing Release binary if 1
#   BUILD_SYSTEM        (default: xcodebuild) 'xcodebuild' or 'swiftpm'
#   XCODE_DERIVED_DATA  (default: .build/xcode-dist) derived data path for xcodebuild
#   FFMPEG_PATH         (default: auto-download static build) source ffmpeg binary to bundle
#   FFMPEG_VERSION      (default: release) 'release' or 'snapshot' from ffmpeg.martin-riedl.de
#   ALLOW_NON_PORTABLE_FFMPEG (default: 0) allow bundling ffmpeg with non-system dylib deps
#   BUNDLE_NODE        (default: 1) bundle Node runtime for yt-dlp
#   NODE_VERSION       (default: 24.13.1) Node version used when downloading

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"

APP_NAME="${APP_NAME:-MacParakeet}"
BUNDLE_ID="${BUNDLE_ID:-com.macparakeet.MacParakeet}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"
BUILD_GIT_COMMIT="${BUILD_GIT_COMMIT:-$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)}"
BUILD_DATE_UTC="${BUILD_DATE_UTC:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-14.2}"
UNIVERSAL="${UNIVERSAL:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
BUILD_SYSTEM="${BUILD_SYSTEM:-xcodebuild}"
BUILD_SOURCE="${BUILD_SOURCE:-dist-${BUILD_SYSTEM}-release}"
XCODE_DERIVED_DATA="${XCODE_DERIVED_DATA:-$ROOT_DIR/.build/xcode-dist}"

APP_DIR="$DIST_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

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

# Bundle FFmpeg (required at runtime for media demux/conversion).
#
# By default, downloads a statically-linked build from ffmpeg.martin-riedl.de.
# Override with FFMPEG_PATH to use your own binary.
FFMPEG_VERSION="${FFMPEG_VERSION:-release}"
ALLOW_NON_PORTABLE_FFMPEG="${ALLOW_NON_PORTABLE_FFMPEG:-0}"

download_static_ffmpeg() {
  local version_type="$1"  # "release" or "snapshot"
  local out="$2"
  local base_url="https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/${version_type}"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local zip_path="$tmp_dir/ffmpeg.zip"

  echo "Downloading static FFmpeg (${version_type}) from ffmpeg.martin-riedl.de…"
  curl -LsSf "${base_url}/ffmpeg.zip" -o "$zip_path"

  # Verify checksum. The redirect resolves to a versioned URL; fetch the
  # .sha256 file from the same resolved location.
  local resolved_url
  resolved_url="$(curl -LsS -o /dev/null -w "%{url_effective}" "${base_url}/ffmpeg.zip")"
  local expected_sha
  expected_sha="$(curl -LsSf "${resolved_url}.sha256" | awk '{print $1}')"
  local actual_sha
  actual_sha="$(shasum -a 256 "$zip_path" | awk '{print $1}')"

  if [[ -z "$expected_sha" || "$expected_sha" != "$actual_sha" ]]; then
    echo "Error: FFmpeg SHA256 verification failed." >&2
    echo "  Expected: $expected_sha" >&2
    echo "  Actual:   $actual_sha" >&2
    rm -rf "$tmp_dir"
    exit 1
  fi
  echo "SHA256 verified: $actual_sha"

  unzip -o -q "$zip_path" -d "$tmp_dir/extract"
  local ffmpeg_bin="$tmp_dir/extract/ffmpeg"
  if [[ ! -f "$ffmpeg_bin" ]]; then
    echo "Error: ffmpeg not found inside downloaded zip." >&2
    rm -rf "$tmp_dir"
    exit 1
  fi

  install -m 0755 "$ffmpeg_bin" "$out"
  rm -rf "$tmp_dir"
}

if [[ -n "${FFMPEG_PATH:-}" ]]; then
  # User provided a custom FFmpeg binary.
  if [[ ! -x "$FFMPEG_PATH" ]]; then
    echo "Error: FFMPEG_PATH not executable: $FFMPEG_PATH" >&2
    exit 1
  fi
  cp "$FFMPEG_PATH" "$RESOURCES_DIR/ffmpeg"
  chmod +x "$RESOURCES_DIR/ffmpeg"
  echo "Bundled FFmpeg from: $FFMPEG_PATH"
else
  # Download static FFmpeg (no Homebrew dependencies).
  download_static_ffmpeg "$FFMPEG_VERSION" "$RESOURCES_DIR/ffmpeg"
  echo "Bundled static FFmpeg ($FFMPEG_VERSION)"
fi

# Guard against accidentally bundling Homebrew-linked ffmpeg, which depends on
# external Cellar dylibs and is not portable across machines.
if [[ "$ALLOW_NON_PORTABLE_FFMPEG" != "1" ]] && command -v otool >/dev/null 2>&1; then
  NON_SYSTEM_DEPS="$(otool -L "$RESOURCES_DIR/ffmpeg" | tail -n +2 | awk '{print $1}' | grep -Ev '^/System/Library/|^/usr/lib/' | grep -Ev '^\(' || true)"
  if [[ -n "$NON_SYSTEM_DEPS" ]]; then
    echo "Error: bundled ffmpeg has non-system dylib dependencies and is not portable:" >&2
    echo "$NON_SYSTEM_DEPS" >&2
    echo "Use the default auto-download (remove FFMPEG_PATH), provide a static build, or set ALLOW_NON_PORTABLE_FFMPEG=1 to override." >&2
    exit 1
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

# Embed Sparkle.framework for auto-updates.
#
# Sparkle is linked via @rpath and must live in Contents/Frameworks/.
# For xcodebuild, the framework is produced in the derived-data product dir.
# For SwiftPM, it's in .build/<triple>/release/.
echo "Embedding Sparkle.framework…"
SPARKLE_FW=""
if [[ "$BUILD_SYSTEM" == "xcodebuild" ]]; then
  SPARKLE_FW="$XCODE_DERIVED_DATA/Build/Products/Release/PackageFrameworks/Sparkle.framework"
  # Fallback: xcodebuild may place it differently
  if [[ ! -d "$SPARKLE_FW" ]]; then
    SPARKLE_FW="$(find "$XCODE_DERIVED_DATA" -type d -name "Sparkle.framework" -path "*/Release/*" 2>/dev/null | head -n 1)"
  fi
else
  SPARKLE_FW="$(find "$ROOT_DIR/.build" -type d -name "Sparkle.framework" -not -path "*/artifacts/*" 2>/dev/null | head -n 1)"
fi

if [[ -z "$SPARKLE_FW" || ! -d "$SPARKLE_FW" ]]; then
  # Last resort: use the xcframework artifact directly
  SPARKLE_FW="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
fi

if [[ -d "$SPARKLE_FW" ]]; then
  rm -rf "$FRAMEWORKS_DIR/Sparkle.framework"
  cp -R "$SPARKLE_FW" "$FRAMEWORKS_DIR/"
  echo "Embedded Sparkle.framework from: $SPARKLE_FW"

  # Ensure the binary's rpath includes Contents/Frameworks/ (standard macOS location).
  # xcodebuild may set @executable_path/../lib instead.
  BINARY="$MACOS_DIR/$APP_NAME"
  if ! otool -l "$BINARY" | grep -q '@executable_path/../Frameworks'; then
    echo "Adding @executable_path/../Frameworks to rpath…"
    install_name_tool -add_rpath @executable_path/../Frameworks "$BINARY"
  fi
else
  echo "Error: Sparkle.framework not found — app will crash at launch without it." >&2
  echo "Searched:" >&2
  echo "  $XCODE_DERIVED_DATA/Build/Products/Release/PackageFrameworks/Sparkle.framework" >&2
  echo "  $XCODE_DERIVED_DATA (find)" >&2
  echo "  $ROOT_DIR/.build (find)" >&2
  echo "  $ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" >&2
  exit 1
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
  <key>MacParakeetBuildDateUTC</key>
  <string>${BUILD_DATE_UTC}</string>
  <key>MacParakeetBuildSource</key>
  <string>${BUILD_SOURCE}</string>
  <key>MacParakeetGitCommit</key>
  <string>${BUILD_GIT_COMMIT}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_MACOS_VERSION}</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>MacParakeet needs microphone access for dictation.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>MacParakeet needs system audio recording access for meeting recording.</string>
  <key>SUFeedURL</key>
  <string>https://macparakeet.com/appcast.xml</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUPublicEDKey</key>
  <string>2aqRU0Agz+xxZwt0kLybmKz/SAvZUsyn+z9fU0I6ynY=</string>
$(printf "%b" "$LICENSING_PLIST")
</dict>
</plist>
EOF

echo "[4/4] Done: $APP_DIR"
echo "Metadata: version=$VERSION build=$BUILD_NUMBER commit=$BUILD_GIT_COMMIT built=$BUILD_DATE_UTC source=$BUILD_SOURCE"
