#!/usr/bin/env bash
# Fast inner-loop check for agents: debug build (no release, no clean) plus an
# optional filtered test run. Much faster than scripts/dev/ci_local.sh.
# Usage: scripts/dev/check.sh [test-filter]
set -euo pipefail
cd "$(dirname "$0")/../.."
echo "==> swift build (debug)"
swift build
if [[ "${1:-}" != "" ]]; then
  echo "==> swift test --filter $1"
  swift test --filter "$1"
fi
echo "==> swift-format lint (report only)"
xcrun swift-format lint --recursive --configuration .swift-format Sources Tests || true
echo "check.sh complete"
