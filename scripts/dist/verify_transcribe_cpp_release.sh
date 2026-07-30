#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT_DIR/scripts/dist/transcribe_cpp_release_pins.sh"

PACKAGE_PATH="${MACPARAKEET_TRANSCRIBE_CPP_PACKAGE_PATH:-}"
ARTIFACT_ZIP="${MACPARAKEET_TRANSCRIBE_CPP_ARTIFACT_ZIP:-}"

fail() {
  echo "Error: $*" >&2
  exit 1
}

[[ "${UNIVERSAL:-0}" != "1" ]] ||
  fail "UNIVERSAL=1 is incompatible with the arm64-only transcribe.cpp release artifact."

[[ -n "$TRANSCRIBE_CPP_OWNED_FORK_COMMIT" ]] ||
  fail "the owned transcribe.cpp fork commit is not pinned. See scripts/dist/transcribe_cpp_release_pins.sh."
[[ -n "$TRANSCRIBE_CPP_OWNED_ARTIFACT_SHA256" ]] ||
  fail "the owned transcribe.cpp XCFramework checksum is not pinned. See scripts/dist/transcribe_cpp_release_pins.sh."
[[ -n "$TRANSCRIBE_CPP_OWNED_RELEASE_TAG" &&
   -n "$TRANSCRIBE_CPP_OWNED_ARTIFACT_FILENAME" &&
   -n "$TRANSCRIBE_CPP_OWNED_ARTIFACT_URL" ]] ||
  fail "the owned transcribe.cpp release metadata is incomplete. See scripts/dist/transcribe_cpp_release_pins.sh."

[[ -n "$PACKAGE_PATH" && -d "$PACKAGE_PATH" ]] ||
  fail "MACPARAKEET_TRANSCRIBE_CPP_PACKAGE_PATH must point to the owned Swift wrapper package."
[[ -n "$ARTIFACT_ZIP" && -f "$ARTIFACT_ZIP" ]] ||
  fail "MACPARAKEET_TRANSCRIBE_CPP_ARTIFACT_ZIP must point to the owned XCFramework archive."
[[ "$(basename "$ARTIFACT_ZIP")" == "$TRANSCRIBE_CPP_OWNED_ARTIFACT_FILENAME" ]] ||
  fail "transcribe.cpp artifact filename mismatch, expected $TRANSCRIBE_CPP_OWNED_ARTIFACT_FILENAME."

PACKAGE_PATH="$(cd "$PACKAGE_PATH" && pwd)"
PACKAGE_ROOT="$(git -C "$PACKAGE_PATH" rev-parse --show-toplevel 2>/dev/null)" ||
  fail "the transcribe.cpp package must live in a Git checkout."
ACTUAL_COMMIT="$(git -C "$PACKAGE_ROOT" rev-parse HEAD)"
[[ "$ACTUAL_COMMIT" == "$TRANSCRIBE_CPP_OWNED_FORK_COMMIT" ]] ||
  fail "transcribe.cpp checkout commit mismatch, expected $TRANSCRIBE_CPP_OWNED_FORK_COMMIT, got $ACTUAL_COMMIT."

SWIFT_PINS="$ROOT_DIR/Sources/MacParakeetCore/STT/CohereTranscribeModel.swift"
grep -Fq "static let ownedForkRepository = \"$TRANSCRIBE_CPP_OWNED_FORK_REPOSITORY\"" "$SWIFT_PINS" ||
  fail "the Swift owned-fork repository pin does not match the distribution pin."
grep -Fq "static let ownedForkCommit = \"$TRANSCRIBE_CPP_OWNED_FORK_COMMIT\"" "$SWIFT_PINS" ||
  fail "the Swift native capability pin does not match the owned fork commit."
grep -Fq "static let ownedReleaseTag = \"$TRANSCRIBE_CPP_OWNED_RELEASE_TAG\"" "$SWIFT_PINS" ||
  fail "the Swift release tag pin does not match the distribution pin."
grep -Fq "\"$TRANSCRIBE_CPP_OWNED_ARTIFACT_FILENAME\"" "$SWIFT_PINS" ||
  fail "the Swift artifact filename pin does not match the distribution pin."
grep -Fq "\"$TRANSCRIBE_CPP_OWNED_ARTIFACT_URL\"" "$SWIFT_PINS" ||
  fail "the Swift artifact URL pin does not match the distribution pin."
grep -Fq "\"$TRANSCRIBE_CPP_OWNED_ARTIFACT_SHA256\"" "$SWIFT_PINS" ||
  fail "the Swift artifact checksum pin does not match the distribution pin."

WRAPPER_SOURCE="$PACKAGE_PATH/Sources/TranscribeCpp/TranscribeCpp.swift"
[[ -f "$WRAPPER_SOURCE" ]] || fail "Swift wrapper source is missing at $WRAPPER_SOURCE."
grep -Fq "public static let compiledVersion = \"$TRANSCRIBE_CPP_WRAPPER_VERSION\"" "$WRAPPER_SOURCE" ||
  fail "Swift wrapper version does not match $TRANSCRIBE_CPP_WRAPPER_VERSION."

GGML_UPSTREAM_FILE="$PACKAGE_ROOT/ggml/UPSTREAM"
MINIZ_UPSTREAM_FILE="$PACKAGE_ROOT/src/third_party/miniz/UPSTREAM"
[[ -f "$GGML_UPSTREAM_FILE" ]] || fail "the ggml upstream provenance file is missing."
[[ -f "$MINIZ_UPSTREAM_FILE" ]] || fail "the miniz upstream provenance file is missing."
[[ "$(awk '$1 == "sha:" { print $2; exit }' "$GGML_UPSTREAM_FILE")" == "$TRANSCRIBE_CPP_GGML_UPSTREAM_COMMIT" ]] ||
  fail "the vendored ggml upstream commit does not match its release pin."
[[ "$(awk '$1 == "sha:" { print $2; exit }' "$MINIZ_UPSTREAM_FILE")" == "$TRANSCRIBE_CPP_MINIZ_UPSTREAM_COMMIT" ]] ||
  fail "the vendored miniz upstream commit does not match its release pin."

ACTUAL_ARTIFACT_SHA="$(shasum -a 256 "$ARTIFACT_ZIP" | awk '{print $1}')"
[[ "$ACTUAL_ARTIFACT_SHA" == "$TRANSCRIBE_CPP_OWNED_ARTIFACT_SHA256" ]] ||
  fail "transcribe.cpp artifact checksum mismatch, expected $TRANSCRIBE_CPP_OWNED_ARTIFACT_SHA256, got $ACTUAL_ARTIFACT_SHA."

XCFRAMEWORK_PATH="$PACKAGE_PATH/build-apple/TranscribeCpp.xcframework"
[[ -d "$XCFRAMEWORK_PATH" ]] ||
  fail "the verified XCFramework must be installed at $XCFRAMEWORK_PATH."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ditto -x -k "$ARTIFACT_ZIP" "$TMP_DIR"
ARCHIVE_XCFRAMEWORK="$(find "$TMP_DIR" -type d -name TranscribeCpp.xcframework -print -quit)"
[[ -n "$ARCHIVE_XCFRAMEWORK" ]] ||
  fail "the artifact archive does not contain TranscribeCpp.xcframework."

# The upstream packager follows the standard macOS framework symlinks when it
# creates the zip. Materialize the installed tree the same way so recursive
# comparison checks every file without following those links into directory
# loops.
MATERIALIZED_DIR="$TMP_DIR/installed"
mkdir "$MATERIALIZED_DIR"
cp -RL "$XCFRAMEWORK_PATH" "$MATERIALIZED_DIR/"
MATERIALIZED_XCFRAMEWORK="$MATERIALIZED_DIR/TranscribeCpp.xcframework"
diff -qr "$ARCHIVE_XCFRAMEWORK" "$MATERIALIZED_XCFRAMEWORK" >/dev/null ||
  fail "the wrapper package XCFramework differs from the checksum-verified archive."

NATIVE_BINARY="$(find "$XCFRAMEWORK_PATH" -path '*macos*/CTranscribe.framework/Versions/A/CTranscribe' -type f -print -quit)"
if [[ -z "$NATIVE_BINARY" ]]; then
  NATIVE_BINARY="$(find "$XCFRAMEWORK_PATH" -path '*macos*/CTranscribe.framework/CTranscribe' -type f -print -quit)"
fi
[[ -n "$NATIVE_BINARY" ]] || fail "the XCFramework has no macOS CTranscribe binary."
[[ "$(lipo -archs "$NATIVE_BINARY")" == "arm64" ]] ||
  fail "the owned macOS CTranscribe framework must contain only arm64."

for notice in LICENSE LICENSE.ggml LICENSE.miniz; do
  [[ -f "$XCFRAMEWORK_PATH/$notice" ]] ||
    fail "the XCFramework is missing required notice $notice."
done
cmp -s "$XCFRAMEWORK_PATH/LICENSE" "$ROOT_DIR/LICENSES/transcribe.cpp-MIT.txt" ||
  fail "the XCFramework transcribe.cpp MIT notice differs from the retained source notice."
cmp -s "$XCFRAMEWORK_PATH/LICENSE.ggml" "$ROOT_DIR/LICENSES/transcribe.cpp-ggml-MIT.txt" ||
  fail "the XCFramework ggml MIT notice differs from the retained source notice."
cmp -s "$XCFRAMEWORK_PATH/LICENSE.miniz" "$ROOT_DIR/LICENSES/transcribe.cpp-miniz-MIT.txt" ||
  fail "the XCFramework miniz MIT notice differs from the retained source notice."

echo "Verified owned transcribe.cpp commit: $ACTUAL_COMMIT"
echo "Verified owned transcribe.cpp artifact: $ACTUAL_ARTIFACT_SHA"
