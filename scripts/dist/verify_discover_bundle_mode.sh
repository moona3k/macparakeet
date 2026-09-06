#!/usr/bin/env bash
set -euo pipefail

# Inspect the assembled bundle without rebuilding or launching it.
app_dir="${1:?Usage: verify_discover_bundle_mode.sh APP_DIR [DISABLED] [APP_NAME]}"
disabled="${2:-0}"
app_name="${3:-MacParakeet}"
resources_dir="$app_dir/Contents/Resources"
macos_dir="$app_dir/Contents/MacOS"
discover_resource="$(find "$resources_dir" -name 'discover-fallback.json' -print -quit)"

if [[ "$disabled" == "1" ]]; then
  if [[ -n "$discover_resource" ]]; then
    echo "Discover-disabled build unexpectedly contains: $discover_resource" >&2
    exit 1
  fi
  for bundled_binary in "$macos_dir/$app_name" "$macos_dir/macparakeet-cli"; do
    # Consume all strings: grep -q exits on the first match and can give
    # strings SIGPIPE, making this condition false under pipefail.
    if [[ -f "$bundled_binary" ]] && strings "$bundled_binary" | grep -E '/api/discover(\.json|-thoughts)|MACPARAKEET_DISCOVER_' > /dev/null; then
      echo "Discover-disabled build unexpectedly contains Discover endpoints or overrides: $bundled_binary" >&2
      exit 1
    fi
  done
  echo "Verified Discover is absent from the app bundle."
elif [[ -z "$discover_resource" ]]; then
  echo "Discover-enabled build is missing discover-fallback.json." >&2
  exit 1
fi
