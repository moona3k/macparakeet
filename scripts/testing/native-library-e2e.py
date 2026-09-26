#!/usr/bin/env python3
"""Opt-in real-app qualification. Requires a dedicated disposable GUI account."""
import argparse
import json
import os
from pathlib import Path
import pwd
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[2]
ACCOUNT = "macparakeet-e2e"
NOTES = "Native journey persisted notes: cedar launch approved after relaunch."
TRANSCRIPT = "Synthetic meeting transcript: the cedar launch is approved."


def processes():
    output = subprocess.check_output(["ps", "-axo", "pid=,uid=,comm="], text=True)
    return [(int(p), int(u), command) for line in output.splitlines()
            for p, u, command in [line.strip().split(None, 2)]]


def preflight(attested):
    if not attested or pwd.getpwuid(os.getuid()).pw_name != ACCOUNT or os.getuid() == 0:
        raise RuntimeError("Requires --disposable-account in the dedicated macparakeet-e2e logged-in account. State overrides do not isolate shared preferences or Keychain.")
    if Path("/dev/console").stat().st_uid != os.getuid():
        raise RuntimeError("The disposable account must own the active GUI console")
    if any(uid == os.getuid() and Path(command).name in ("MacParakeet", "MacParakeet-Dev")
           for _, uid, command in processes()):
        raise RuntimeError("Quit existing MacParakeet instances yourself before qualification")
    if shutil.disk_usage(REPO).free < 25 * 1024**3:
        raise RuntimeError("Requires at least 25 GiB free for the owned build")


def group_alive(group_id):
    try:
        os.killpg(group_id, 0)
    except (ProcessLookupError, PermissionError):
        return False
    return True


def run_owned(command, *, cwd, env, log, timeout):
    process = subprocess.Popen(command, cwd=cwd, env=env, stdout=log,
                               stderr=subprocess.STDOUT, start_new_session=True)
    error = None
    status = None
    try:
        status = process.wait(timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt) as caught:
        error = caught
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    if status is None:
        process.wait()
    deadline = time.monotonic() + 10
    while group_alive(process.pid) and time.monotonic() < deadline:
        time.sleep(0.1)
    if error is not None:
        raise error
    if status:
        raise subprocess.CalledProcessError(status, command)


def notes_persisted(database, expected):
    if not database.exists():
        return False
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    try:
        row = connection.execute("SELECT userNotes FROM transcriptions").fetchone()
    finally:
        connection.close()
    return row is not None and row[0] == expected


def wait_for_notes(database, expected, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if notes_persisted(database, expected):
            return
        time.sleep(0.1)
    raise RuntimeError("Saved notes were not persisted to the owned database")


def owned_matches(binary):
    return [pid for pid, uid, command in processes()
            if uid == os.getuid() and command == str(binary)]


def stop(pid, binary):
    if (pid, os.getuid(), str(binary)) not in processes():
        return
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 30
    while any(p == pid for p, _, _ in processes()):
        if time.monotonic() > deadline:
            raise RuntimeError("Owned app did not exit; refusing relaunch")
        time.sleep(0.1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--disposable-account", action="store_true", help="Attest this account contains no valuable app preferences, credentials, or data")
    parser.add_argument("--preflight-only", action="store_true")
    args = parser.parse_args()
    preflight(args.disposable_account)
    if args.preflight_only:
        print("PASS disposable-account preflight")
        return
    root = Path(tempfile.mkdtemp(prefix="macparakeet-native-e2e-"))
    print(f"Evidence retained at {root}", flush=True)
    (root / "owned-native-journey").write_text(ACCOUNT + "\n")
    env = dict(os.environ, MACPARAKEET_NATIVE_E2E_ROOT=str(root),
               MACPARAKEET_DEBUG_APP_STATE_DIR=str(root / "state"), MACPARAKEET_CONFIG="Debug",
               MACPARAKEET_TELEMETRY="0")
    bundle = REPO / ".build/xcode-dev/Build/Products/Debug/MacParakeet-Dev.app"
    binary = bundle / "Contents/MacOS/MacParakeet"
    log = (root / "journey.log").open("w")
    owned_pid = None

    def run(command, timeout=120):
        log.write(f"RUN {command!r}\n")
        log.flush()
        run_owned(command, cwd=REPO, env=env, log=log, timeout=timeout)

    def launched_pid():
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            matches = owned_matches(binary)
            if len(matches) == 1:
                return matches[0]
            if len(matches) > 1:
                raise RuntimeError("Multiple app instances; ownership is ambiguous")
            time.sleep(0.1)
        raise RuntimeError("Owned app did not launch")

    def ax(action, identifier, *values):
        run([str(root / "ax"), str(owned_pid), action, identifier, *values], timeout=45)

    try:
        run(["swiftc", str(REPO / "scripts/testing/native-library-ax.swift"), "-o", str(root / "ax")])
        run(["swift", "test", "--jobs", "4", "--filter", "NativeLibraryJourneyFixtureTests/testSeedOwnedNativeJourney"], timeout=1800)
        meeting_id = (root / "meeting-id").read_text()
        run([str(REPO / "scripts/dev/run_app.sh")], timeout=1800)
        owned_pid = launched_pid()
        ax("press", "sidebar-Library")
        ax("press", "library-item-" + meeting_id)
        ax("press", "meeting-notes-tab")
        ax("assert", "meeting-notes-editor", "Original synthetic notes")
        ax("set", "meeting-notes-editor", NOTES)
        wait_for_notes(root / "state/macparakeet.db", NOTES)
        # Ordinary AppKit quit flushes derived note artifacts; SIGTERM bypasses it.
        ax("quit", "application")
        run(["open", "-n", str(bundle), "--env", "MACPARAKEET_DEBUG_APP_STATE_DIR=" + str(root / "state"),
             "--env", "MACPARAKEET_TELEMETRY=0"])
        owned_pid = launched_pid()
        ax("press", "sidebar-Library")
        ax("press", "library-item-" + meeting_id)
        ax("press", "meeting-notes-tab")
        ax("assert", "meeting-notes-editor", NOTES)
        artifact = root / "state/meetings/native-library-fixture"
        if not (artifact / "notes.md").read_text().rstrip().endswith(NOTES):
            raise RuntimeError("Durable meeting notes artifact differs from saved notes")
        if NOTES not in (artifact / "meeting.md").read_text():
            raise RuntimeError("Materialized meeting Markdown is missing saved notes")
        downloads = Path.home() / "Downloads"
        before = set(downloads.glob("*"))
        ax("press", "transcript-export-options")
        ax("press", "transcript-export-format-md")
        ax("press", "transcript-export-confirm")
        deadline = time.monotonic() + 30
        exported = None
        while time.monotonic() < deadline:
            for path in set(downloads.glob("*.md")) - before:
                content = path.read_text()
                if TRANSCRIPT in content:
                    exported = path
                    break
            if exported:
                break
            time.sleep(0.1)
        if exported is None:
            raise RuntimeError("No new Markdown export containing the persisted transcript")
        shutil.copy2(exported, root / "export.md")
        result = {"result": "passed", "meeting_id": meeting_id,
            "export": str(exported), "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip()}
    except BaseException as error:
        (root / "result.json").write_text(json.dumps({"result": "failed", "error": str(error)}, indent=2))
        raise
    finally:
        try:
            for pid in owned_matches(binary):
                stop(pid, binary)
        except BaseException as error:
            (root / "result.json").write_text(json.dumps({"result": "failed", "cleanupError": str(error)}, indent=2))
            raise
        finally:
            log.close()
    (root / "result.json").write_text(json.dumps(result, indent=2))
    print(f"PASS native Library edit/save/relaunch/export; evidence: {root}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(f"Native Library qualification FAILED: {error}") from error
