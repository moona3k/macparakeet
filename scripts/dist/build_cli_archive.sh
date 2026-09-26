#!/usr/bin/env bash
set -euo pipefail

# Standalone CLI archive with the private Ask runtime. The archive's binary and
# libexec directory can be moved together without a source checkout.
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
tar -czf "$ARCHIVE" -C "$PACKAGE" macparakeet-cli libexec
shasum -a 256 "$ARCHIVE"
