#!/usr/bin/env bash
# Additional identity for the separate distribution-only Xcode build cache.
set -euo pipefail
: "${XCODE_DERIVED_DATA:?Set the absolute Xcode DerivedData path}"
xcode_executable=$(xcrun --find xcodebuild)
{
  bash scripts/ci/swift-cache-key.sh
  python3 - "$PWD" "$XCODE_DERIVED_DATA" "$xcode_executable" <<'PY'
from pathlib import Path
import sys
checkout, derived, executable = map(Path, sys.argv[1:])
if not derived.is_absolute():
    raise SystemExit("XCODE_DERIVED_DATA must be absolute")
if not executable.is_absolute() or not executable.is_file():
    raise SystemExit("xcrun must identify the selected xcodebuild executable")
print(checkout.resolve(strict=True))
print(derived.resolve())
print(executable.resolve(strict=True).parents[2])
PY
  shasum -a 256 scripts/dist/build_app_bundle.sh scripts/ci/xcode-cache-key.sh
} | shasum -a 256 | awk '{print $1}'
