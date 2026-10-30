#!/usr/bin/env bash
# Prepare only the pinned Swift wrapper and small native artifact, never a model.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "$ROOT_DIR/scripts/dist/transcribe_cpp_release_pins.sh"
: "${RUNNER_TEMP:?RUNNER_TEMP must identify this job's temporary directory}"
: "${GITHUB_ENV:?GITHUB_ENV must identify this job's environment file}"
[[ "$RUNNER_TEMP" == /* && -d "$RUNNER_TEMP" ]] || { echo 'RUNNER_TEMP must be an existing absolute directory' >&2; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo 'Cohere CI requires an arm64 runner' >&2; exit 1; }
NATIVE_ROOT="$(cd "$RUNNER_TEMP" && pwd -P)/macparakeet-cohere-native"
[[ ! -e "$NATIVE_ROOT" && ! -L "$NATIVE_ROOT" ]] || {
  echo 'Refusing to replace an existing Cohere CI checkout' >&2; exit 1;
}
mkdir "$NATIVE_ROOT"
CHECKOUT="$NATIVE_ROOT/source"
git init --quiet "$CHECKOUT"
git -C "$CHECKOUT" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 fetch --quiet --depth=1 \
  "https://github.com/$TRANSCRIBE_CPP_OWNED_FORK_REPOSITORY.git" "$TRANSCRIBE_CPP_OWNED_FORK_COMMIT"
git -C "$CHECKOUT" checkout --quiet --detach FETCH_HEAD
export MACPARAKEET_TRANSCRIBE_CPP_PACKAGE_PATH="$CHECKOUT/bindings/swift"
export MACPARAKEET_TRANSCRIBE_CPP_ARTIFACT_ZIP="$NATIVE_ROOT/$TRANSCRIBE_CPP_OWNED_ARTIFACT_FILENAME"
export TRANSCRIBE_XCFRAMEWORK_PATH="$MACPARAKEET_TRANSCRIBE_CPP_PACKAGE_PATH/build-apple/TranscribeCpp.xcframework"
curl --fail --location --silent --show-error --connect-timeout 15 --max-time 120 --retry 2 \
  "$TRANSCRIBE_CPP_OWNED_ARTIFACT_URL" -o "$MACPARAKEET_TRANSCRIBE_CPP_ARTIFACT_ZIP"
ACTUAL_SHA="$(shasum -a 256 "$MACPARAKEET_TRANSCRIBE_CPP_ARTIFACT_ZIP" | awk '{print $1}')"
[[ "$ACTUAL_SHA" == "$TRANSCRIBE_CPP_OWNED_ARTIFACT_SHA256" ]] || {
  echo 'Cohere CI artifact checksum mismatch' >&2; exit 1;
}
mkdir -p "$MACPARAKEET_TRANSCRIBE_CPP_PACKAGE_PATH/build-apple"
ditto -x -k "$MACPARAKEET_TRANSCRIBE_CPP_ARTIFACT_ZIP" "$MACPARAKEET_TRANSCRIBE_CPP_PACKAGE_PATH/build-apple"
"$ROOT_DIR/scripts/dist/verify_transcribe_cpp_release.sh"
# Export only after source, archive, installed bytes, architecture, and notices pass.
printf '%s\n' \
  "MACPARAKEET_TRANSCRIBE_CPP_PACKAGE_PATH=$MACPARAKEET_TRANSCRIBE_CPP_PACKAGE_PATH" \
  "MACPARAKEET_TRANSCRIBE_CPP_ARTIFACT_ZIP=$MACPARAKEET_TRANSCRIBE_CPP_ARTIFACT_ZIP" \
  "TRANSCRIBE_XCFRAMEWORK_PATH=$TRANSCRIBE_XCFRAMEWORK_PATH" >> "$GITHUB_ENV"
