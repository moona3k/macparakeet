"""Auto-spawn the cleanup daemon when the CLI can't reach it.

The first LLM-mode call from a fresh user is "the daemon doesn't exist yet."
Rather than make them manage a process, the CLI detects that case and spawns
the daemon detached. The daemon's idle-exit handles its own teardown.
"""

from __future__ import annotations

import os
import socket
import subprocess
import sys
import time
from pathlib import Path

from .config import DEFAULT_MODEL


def _default_log_dir() -> Path:
    return Path.home() / "Library" / "Logs" / "MacParakeet"


def _socket_alive(socket_path: str, *, timeout: float = 0.2) -> bool:
    """Return True if a daemon is accepting connections on `socket_path`."""
    if not Path(socket_path).exists():
        return False
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(socket_path)
        return True
    except (FileNotFoundError, ConnectionRefusedError, OSError):
        return False
    finally:
        s.close()


def spawn_daemon(
    *,
    socket_path: str,
    model: str = DEFAULT_MODEL,
    log_path: Path | None = None,
    debug: bool = False,
    wait_seconds: float = 5.0,
    launcher_override: Path | None = None,
) -> bool:
    """Spawn the cleanup daemon detached from the current process.

    Returns True if the daemon's socket comes up within `wait_seconds`.

    The daemon inherits its own lifecycle (idle-exit), so the parent doesn't
    need to track its PID. `launcher_override` is for tests.
    """
    log_dir = (log_path.parent if log_path else _default_log_dir())
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_path or (log_dir / "cleanupd.log")

    # Locate the daemon launcher: prefer the bundled bin/macparakeet-cleanupd,
    # fall back to invoking the module via the current Python.
    if launcher_override is not None:
        cmd = [str(launcher_override)]
    else:
        pkg_root = Path(__file__).resolve().parents[1]
        launcher = pkg_root / "bin" / "macparakeet-cleanupd"
        if launcher.exists() and os.access(launcher, os.X_OK):
            cmd = [str(launcher)]
        else:
            cmd = [sys.executable, "-m", "macparakeet_cleanup.daemon"]

    cmd += ["--socket", socket_path, "--model", model]
    if debug:
        cmd.append("--debug")

    log_fh = open(log_file, "ab")  # append; daemon may roll its own.
    try:
        # Detach: new session, /dev/null stdin, log fd as stdout/stderr.
        subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=log_fh,
            stderr=log_fh,
            start_new_session=True,
            close_fds=True,
        )
    finally:
        # Popen dup'd the fd; we can close ours.
        log_fh.close()

    # Wait for the socket to appear and accept connections.
    deadline = time.monotonic() + wait_seconds
    while time.monotonic() < deadline:
        if _socket_alive(socket_path):
            return True
        time.sleep(0.05)
    return False


def ensure_daemon(
    socket_path: str,
    *,
    model: str = DEFAULT_MODEL,
    debug: bool = False,
) -> tuple[bool, bool]:
    """If the daemon isn't responding, try to spawn one.

    Returns (alive, spawned):
      - alive: the daemon is now reachable
      - spawned: this call started a new daemon (model is still loading)
    """
    if _socket_alive(socket_path):
        return True, False
    # Stale socket file (daemon crashed)? Clean it up so bind() can succeed.
    try:
        Path(socket_path).unlink()
    except FileNotFoundError:
        pass
    except OSError:
        pass
    ok = spawn_daemon(socket_path=socket_path, model=model, debug=debug)
    return ok, ok
