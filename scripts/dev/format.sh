#!/usr/bin/env bash
# Format first-party Swift in place with the repo's swift-format config.
# Manual / opt-in — NOT run by CI. Review the diff before committing.
set -euo pipefail
cd "$(dirname "$0")/../.."
echo "Formatting Sources/ and Tests/ with swift-format…"
xcrun swift-format format --in-place --recursive --configuration .swift-format Sources Tests
echo "Done. Review with: git diff --stat"
