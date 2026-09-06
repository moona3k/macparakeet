#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macparakeet-quit-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -parse-as-library -D LAUNCHER_TESTS \
  -module-cache-path "${TMPDIR:-/tmp}/macparakeet-dev-helper-module-cache" \
  "$SCRIPT_DIR/stop_app_processes.swift" "$SCRIPT_DIR/test_stop_app_processes.swift" \
  -o "$TEST_DIR/quit-tests"
"$TEST_DIR/quit-tests"

# A compiler failure must stop the wrapper before it can inspect or quit apps.
source "$SCRIPT_DIR/stop_app_processes.sh"
xcrun() { return 1; }
if stop_app_processes 1 /synthetic/MacParakeet 2>"$TEST_DIR/compiler-error"; then
  echo 'FAIL: helper compilation failure did not abort' >&2
  exit 1
fi
unset -f xcrun
[[ "$(cat "$TEST_DIR/compiler-error")" == *'Build aborted'* ]]
printf 'PASS: helper preparation failure aborts safely\n'

# Exercise the real wrapper's compile/execute/cleanup path with an inert Swift
# fixture. Even a regression must never call the production helper: its Dev
# bundle suffix also matches user apps when the supplied path is synthetic.
cat > "$TEST_DIR/inert-helper.swift" <<'SWIFT'
import Foundation
import Darwin
@main
struct InertWrapperFixture {
    static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        let receipt = environment["MACPARAKEET_WRAPPER_TEST_RECEIPT"]!
        try CommandLine.arguments.joined(separator: "\n").write(
            toFile: receipt, atomically: true, encoding: .utf8
        )
        exit(Int32(environment["MACPARAKEET_WRAPPER_TEST_EXIT"]!)!)
    }
}
SWIFT
xcrun() {
  local original replaced=0
  local compiler_args=()
  for original in "$@"; do
    if [[ "$original" == "$SCRIPT_DIR/stop_app_processes.swift" ]]; then
      compiler_args+=("$TEST_DIR/inert-helper.swift")
      replaced=$((replaced + 1))
    else
      compiler_args+=("$original")
    fi
  done
  [[ "$replaced" == 1 ]] || { echo 'Unsafe test compiler invocation rejected' >&2; return 1; }
  command xcrun "${compiler_args[@]}"
}
export MACPARAKEET_WRAPPER_TEST_RECEIPT="$TEST_DIR/wrapper-receipt"
TEST_EXECUTABLE_ONE='/synthetic/space and (parentheses)[brackets]/MacParakeet'
TEST_EXECUTABLE_TWO='/synthetic/literal$characters+/MacParakeet'
for expected_status in 0 37; do
  export MACPARAKEET_WRAPPER_TEST_EXIT="$expected_status"
  wrapper_status=0
  stop_app_processes 2.5 "$TEST_EXECUTABLE_ONE" "$TEST_EXECUTABLE_TWO" || wrapper_status=$?
  [[ "$wrapper_status" == "$expected_status" ]] || { echo 'Wrapper lost helper exit status' >&2; exit 1; }
  [[ -f "$MACPARAKEET_WRAPPER_TEST_RECEIPT" ]] || { echo 'Compiled fixture did not execute' >&2; exit 1; }
  helper_binary="$(head -n 1 "$MACPARAKEET_WRAPPER_TEST_RECEIPT")"
  expected_arguments="$(printf '%s\n' 2.5 "$TEST_EXECUTABLE_ONE" "$TEST_EXECUTABLE_TWO")"
  actual_arguments="$(tail -n +2 "$MACPARAKEET_WRAPPER_TEST_RECEIPT")"
  [[ "$actual_arguments" == "$expected_arguments" ]] || { echo 'Wrapper changed argument boundaries' >&2; exit 1; }
  [[ ! -e "$helper_binary" && ! -d "${helper_binary%/*}" ]] || { echo 'Wrapper left temporary helper files' >&2; exit 1; }
  rm "$MACPARAKEET_WRAPPER_TEST_RECEIPT"
done
unset -f xcrun
unset MACPARAKEET_WRAPPER_TEST_RECEIPT MACPARAKEET_WRAPPER_TEST_EXIT
printf 'PASS: real wrapper compiles/executes inert fixture, preserves arguments/status and cleans success/failure\n'
