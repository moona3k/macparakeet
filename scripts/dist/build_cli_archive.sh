#!/usr/bin/env bash
set -euo pipefail

# Standalone CLI archive with the private Ask runtime and verified Cohere
# framework. Keep the executable and all sibling directories together.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
VERSION="${VERSION:-0.0.0}"
NODE_VERSION="${NODE_VERSION:-24.13.1}"
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  arm64) NODE_ASSET_ARCH="arm64" ;;
  x86_64) NODE_ASSET_ARCH="x64" ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"

# Development and CI builds may deliberately omit the optional native package.
# Every versioned distribution must include the pinned Cohere runtime.
PACKAGE_PATH="${MACPARAKEET_TRANSCRIBE_CPP_PACKAGE_PATH:-}"
if [[ -n "$PACKAGE_PATH" || ( "$VERSION" != "0.0.0" && "$VERSION" != "ci" ) ]]; then
  [[ "$ARCH" == "arm64" ]] || { echo "Cohere releases require arm64" >&2; exit 1; }
  "$ROOT_DIR/scripts/dist/verify_transcribe_cpp_release.sh"
fi

if [[ -z "${CLI_BINARY:-}" ]]; then
  (cd "$ROOT_DIR" && swift build -c release --product macparakeet-cli)
  CLI_BINARY="$(cd "$ROOT_DIR" && swift build -c release --show-bin-path)/macparakeet-cli"
fi
if [[ ! -x "$CLI_BINARY" ]]; then
  echo "CLI binary unavailable: $CLI_BINARY" >&2
  exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
PACKAGE="$STAGING/macparakeet-cli"
LIBEXEC="$PACKAGE/libexec/macparakeet-cli"
mkdir -p "$LIBEXEC" "$OUT_DIR"
install -m 0755 "$CLI_BINARY" "$PACKAGE/macparakeet-cli"
if [[ -n "$PACKAGE_PATH" ]]; then
  XCFRAMEWORK="$PACKAGE_PATH/build-apple/TranscribeCpp.xcframework"
  FRAMEWORK="$(find "$XCFRAMEWORK" -type d -path '*macos*/CTranscribe.framework' -print -quit)"
  [[ -n "$FRAMEWORK" ]] || { echo "Cohere macOS framework missing" >&2; exit 1; }
  otool -L "$PACKAGE/macparakeet-cli" | grep -Fq '@rpath/CTranscribe.framework/' || {
    echo "CLI does not link the verified Cohere framework" >&2; exit 1;
  }
  mkdir -p "$PACKAGE/Frameworks" "$PACKAGE/Legal"
  ditto "$FRAMEWORK" "$PACKAGE/Frameworks/CTranscribe.framework"
  # The archive runs at its root; Homebrew installs the binary under bin and
  # the framework under libexec/Frameworks. Preserve Ask's existing layout.
  for RPATH in '@executable_path/Frameworks' '@executable_path/../libexec/Frameworks'; do
    if ! otool -l "$PACKAGE/macparakeet-cli" | grep -Fq "path $RPATH "; then
      install_name_tool -add_rpath "$RPATH" "$PACKAGE/macparakeet-cli"
    fi
  done
  # install_name_tool invalidates the linker's arm64 ad-hoc signature. Keep
  # the preliminary archive executable; release instructions replace this
  # with the Developer ID signature before notarization and publication.
  codesign --force --sign - "$PACKAGE/macparakeet-cli"
  codesign --verify --strict "$PACKAGE/macparakeet-cli"
  cp "$ROOT_DIR/LICENSE" "$ROOT_DIR/THIRD_PARTY_LICENSES.md" \
    "$ROOT_DIR/LICENSES/Apache-2.0.txt" "$PACKAGE/Legal/"
  for NOTICE in LICENSE LICENSE.ggml LICENSE.miniz; do
    cp "$XCFRAMEWORK/$NOTICE" "$PACKAGE/Legal/transcribe.cpp-$NOTICE"
  done
fi
"$ROOT_DIR/scripts/build_ask_helper.sh" "$LIBEXEC/AskAgentHelper"

if [[ -n "${NODE_BINARY:-}" ]]; then
  install -m 0755 "$NODE_BINARY" "$LIBEXEC/node"
  if [[ -n "${NODE_LICENSE_FILE:-}" ]]; then
    mkdir -p "$LIBEXEC/Legal/Node"
    install -m 0644 "$NODE_LICENSE_FILE" "$LIBEXEC/Legal/Node/LICENSE"
  fi
else
  ASSET="node-v${NODE_VERSION}-darwin-${NODE_ASSET_ARCH}.tar.gz"
  curl -LsSf "https://nodejs.org/dist/v${NODE_VERSION}/${ASSET}" -o "$STAGING/$ASSET"
  curl -LsSf "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" -o "$STAGING/SHASUMS256.txt"
  EXPECTED="$(awk -v target="$ASSET" '$2 == target {print $1}' "$STAGING/SHASUMS256.txt")"
  ACTUAL="$(shasum -a 256 "$STAGING/$ASSET" | awk '{print $1}')"
  if [[ -z "$EXPECTED" || "$EXPECTED" != "$ACTUAL" ]]; then
    echo "Node SHA256 verification failed for $ASSET" >&2
    exit 1
  fi
  tar -xzf "$STAGING/$ASSET" -C "$STAGING" "node-v${NODE_VERSION}-darwin-${NODE_ASSET_ARCH}/bin/node"
  install -m 0755 "$STAGING/node-v${NODE_VERSION}-darwin-${NODE_ASSET_ARCH}/bin/node" "$LIBEXEC/node"
  mkdir -p "$LIBEXEC/Legal/Node"
  tar -xOzf "$STAGING/$ASSET" "node-v${NODE_VERSION}-darwin-${NODE_ASSET_ARCH}/LICENSE" > "$LIBEXEC/Legal/Node/LICENSE"
fi

ARCHIVE="$OUT_DIR/macparakeet-cli-${VERSION}-darwin-${ARCH}.tar.gz"
CONTENTS=(macparakeet-cli libexec)
if [[ -n "$PACKAGE_PATH" ]]; then CONTENTS+=(Frameworks Legal); fi
tar -czf "$ARCHIVE" -C "$PACKAGE" "${CONTENTS[@]}"
shasum -a 256 "$ARCHIVE"
