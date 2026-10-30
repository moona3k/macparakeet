#!/usr/bin/env bash
# Identity for reusable SwiftPM build state. Source files deliberately do not
# participate: each job still asks SwiftPM to rebuild changed inputs. The caller
# adds the lane and commit so immutable cache entries can advance independently.
set -euo pipefail

{
  uname -m
  sw_vers
  xcodebuild -version
  swift --version
  xcrun --show-sdk-build-version
  shasum -a 256 Package.swift Package.resolved .github/workflows/ci.yml scripts/ci/swift-cache-key.sh
  shasum -a 256 scripts/ci/prepare_cohere_runtime.sh scripts/dist/transcribe_cpp_release_pins.sh \
    scripts/dist/verify_transcribe_cpp_release.sh
  printf 'cohere-native=%s\n' "${MACPARAKEET_TRANSCRIBE_CPP_PACKAGE_PATH:-disabled}"
} | shasum -a 256 | awk '{print $1}'
