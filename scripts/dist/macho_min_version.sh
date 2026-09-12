#!/usr/bin/env bash
# Mach-O minimum-OS-version inspection and numeric macOS version comparison.
#
# Sourced by scripts/dist/prepare_meeting_echo_assets.sh and
# scripts/dist/verify_meeting_echo_assets.sh. Can also run standalone for
# inspection/testing:
#   scripts/dist/macho_min_version.sh <path-to-macho-file>
# prints one "<arch>\t<minos>" line per architecture slice found in the file.

is_macos_version() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]
}

# Numerically compares dot-separated macOS version strings (e.g. "14.10" >
# "14.2"), padding missing trailing components with 0. Callers must validate
# both inputs with is_macos_version first; behavior on malformed input is
# undefined.
version_compare() {
  local a="$1" b="$2"
  local -a a_parts b_parts
  IFS='.' read -r -a a_parts <<<"$a"
  IFS='.' read -r -a b_parts <<<"$b"
  local len=${#a_parts[@]}
  ((${#b_parts[@]} > len)) && len=${#b_parts[@]}
  local i ac bc
  for ((i = 0; i < len; i++)); do
    ac=$((10#${a_parts[i]:-0}))
    bc=$((10#${b_parts[i]:-0}))
    if ((ac > bc)); then
      printf '1\n'
      return 0
    fi
    if ((ac < bc)); then
      printf -- '-1\n'
      return 0
    fi
  done
  printf '0\n'
}

version_gt() { [[ "$(version_compare "$1" "$2")" == "1" ]]; }

macho_archs() {
  local path="$1"
  local info
  if ! info="$(lipo -info "$path" 2>&1)"; then
    echo "Error: 'lipo -info' failed for '$path': $info" >&2
    return 1
  fi
  if [[ "$info" == *"Non-fat file:"* ]]; then
    awk -F'is architecture: ' '{print $2}' <<<"$info"
  elif [[ "$info" == *"Architectures in the fat file:"* ]]; then
    awk -F'are: ' '{print $2}' <<<"$info"
  else
    echo "Error: could not parse 'lipo -info' output for '$path': $info" >&2
    return 1
  fi
}

# Prints "<arch>\t<minos>" for each architecture slice of $1 to stdout.
# Returns non-zero (with details on stderr) if any slice's minimum-OS-version
# load command (LC_BUILD_VERSION minos, or legacy LC_VERSION_MIN_MACOSX
# version) is missing or malformed. Never silently drops a slice: the caller's
# stdout output is only as complete as its exit status is zero.
macho_minos() {
  local path="$1"
  local archs arch
  archs="$(macho_archs "$path")" || return 1

  local status=0
  for arch in $archs; do
    local lc_output minos
    if ! lc_output="$(otool -arch "$arch" -l "$path" 2>&1)"; then
      echo "Error: 'otool -l' failed for '$path' (arch $arch): $lc_output" >&2
      status=1
      continue
    fi

    minos="$(awk '
      /^[[:space:]]*cmd LC_BUILD_VERSION/ { in_bv=1; in_vm=0; next }
      /^[[:space:]]*cmd LC_VERSION_MIN_MACOSX/ { in_vm=1; in_bv=0; next }
      /^[[:space:]]*cmd / { in_bv=0; in_vm=0 }
      in_bv && /^[[:space:]]*minos / { print $2; exit }
      in_vm && /^[[:space:]]*version / { print $2; exit }
    ' <<<"$lc_output")"

    if [[ -z "$minos" ]] || ! is_macos_version "$minos"; then
      echo "Error: no parseable minimum OS version load command for '$path' (arch $arch)." >&2
      status=1
      continue
    fi
    printf '%s\t%s\n' "$arch" "$minos"
  done
  return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  if [[ "$#" -ne 1 ]]; then
    echo "Usage: $0 <path-to-macho-file>" >&2
    exit 2
  fi
  macho_minos "$1"
fi
