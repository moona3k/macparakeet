#!/usr/bin/env bash
set -euo pipefail

# Prepare the native meeting echo-suppression assets expected by
# scripts/dist/build_app_bundle.sh. Outputs are deterministic and live under
# .build by default so the assets are not committed into the repository.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

. "$ROOT_DIR/scripts/dist/meeting_echo_asset_defaults.sh"

DEFAULT_LOCALVQE_REPO_URL="https://github.com/localai-org/LocalVQE.git"
DEFAULT_LOCALVQE_REF="35b116d5eb059d552fa46fac3ce2963ed13ce153"
DEFAULT_LOCALVQE_FETCH_REF="refs/heads/main"
DEFAULT_MODEL_URL="https://huggingface.co/LocalAI-io/LocalVQE/resolve/main/${DEFAULT_MEETING_ECHO_MODEL_NAME}"

ASSETS_DIR="${MACPARAKEET_MEETING_ECHO_ASSETS_DIR:-$ROOT_DIR/.build/meeting-echo-assets}"
DEFAULT_SOURCE_DIR="$ROOT_DIR/.build/localvqe-src"
SOURCE_DIR="${LOCALVQE_SOURCE_DIR:-$DEFAULT_SOURCE_DIR}"
BUILD_DIR="${LOCALVQE_BUILD_DIR:-$ASSETS_DIR/build}"
LIB_DIR="$ASSETS_DIR/lib"
MODEL_DIR="$ASSETS_DIR/model"
RUNTIME_STAMP="$LIB_DIR/.localvqe-runtime.stamp"
RUNTIME_MANIFEST="$LIB_DIR/.localvqe-runtime.dylibs"

LOCALVQE_REPO_URL="${LOCALVQE_REPO_URL:-$DEFAULT_LOCALVQE_REPO_URL}"
LOCALVQE_REF="${LOCALVQE_REF:-$DEFAULT_LOCALVQE_REF}"
LOCALVQE_FETCH_REF="${LOCALVQE_FETCH_REF:-$DEFAULT_LOCALVQE_FETCH_REF}"
MODEL_NAME="${MACPARAKEET_MEETING_ECHO_MODEL_NAME:-$DEFAULT_MEETING_ECHO_MODEL_NAME}"
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

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

if [[ "$MODEL_NAME" == */* || "$(printf '%s' "$MODEL_NAME" | tr '[:upper:]' '[:lower:]')" != *.gguf ]]; then
  echo "Error: MACPARAKEET_MEETING_ECHO_MODEL_NAME must be a GGUF filename, not a path." >&2
  exit 1
fi

if [[ "$MODEL_NAME" == "$DEFAULT_MEETING_ECHO_MODEL_NAME" ]]; then
  MODEL_SHA256="${MODEL_SHA256:-$DEFAULT_MEETING_ECHO_MODEL_SHA256}"
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

reset_generated_source_dir_if_locked() {
  local lock_path="$SOURCE_DIR/.git/index.lock"
  [[ -e "$lock_path" ]] || return 0

  case "$SOURCE_DIR" in
    "$DEFAULT_SOURCE_DIR" | "$DEFAULT_SOURCE_DIR/")
      echo "Removing generated LocalVQE source cache because a Git lock exists: $lock_path" >&2
      rm -rf "$SOURCE_DIR"
      ;;
    *)
      echo "Error: LocalVQE source checkout is locked: $lock_path" >&2
      echo "Remove the lock manually after confirming no Git process is using LOCALVQE_SOURCE_DIR." >&2
      exit 1
      ;;
  esac
}

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

  # Fetch an advertised ref for portability, then checkout the exact pinned
  # commit. Avoid a depth-limited fetch so the pin survives future branch moves.
  local fetch_args=()
  if [[ "$(git -C "$SOURCE_DIR" rev-parse --is-shallow-repository)" == "true" ]]; then
    fetch_args+=(--unshallow)
  else
    fetch_args+=(--filter=blob:none)
  fi
  git -C "$SOURCE_DIR" fetch "${fetch_args[@]}" origin "$LOCALVQE_FETCH_REF"
  local checkout_output
  if ! checkout_output="$(git -C "$SOURCE_DIR" checkout --detach "$LOCALVQE_REF" 2>&1)"; then
    echo "Error: failed to checkout pinned LocalVQE commit '$LOCALVQE_REF'." >&2
    if [[ -n "$checkout_output" ]]; then
      echo "$checkout_output" >&2
    fi
    echo "If the commit is not reachable from '$LOCALVQE_FETCH_REF', set LOCALVQE_FETCH_REF to an advertised branch or tag that contains LOCALVQE_REF." >&2
    exit 1
  fi
  git -C "$SOURCE_DIR" submodule sync --recursive
  git -C "$SOURCE_DIR" submodule update --init --depth 1 ggml/vendor/ggml
}

localvqe_source_is_current() {
  [[ -d "$SOURCE_DIR/.git" ]] || return 1

  local source_remote
  source_remote="$(git -C "$SOURCE_DIR" remote get-url origin 2>/dev/null)" || return 1
  [[ "$source_remote" == "$LOCALVQE_REPO_URL" ]] || return 1

  local source_head
  source_head="$(git -C "$SOURCE_DIR" rev-parse --verify HEAD 2>/dev/null)" || return 1
  [[ "$source_head" == "$LOCALVQE_REF" ]] || return 1

  local submodule_status
  submodule_status="$(git -C "$SOURCE_DIR" submodule status --recursive ggml/vendor/ggml 2>/dev/null)" || return 1
  [[ -n "$submodule_status" ]] || return 1
  if grep -qvE '^[[:space:]]' <<< "$submodule_status"; then
    return 1
  fi
  return 0
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

localvqe_cmake_jobs() {
  local jobs="${LOCALVQE_CMAKE_BUILD_JOBS:-}"
  if [[ -z "$jobs" ]]; then
    jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  fi
  if ! is_positive_integer "$jobs"; then
    echo "Error: LOCALVQE_CMAKE_BUILD_JOBS must be a positive integer." >&2
    exit 1
  fi
  printf '%s\n' "$jobs"
}

configure_localvqe_runtime() {
  local cmake_build_type_upper
  cmake_build_type_upper="$(printf '%s' "$CMAKE_BUILD_TYPE" | tr '[:lower:]' '[:upper:]')"
  local cmake_args=(
    -S "$SOURCE_DIR/ggml"
    -B "$BUILD_DIR"
    -DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE"
    -DCMAKE_LIBRARY_OUTPUT_DIRECTORY="$BUILD_DIR"
    -DCMAKE_RUNTIME_OUTPUT_DIRECTORY="$BUILD_DIR"
    "-DCMAKE_LIBRARY_OUTPUT_DIRECTORY_${cmake_build_type_upper}=$BUILD_DIR"
    "-DCMAKE_RUNTIME_OUTPUT_DIRECTORY_${cmake_build_type_upper}=$BUILD_DIR"
    -DLOCALVQE_BUILD_SHARED=ON
    -DLOCALVQE_VULKAN=OFF
    -DLOCALVQE_CUDA=OFF
    -DGGML_METAL=OFF
  )
  if [[ "$UNIVERSAL" == "1" ]]; then
    cmake_args+=("-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64")
  fi

  cmake "${cmake_args[@]}"
}

build_localvqe_runtime() {
  echo "Building LocalVQE runtime from ${LOCALVQE_REF}"
  configure_localvqe_runtime

  local jobs
  jobs="$(localvqe_cmake_jobs)"
  echo "Building LocalVQE runtime with ${jobs} CMake job(s)"
  if cmake --build "$BUILD_DIR" --target localvqe_shared -j"$jobs"; then
    return 0
  fi

  if [[ "$jobs" == "1" ]]; then
    return 1
  fi

  echo "Warning: parallel LocalVQE build failed; retrying once with LOCALVQE_CMAKE_BUILD_JOBS=1." >&2
  reset_build_dir
  configure_localvqe_runtime
  cmake --build "$BUILD_DIR" --target localvqe_shared -j1
}

runtime_stamp_value() {
  printf 'repo=%s\n' "$LOCALVQE_REPO_URL"
  printf 'ref=%s\n' "$LOCALVQE_REF"
  printf 'build_type=%s\n' "$CMAKE_BUILD_TYPE"
  printf 'universal=%s\n' "$UNIVERSAL"
}

runtime_dylib_manifest_value() {
  find "$LIB_DIR" -maxdepth 1 -type f -name '*.dylib' -exec basename {} \; | sort
}

runtime_cache_is_current() {
  [[ -f "$LIB_DIR/liblocalvqe.dylib" && -f "$RUNTIME_STAMP" && -f "$RUNTIME_MANIFEST" ]] &&
    cmp -s "$RUNTIME_STAMP" <(runtime_stamp_value) &&
    cmp -s "$RUNTIME_MANIFEST" <(runtime_dylib_manifest_value)
}

reset_build_dir() {
  if [[ -z "$BUILD_DIR" || "$BUILD_DIR" == "/" ]]; then
    echo "Error: refusing to remove unsafe LOCALVQE_BUILD_DIR: '$BUILD_DIR'." >&2
    exit 1
  fi
  rm -rf "$BUILD_DIR"
}

ensure_localvqe_runtime() {
  if runtime_cache_is_current; then
    echo "Meeting echo runtime already present: $LIB_DIR/liblocalvqe.dylib"
    return 0
  fi

  rm -f "$RUNTIME_STAMP" "$RUNTIME_MANIFEST"
  reset_build_dir
  reset_generated_source_dir_if_locked
  if localvqe_source_is_current; then
    echo "LocalVQE source already pinned: $SOURCE_DIR"
  else
    ensure_localvqe_source
  fi
  build_localvqe_runtime
  copy_runtime_outputs
  runtime_dylib_manifest_value > "$RUNTIME_MANIFEST"
  runtime_stamp_value > "$RUNTIME_STAMP"
}

copy_runtime_outputs() {
  local runtime_src
  runtime_src="$(find "$BUILD_DIR" -maxdepth 1 -type f -name 'liblocalvqe*.dylib' | sort | head -n 1)"
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
  done < <(find "$BUILD_DIR" -maxdepth 1 -type f -name '*.dylib' -print0)

  normalize_dylibs
}

rewrite_dependency() {
  local old_path="$1"
  local new_path="$2"
  local target="$3"
  if [[ "$old_path" == "$new_path" ]]; then
    return 0
  fi

  local output
  if ! output="$(install_name_tool -change "$old_path" "$new_path" "$target" 2>&1)"; then
    echo "Error: failed to rewrite LocalVQE dylib dependency." >&2
    echo "  Target: $target" >&2
    echo "  Change: $old_path -> $new_path" >&2
    if [[ -n "$output" ]]; then
      echo "$output" >&2
    fi
    exit 1
  fi
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
    local dylib_id
    dylib_id="$(otool -D "$dylib" | tail -n 1)"
    while IFS= read -r dep; do
      [[ "$dep" == "$dylib_id" ]] && continue
      local dep_base
      dep_base="$(basename "$dep")"
      if [[ "$dep_base" == liblocalvqe*.dylib ]]; then
        rewrite_dependency "$dep" "@loader_path/liblocalvqe.dylib" "$dylib"
      elif [[ -f "$LIB_DIR/$dep_base" ]]; then
        rewrite_dependency "$dep" "@loader_path/$dep_base" "$dylib"
      fi
    done < <(otool -L "$dylib" | sed -E -n 's/^[[:space:]]+(.*) \(compatibility.*/\1/p' | sort -u)
  done
}

ensure_model
ensure_localvqe_runtime

echo "Prepared meeting echo runtime: $LIB_DIR/liblocalvqe.dylib"
echo "Prepared meeting echo model: $MODEL_DIR/$MODEL_NAME"
echo "Meeting echo model SHA256: $MODEL_SHA256"
