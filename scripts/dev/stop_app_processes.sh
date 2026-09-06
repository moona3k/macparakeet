#!/usr/bin/env bash

# Source this helper before replacing a running app's executable or resources.
# AppKit normal quit preserves recording confirmation and pending-note saves.
stop_app_processes() {
  local helper_dir status=0
  helper_dir="$(mktemp -d "${TMPDIR:-/tmp}/macparakeet-quit.XXXXXX")" || return 1
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # This standalone AppKit helper has no package dependencies. Build outside the
  # app's products so inspecting/quitting never modifies the running app bundle.
  if xcrun swiftc -parse-as-library -module-cache-path "${TMPDIR:-/tmp}/macparakeet-dev-helper-module-cache" \
    "$script_dir/stop_app_processes.swift" -o "$helper_dir/stop-app"; then
    "$helper_dir/stop-app" "$@" || status=$?
  else
    echo 'Could not prepare normal app shutdown. Build aborted.' >&2
    status=1
  fi
  rm -rf "$helper_dir"
  return "$status"
}
