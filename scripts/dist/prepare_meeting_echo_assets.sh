#!/usr/bin/env bash
set -euo pipefail

# Prepare the native meeting echo-suppression assets expected by
# scripts/dist/build_app_bundle.sh. Outputs are deterministic and live under
# .build by default so the assets are not committed into the repository.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

DEFAULT_LOCALVQE_REPO_URL="https://github.com/localai-org/LocalVQE.git"
DEFAULT_LOCALVQE_REF="35b116d5eb059d552fa46fac3ce2963ed13ce153"
DEFAULT_MODEL_NAME="localvqe-v1.4-aec-200K-f32.gguf"
DEFAULT_MODEL_URL="https://huggingface.co/LocalAI-io/LocalVQE/resolve/main/${DEFAULT_MODEL_NAME}"
DEFAULT_MODEL_SHA256="b6e43138588a83bfe903ab5e143b4020b91c1e1629f5a575ac5855ff0003c731"

ASSETS_DIR="${MACPARAKEET_MEETING_ECHO_ASSETS_DIR:-$ROOT_DIR/.build/meeting-echo-assets}"
SOURCE_DIR="${LOCALVQE_SOURCE_DIR:-$ROOT_DIR/.build/localvqe-src}"
BUILD_DIR="${LOCALVQE_BUILD_DIR:-$ASSETS_DIR/build}"
LIB_DIR="$ASSETS_DIR/lib"
MODEL_DIR="$ASSETS_DIR/model"

LOCALVQE_REPO_URL="${LOCALVQE_REPO_URL:-$DEFAULT_LOCALVQE_REPO_URL}"
LOCALVQE_REF="${LOCALVQE_REF:-$DEFAULT_LOCALVQE_REF}"
MODEL_NAME="${MACPARAKEET_MEETING_ECHO_MODEL_NAME:-$DEFAULT_MODEL_NAME}"
MODEL_URL="${MACPARAKEET_MEETING_ECHO_MODEL_URL:-$DEFAULT_MODEL_URL}"
MODEL_SHA256="${MACPARAKEET_MEETING_ECHO_MODEL_SHA256:-}"
UNIVERSAL="${MACPARAKEET_MEETING_ECHO_UNIVERSAL:-${UNIVERSAL:-0}}"
CMAKE_BUILD_TYPE="${LOCALVQE_CMAKE_BUILD_TYPE:-Release}"

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: '${tool}' is required to prepare meeting echo assets." >&2
    exit 1
  fi
}

require_tool git
require_tool cmake
require_tool curl
require_tool shasum

if [[ "$MODEL_NAME" == */* || "$(printf '%s' "$MODEL_NAME" | tr '[:upper:]' '[:lower:]')" != *.gguf ]]; then
  echo "Error: MACPARAKEET_MEETING_ECHO_MODEL_NAME must be a GGUF filename, not a path." >&2
  exit 1
fi

if [[ "$MODEL_NAME" == "$DEFAULT_MODEL_NAME" ]]; then
  MODEL_SHA256="${MODEL_SHA256:-$DEFAULT_MODEL_SHA256}"
else
  if [[ -z "${MACPARAKEET_MEETING_ECHO_MODEL_URL:-}" ]]; then
    echo "Error: custom MACPARAKEET_MEETING_ECHO_MODEL_NAME requires MACPARAKEET_MEETING_ECHO_MODEL_URL." >&2
    exit 1
  fi
  if [[ -z "$MODEL_SHA256" ]]; then
    echo "Error: custom MACPARAKEET_MEETING_ECHO_MODEL_NAME requires MACPARAKEET_MEETING_ECHO_MODEL_SHA256." >&2
    exit 1
  fi
fi

mkdir -p "$ASSETS_DIR" "$LIB_DIR" "$MODEL_DIR"

ensure_localvqe_source() {
  if [[ -d "$SOURCE_DIR/.git" ]]; then
    echo "Updating LocalVQE source at $SOURCE_DIR"
    git -C "$SOURCE_DIR" remote set-url origin "$LOCALVQE_REPO_URL"
  elif [[ -e "$SOURCE_DIR" ]]; then
    echo "Error: LOCALVQE_SOURCE_DIR exists but is not a git repository: $SOURCE_DIR" >&2
    exit 1
  else
    echo "Cloning LocalVQE source into $SOURCE_DIR"
    git clone --filter=blob:none "$LOCALVQE_REPO_URL" "$SOURCE_DIR"
  fi

  git -C "$SOURCE_DIR" fetch --depth 1 origin "$LOCALVQE_REF"
  git -C "$SOURCE_DIR" checkout --detach FETCH_HEAD
  git -C "$SOURCE_DIR" submodule sync --recursive
  git -C "$SOURCE_DIR" submodule update --init --depth 1 ggml/vendor/ggml
}

actual_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

ensure_model() {
  local model_path="$MODEL_DIR/$MODEL_NAME"
  local expected_sha_lc
  expected_sha_lc="$(printf '%s' "$MODEL_SHA256" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"

  if [[ -f "$model_path" ]]; then
    local existing_sha
    existing_sha="$(actual_sha256 "$model_path")"
    if [[ "$existing_sha" == "$expected_sha_lc" ]]; then
      echo "Meeting echo model already present: $model_path"
      return 0
    fi
    echo "Existing meeting echo model checksum mismatch; re-downloading $MODEL_NAME" >&2
    rm -f "$model_path"
  fi

  echo "Downloading meeting echo model: $MODEL_NAME"
  local tmp_path="$model_path.tmp"
  rm -f "$tmp_path"
  curl --fail --location --show-error --silent "$MODEL_URL" --output "$tmp_path"

  local actual_sha
  actual_sha="$(actual_sha256 "$tmp_path")"
  if [[ "$actual_sha" != "$expected_sha_lc" ]]; then
    rm -f "$tmp_path"
    echo "Error: downloaded meeting echo model SHA256 verification failed." >&2
    echo "  Expected: $MODEL_SHA256" >&2
    echo "  Actual:   $actual_sha" >&2
    exit 1
  fi
  mv "$tmp_path" "$model_path"
  chmod 0644 "$model_path"
  echo "Meeting echo model SHA256 verified: $actual_sha"
}

build_localvqe_runtime() {
  echo "Building LocalVQE runtime from ${LOCALVQE_REF}"
  local cmake_args=(
    -S "$SOURCE_DIR/ggml"
    -B "$BUILD_DIR"
    -DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE"
    -DLOCALVQE_BUILD_SHARED=ON
    -DLOCALVQE_VULKAN=OFF
    -DLOCALVQE_CUDA=OFF
    -DGGML_METAL=OFF
  )
  if [[ "$UNIVERSAL" == "1" ]]; then
    cmake_args+=("-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64")
  fi

  cmake "${cmake_args[@]}"

  local jobs
  jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  cmake --build "$BUILD_DIR" --target localvqe_shared -j"$jobs"
}

copy_runtime_outputs() {
  local runtime_src
  runtime_src="$(find "$BUILD_DIR" -type f -name 'liblocalvqe*.dylib' | sort | head -n 1)"
  if [[ -z "${runtime_src:-}" || ! -f "$runtime_src" ]]; then
    echo "Error: LocalVQE build did not produce liblocalvqe*.dylib under $BUILD_DIR" >&2
    exit 1
  fi

  find "$LIB_DIR" -maxdepth 1 -type f -name '*.dylib' -delete
  install -m 0755 "$runtime_src" "$LIB_DIR/liblocalvqe.dylib"

  while IFS= read -r -d '' dylib; do
    local base
    base="$(basename "$dylib")"
    if [[ "$base" == liblocalvqe* ]]; then
      continue
    fi
    install -m 0755 "$dylib" "$LIB_DIR/$base"
  done < <(find "$BUILD_DIR" -type f -name '*.dylib' -print0)

  normalize_dylibs
}

normalize_dylibs() {
  if ! command -v install_name_tool >/dev/null 2>&1; then
    echo "Warning: install_name_tool is not available; leaving LocalVQE install names unchanged." >&2
    return 0
  fi

  local dylib
  for dylib in "$LIB_DIR"/*.dylib; do
    [[ -f "$dylib" ]] || continue
    local base
    base="$(basename "$dylib")"
    if [[ "$base" == "liblocalvqe.dylib" ]]; then
      install_name_tool -id "@rpath/liblocalvqe.dylib" "$dylib"
    else
      install_name_tool -id "@rpath/$base" "$dylib"
    fi
  done

  if ! command -v otool >/dev/null 2>&1; then
    return 0
  fi

  for dylib in "$LIB_DIR"/*.dylib; do
    [[ -f "$dylib" ]] || continue
    while IFS= read -r dep; do
      local dep_base
      dep_base="$(basename "$dep")"
      if [[ -f "$LIB_DIR/$dep_base" ]]; then
        install_name_tool -change "$dep" "@loader_path/$dep_base" "$dylib" || true
      fi
      if [[ "$dep_base" == liblocalvqe*.dylib ]]; then
        install_name_tool -change "$dep" "@loader_path/liblocalvqe.dylib" "$dylib" || true
      fi
    done < <(otool -L "$dylib" | awk '/^[[:space:]]/ {print $1}')
  done
}

ensure_localvqe_source
ensure_model
build_localvqe_runtime
copy_runtime_outputs

echo "Prepared meeting echo runtime: $LIB_DIR/liblocalvqe.dylib"
echo "Prepared meeting echo model: $MODEL_DIR/$MODEL_NAME"
echo "Meeting echo model SHA256: $MODEL_SHA256"
