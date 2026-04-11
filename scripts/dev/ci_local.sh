#!/usr/bin/env bash
set -euo pipefail

# Local CI parity check: clean release build + full parallel test run.
swift package clean
swift build -c release
swift test --parallel
