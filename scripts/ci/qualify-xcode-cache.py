#!/usr/bin/env python3
"""CI-only consumer invalidation probe; never save caches after running this."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import uuid

REPO = Path(__file__).resolve().parents[2]
SOURCE = Path("Sources/MacParakeet/AppDelegate.swift")
RESOURCE = Path("Sources/MacParakeet/Resources/discover-fallback.json")
ORIGINAL = '"MacParakeet Failed to Start"'


def run_build(root, env):
    process = subprocess.Popen(["bash", "scripts/dist/build_app_bundle.sh"], cwd=root,
                               env=env, start_new_session=True)
    try:
        status = process.wait(timeout=1800)
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
    if status:
        raise RuntimeError(f"Package build failed with exit {status}")


def qualify(root, environment):
    if environment.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("Requires an explicitly dispatched disposable GitHub Actions job")
    temporary = Path(environment["RUNNER_TEMP"])
    derived = Path(environment["XCODE_DERIVED_DATA"])
    if not temporary.is_absolute() or not derived.is_absolute() or not derived.resolve().is_relative_to(temporary.resolve()):
        raise RuntimeError("DerivedData must be inside absolute RUNNER_TEMP")
    source, resource = root / SOURCE, root / RESOURCE
    original_source, original_resource = source.read_bytes(), resource.read_bytes()
    text = original_source.decode()
    if text.count(ORIGINAL) != 1:
        raise RuntimeError("Expected exactly one compiled app string to replace")
    document = json.loads(original_resource)
    if not document.get("items") or not isinstance(document["items"][0].get("title"), str):
        raise RuntimeError("Expected the existing discover resource title")
    marker = "MacParakeetCacheProbe-" + uuid.uuid4().hex
    document["items"][0]["title"] = marker
    env = dict(environment, SKIP_BUILD="0", BUILD_SYSTEM="xcodebuild", UNIVERSAL="0",
               APP_NAME="MacParakeet", BUNDLE_YTDLP="0", BUNDLE_NODE="0",
               FFMPEG_PATH="/usr/bin/true", VERSION="0.0.0", BUILD_NUMBER="cache-probe",
               MACPARAKEET_TELEMETRY="0")
    try:
        source.write_text(text.replace(ORIGINAL, json.dumps(marker)))
        resource.write_text(json.dumps(document) + "\n")
        run_build(root, env)
        app = root / "dist/MacParakeet.app/Contents"
        if marker.encode() not in (app / "MacOS/MacParakeet").read_bytes():
            raise RuntimeError("Packaged app binary lacks the changed source marker")
        bundled = app / "Resources/MacParakeet_MacParakeet.bundle/Contents/Resources/discover-fallback.json"
        if json.loads(bundled.read_text())["items"][0]["title"] != marker:
            raise RuntimeError("Packaged JSON lacks the changed resource marker")
    finally:
        source.write_bytes(original_source)
        resource.write_bytes(original_resource)
    print(json.dumps({"result": "passed", "marker": marker,
                      "sourceRestored": True, "resourceRestored": True}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--qualify", required=True, action="store_true")
    parser.parse_args()

    def interrupted(signum, _frame):
        raise InterruptedError(f"Qualification interrupted by signal {signum}")

    signal.signal(signal.SIGTERM, interrupted)
    qualify(REPO, os.environ)


if __name__ == "__main__":
    main()
