#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
app_dir="$scratch/MacParakeet.app"
mkdir -p "$app_dir/Contents/Resources" "$app_dir/Contents/MacOS"
app_binary="$app_dir/Contents/MacOS/MacParakeet"
cli_binary="$app_dir/Contents/MacOS/macparakeet-cli"
printf '%s\n' 'no feature endpoints' > "$app_binary"
cp "$app_binary" "$cli_binary"

verify() {
  bash "$script_dir/verify_discover_bundle_mode.sh" "$app_dir" "$1" > "$scratch/result.log" 2>&1
}

expect_failure() {
  if verify "$1"; then
    echo "Expected verification to reject: $2" >&2
    exit 1
  fi
  grep -F "$2" "$scratch/result.log" > /dev/null
}

verify 1
expect_failure 0 'missing discover-fallback.json'
touch "$app_dir/Contents/Resources/discover-fallback.json"
verify 0
expect_failure 1 'unexpectedly contains:'
rm "$app_dir/Contents/Resources/discover-fallback.json"

# A match near the beginning of output larger than the pipe buffer reproduces
# the previous SIGPIPE false negative, for both binaries and each pattern.
for binary in "$app_binary" "$cli_binary"; do
  for marker in '/api/discover.json' '/api/discover-thoughts' 'MACPARAKEET_DISCOVER_URL'; do
    awk -v marker="$marker" 'BEGIN {
      print marker
      for (i = 0; i < 100000; i++) print "non_secret_padding_for_pipe_buffer"
    }' > "$binary"
    expect_failure 1 'contains Discover endpoints or overrides'
  done
  printf '%s\n' 'no feature endpoints' > "$binary"
done
verify 1
echo 'Discover bundle verification tests passed.'
