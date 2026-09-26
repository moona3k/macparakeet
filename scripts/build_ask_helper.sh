#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
HELPER_DIR="$ROOT_DIR/Sources/AskAgentHelper"
DEST_DIR="${1:?Usage: scripts/build_ask_helper.sh DEST_DIR}"

if ! command -v npm >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
  echo "Building Ask requires Node.js and npm on the build machine." >&2
  exit 1
fi

(
  cd "$HELPER_DIR"
  npm ci --ignore-scripts --no-audit --no-fund
  npm run build
)
mkdir -p "$DEST_DIR"
install -m 0644 "$HELPER_DIR/dist/ask-helper.cjs" "$DEST_DIR/ask-helper.cjs"
node "$HELPER_DIR/scripts/notices.js" "$DEST_DIR/Legal"

# Dev bundles request a verified official Node runtime here. Distribution and
# standalone CLI builders install their own pinned Node copy.
if [[ -n "${2:-}" ]]; then
  NODE_OUT="$2"
  NODE_VERSION="${NODE_VERSION:-24.13.1}"
  NODE_ARCH="$(uname -m)"
  case "$NODE_ARCH" in
    arm64) NODE_ASSET_ARCH="arm64" ;;
    x86_64) NODE_ASSET_ARCH="x64" ;;
    *) echo "Unsupported Node architecture: $NODE_ARCH" >&2; exit 1 ;;
  esac
  NODE_ASSET="node-v${NODE_VERSION}-darwin-${NODE_ASSET_ARCH}.tar.gz"
  CACHE_DIR="$ROOT_DIR/.build/ask-helper-node"
  mkdir -p "$CACHE_DIR"
  if [[ ! -f "$CACHE_DIR/$NODE_ASSET" || ! -f "$CACHE_DIR/SHASUMS256-v${NODE_VERSION}.txt" ]]; then
    curl -LsSf "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_ASSET}" -o "$CACHE_DIR/$NODE_ASSET"
    curl -LsSf "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" -o "$CACHE_DIR/SHASUMS256-v${NODE_VERSION}.txt"
  fi
  EXPECTED="$(awk -v target="$NODE_ASSET" '$2 == target {print $1}' "$CACHE_DIR/SHASUMS256-v${NODE_VERSION}.txt")"
  ACTUAL="$(shasum -a 256 "$CACHE_DIR/$NODE_ASSET" | awk '{print $1}')"
  if [[ -z "$EXPECTED" || "$EXPECTED" != "$ACTUAL" ]]; then
    echo "Node SHA256 verification failed for $NODE_ASSET" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$NODE_OUT")"
  tar -xOzf "$CACHE_DIR/$NODE_ASSET" "node-v${NODE_VERSION}-darwin-${NODE_ASSET_ARCH}/bin/node" > "$NODE_OUT"
  chmod 0755 "$NODE_OUT"
  NODE_LICENSE="$(dirname "$NODE_OUT")/Legal/Node/LICENSE"
  mkdir -p "$(dirname "$NODE_LICENSE")"
  tar -xOzf "$CACHE_DIR/$NODE_ASSET" "node-v${NODE_VERSION}-darwin-${NODE_ASSET_ARCH}/LICENSE" > "$NODE_LICENSE"
fi
