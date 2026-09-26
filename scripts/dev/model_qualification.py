#!/usr/bin/env python3
"""Offline, pinned Parakeet-v3 qualification in an explicitly disposable account."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import pwd
import signal
import subprocess
import sys

ACCOUNT = "macparakeet-e2e"
NETWORK_PROFILE = "(version 1)(allow default)(deny network*)"
SANDBOX = Path("/usr/bin/sandbox-exec")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def model_files(state):
    root = state / "FluidAudio" / "Models"
    if not root.is_dir() or root.is_symlink() or root.parent.is_symlink():
        raise ValueError(f"Preprovision the model cache at {root}")
    files = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Model pinning requires owned files, not symlinks: {path}")
        if path.is_file():
            files[str(path.relative_to(root))] = sha256(path)
    if not files:
        raise ValueError("Model cache is empty; provision it before qualification")
    return files


def verify_manifest(state, manifest):
    pin = json.loads(manifest.read_text())
    if not isinstance(pin, dict) or pin.get("model") != "parakeet-v3" or not pin.get("files"):
        raise ValueError("Expected a nonempty parakeet-v3 model manifest")
    if pin["files"] != model_files(state):
        raise ValueError("Model cache differs from the pinned manifest")
    return pin


def check_model_cache_unchanged(state, pin):
    """Compare current model hashes to the pin accepted before CLI work ran.

    Uses the already-loaded ``pin["files"]``, not a manifest re-read from disk,
    so a run that also rewrote the manifest file cannot launder a mutated cache.
    """
    if model_files(state) != pin["files"]:
        raise ValueError("Model cache changed during qualification; rejecting the run")


def run_bounded(command, env, stdout_path, stderr_path, timeout):
    """Terminate and reap the owned command group before returning, on every outcome."""
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        process = subprocess.Popen(command, env=env, stdout=stdout, stderr=stderr,
                                   start_new_session=True)
        try:
            status = process.wait(timeout=timeout)
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
    if status:
        raise ValueError(f"Command exited {status}; see {stderr_path}")


def qualify(args):
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("Qualification requires an Apple Silicon Mac")
    account = pwd.getpwuid(os.getuid())
    if account.pw_name != ACCOUNT or os.getuid() == 0:
        raise ValueError(f"Run in the dedicated disposable {ACCOUNT} macOS account; no CLI was launched")
    home = Path(account.pw_dir).resolve()
    state = args.state_dir.resolve()
    output = args.output_dir.resolve()
    if not state.is_relative_to(home) or not output.is_relative_to(home):
        raise ValueError("State and evidence must stay inside the disposable account home")
    if not state.is_dir() or state.stat().st_uid != os.getuid():
        raise ValueError("State must be a preprovisioned directory owned by the disposable account")
    cli = args.cli.resolve()
    if not cli.is_file() or not os.access(cli, os.X_OK):
        raise ValueError("Pass an existing executable with --cli; this runner never builds/downloads")
    if not SANDBOX.is_file():
        raise ValueError("sandbox-exec is unavailable; refusing to run without the offline boundary")
    pin = verify_manifest(state, args.manifest)
    # A fresh directory prevents stale results or database rows from looking like a pass.
    output.mkdir(parents=True, exist_ok=False)
    env = os.environ.copy()
    env.update(MACPARAKEET_DEBUG_APP_STATE_DIR=str(state), MACPARAKEET_TELEMETRY="0")
    evidence = {"result": "fail", "model": pin["model"], "modelManifestSHA256": sha256(args.manifest),
                "cli": str(cli), "cliSHA256": sha256(cli), "os": platform.platform(),
                "architecture": platform.machine(), "account": account.pw_name,
                "network": "sandbox deny network*", "physicalAudioTested": False}
    try:
        run_bounded([str(SANDBOX), "-p", NETWORK_PROFILE, str(cli), "models", "list", "--json"],
                    env, output / "models.json", output / "models.stderr", 60)
        models = json.loads((output / "models.json").read_text())
        if not isinstance(models, list) or not any(
                isinstance(model, dict) and model.get("id") == "parakeet-v3" and model.get("installed") is True
                for model in models):
            raise ValueError("Pinned Parakeet v3 is not installed according to the tested CLI")
        smoke = Path(__file__).with_name("release_demo_smoke.sh")
        run_bounded([str(SANDBOX), "-p", NETWORK_PROFILE, "/bin/bash", str(smoke),
                     "--cli", str(cli), "--output-dir", str(output)],
                    env, output / "journey.stdout", output / "journey.stderr", args.timeout)
        # Recheck the accepted assertions independently of the shell's exit status.
        from verify_release_demo import verify
        evidence["validation"] = verify(output)
        check_model_cache_unchanged(state, pin)
        evidence["result"] = "pass"
    except (ValueError, OSError, subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        evidence["error"] = str(error)
        raise
    finally:
        (output / "qualification.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"Model/file qualification passed. Evidence: {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    pin = commands.add_parser("pin", help="Hash preprovisioned model files; does not run a model or download")
    pin.add_argument("--state-dir", type=Path, required=True)
    pin.add_argument("--output", type=Path, required=True)
    run = commands.add_parser("run", help=f"Run only as {ACCOUNT}, with networking denied")
    run.add_argument("--cli", type=Path, required=True)
    run.add_argument("--state-dir", type=Path, required=True)
    run.add_argument("--manifest", type=Path, required=True)
    run.add_argument("--output-dir", type=Path, required=True)
    run.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    try:
        if args.command == "pin":
            files = model_files(args.state_dir.resolve())
            with args.output.open("x") as destination:
                json.dump({"model": "parakeet-v3", "files": files}, destination, indent=2)
                destination.write("\n")
        else:
            if args.timeout <= 0:
                raise ValueError("--timeout must be positive")
            qualify(args)
    except (ValueError, OSError, subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        print(f"Qualification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
