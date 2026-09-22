#!/usr/bin/env bash
set -euo pipefail

# Run only in a logged-in macOS GUI session. Every application is a synthetic
# fixture in this test's temporary directory; no real MacParakeet is addressed.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/stop_app_processes.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macparakeet-quit-test.XXXXXX")"
CHILD_PIDS=""
cleanup() {
  for state in "$TEST_DIR"/state-*; do
    [[ -d "$state" ]] && touch "$state/exit"
  done
  for pid in $CHILD_PIDS; do wait "$pid" 2>/dev/null || true; done
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

cat > "$TEST_DIR/Fixture.swift" <<'SWIFT'
import AppKit

let mode = CommandLine.arguments[1]
let state = URL(fileURLWithPath: CommandLine.arguments[2])
func mark(_ name: String) {
    FileManager.default.createFile(atPath: state.appendingPathComponent(name).path, contents: Data())
}
if mode == "raw" {
    mark("ready")
    let deadline = ProcessInfo.processInfo.systemUptime + 60
    while !FileManager.default.fileExists(atPath: state.appendingPathComponent("exit").path) {
        if ProcessInfo.processInfo.systemUptime >= deadline { exit(2) }
        Thread.sleep(forTimeInterval: 0.05)
    }
    exit(0)
}
final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { mark("ready") }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        mark("quit-requested")
        if mode == "cancel" { return .terminateCancel }
        if mode == "unfinished" { return .terminateLater }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            mark("finalized")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
// Fixture-only cleanup, independent of the quit behavior under test. Never
// signal a real app, even when the test fails. The lifetime is bounded as well.
let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    if FileManager.default.fileExists(atPath: state.appendingPathComponent("exit").path) { exit(0) }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(2) }
app.run()
SWIFT
/usr/bin/swiftc "$TEST_DIR/Fixture.swift" -o "$TEST_DIR/Fixture"

start_fixture() {
  local name="$1" mode="$2" mentioned_path="${3:-}"
  local bundle="$TEST_DIR/$name/Fixture.app"
  local state="$TEST_DIR/state-$name"
  mkdir -p "$bundle/Contents/MacOS" "$state"
  cp "$TEST_DIR/Fixture" "$bundle/Contents/MacOS/Fixture"
  cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.macparakeet.synthetic-quit-test</string>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
  "$bundle/Contents/MacOS/Fixture" "$mode" "$state" "$mentioned_path" &
  CHILD_PIDS="${CHILD_PIDS:+$CHILD_PIDS }$!"
  local attempts=0
  until [[ -e "$state/ready" ]]; do
    attempts=$((attempts + 1))
    (( attempts < 200 )) || { echo "Fixture $name failed to become ready" >&2; return 1; }
    sleep 0.05
  done
}

TARGET="$TEST_DIR/owned (dev)[1]/Fixture.app/Contents/MacOS/Fixture"
start_fixture 'owned (dev)[1]' allow
start_fixture production cancel "$TARGET"
start_fixture other-worktree cancel
stop_app_processes 3 "$TEST_DIR" "$TARGET"
[[ -e "$TEST_DIR/state-owned (dev)[1]/finalized" ]]
[[ ! -e "$TEST_DIR/state-production/quit-requested" ]]
[[ ! -e "$TEST_DIR/state-other-worktree/quit-requested" ]]
printf 'PASS: ordinary quit awaits finalization and ignores other executable paths/argument-only matches\n'

ln -s "$TEST_DIR/production/Fixture.app" "$TEST_DIR/linked.app"
if stop_app_processes 0.5 "$TEST_DIR" "$TEST_DIR/linked.app/Contents/MacOS/Fixture"; then
  echo 'Unexpected success with redirected executable ownership' >&2; exit 1
fi
mkdir "$TEST_DIR/owned-root"
if stop_app_processes 0.5 "$TEST_DIR/owned-root" "$TEST_DIR/production/Fixture.app/Contents/MacOS/Fixture"; then
  echo 'Unexpected success with executable outside ownership root' >&2; exit 1
fi
[[ ! -e "$TEST_DIR/state-production/quit-requested" ]]
printf 'PASS: linked and outside-root executables are rejected without requesting quit\n'

start_fixture cancelled cancel
CANCELLED_PID=$!
if stop_app_processes 0.5 "$TEST_DIR" "$TEST_DIR/cancelled/Fixture.app/Contents/MacOS/Fixture"; then
  echo 'Unexpected success after Cancel Quit' >&2; exit 1
fi
[[ -e "$TEST_DIR/state-cancelled/quit-requested" ]]
[[ ! -e "$TEST_DIR/state-cancelled/finalized" ]]
kill -0 "$CANCELLED_PID"
printf 'PASS: Cancel Quit refuses the build\n'

start_fixture unfinished unfinished
UNFINISHED_PID=$!
if stop_app_processes 0.5 "$TEST_DIR" "$TEST_DIR/unfinished/Fixture.app/Contents/MacOS/Fixture"; then
  echo 'Unexpected success with unfinished finalization' >&2; exit 1
fi
[[ -e "$TEST_DIR/state-unfinished/quit-requested" ]]
kill -0 "$UNFINISHED_PID"
printf 'PASS: unfinished finalization refuses the build\n'

stop_app_processes 1 "$TEST_DIR" "$TARGET"
printf 'PASS: an exited exact executable does not block the build\n'

# A raw executable must prevent all quit requests, including other owned apps.
# This child also honors the fixture cleanup marker; no signal is sent.
RAW="$TEST_DIR/raw-executable"
mkdir "$TEST_DIR/state-raw"
cp "$TEST_DIR/Fixture" "$RAW"
"$RAW" raw "$TEST_DIR/state-raw" &
RAW_PID=$!
CHILD_PIDS="${CHILD_PIDS:+$CHILD_PIDS }$RAW_PID"
attempts=0
until [[ -e "$TEST_DIR/state-raw/ready" ]]; do
  attempts=$((attempts + 1))
  (( attempts < 200 )) || { echo 'Raw fixture failed to become ready' >&2; exit 1; }
  sleep 0.05
done
if stop_app_processes 0.5 "$TEST_DIR" "$TEST_DIR/production/Fixture.app/Contents/MacOS/Fixture" "$RAW"; then
  echo 'Unexpected success with a raw executable lacking an app-quit interface' >&2; exit 1
fi
kill -0 "$RAW_PID"
[[ ! -e "$TEST_DIR/state-production/quit-requested" ]]
printf 'PASS: raw executable refuses the build before any app receives quit\n'
