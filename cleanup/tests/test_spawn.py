"""Tests for auto-spawn of the cleanup daemon.

We don't want these tests to actually load MLX. Instead, we fake the
daemon launcher: replace the discovered launcher path with a tiny Python
script that just opens the requested Unix socket and idles.
"""

from __future__ import annotations

import os
import socket
import sys
import tempfile
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

FAKE_DAEMON = r"""#!/usr/bin/env python3
import os, socket, sys, time
sock = sys.argv[sys.argv.index('--socket') + 1]
try:
    os.unlink(sock)
except FileNotFoundError:
    pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sock)
s.listen(8)
# Idle until killed.
while True:
    try:
        conn, _ = s.accept()
        conn.close()
    except OSError:
        break
"""


def _write_fake_launcher(dirpath: Path) -> Path:
    bin_dir = dirpath / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    launcher = bin_dir / "macparakeet-cleanupd"
    launcher.write_text(FAKE_DAEMON)
    launcher.chmod(0o755)
    return launcher


def test_socket_alive_returns_false_when_no_socket():
    from macparakeet_cleanup.spawn import _socket_alive

    assert _socket_alive("/tmp/macparakeet-spawn-nope.sock") is False


def test_socket_alive_returns_true_for_listening_socket():
    from macparakeet_cleanup.spawn import _socket_alive

    with tempfile.TemporaryDirectory() as td:
        sock_path = str(Path(td) / "live.sock")
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(sock_path)
        s.listen(1)
        try:
            assert _socket_alive(sock_path) is True
        finally:
            s.close()


def test_spawn_daemon_launches_and_socket_comes_up():
    """spawn_daemon() should fork a detached process and the socket appears."""
    from macparakeet_cleanup import spawn as spawn_mod

    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        launcher = _write_fake_launcher(td_path)
        sock_path = str(td_path / "spawn.sock")
        log_path = td_path / "spawn.log"

        ok = spawn_mod.spawn_daemon(
            socket_path=sock_path,
            log_path=log_path,
            wait_seconds=3.0,
            launcher_override=launcher,
        )
        assert ok, (
            f"daemon did not come up; log: "
            f"{log_path.read_text() if log_path.exists() else '<none>'}"
        )
        assert Path(sock_path).exists()

        # Kill the fake daemon.
        import subprocess
        subprocess.run(["pkill", "-f", sock_path], check=False, timeout=2)
        time.sleep(0.2)


def test_ensure_daemon_is_noop_when_already_running():
    from macparakeet_cleanup.spawn import ensure_daemon

    with tempfile.TemporaryDirectory() as td:
        sock_path = str(Path(td) / "live.sock")
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(sock_path)
        s.listen(1)
        try:
            # ensure_daemon must NOT try to spawn anything — the socket is alive.
            alive, spawned = ensure_daemon(sock_path)
            assert alive is True
            assert spawned is False
        finally:
            s.close()


def test_ensure_daemon_cleans_stale_socket(monkeypatch, tmp_path):
    """A stale socket file (no listener) should be removed before spawn."""
    from macparakeet_cleanup import spawn as spawn_mod

    sock_path = tmp_path / "stale.sock"
    sock_path.write_text("")  # not actually a socket; just a stale file

    spawn_called = {"count": 0, "args": None}

    def fake_spawn_daemon(**kwargs):
        spawn_called["count"] += 1
        spawn_called["args"] = kwargs
        return True

    monkeypatch.setattr(spawn_mod, "spawn_daemon", fake_spawn_daemon)
    alive, spawned = spawn_mod.ensure_daemon(str(sock_path))

    assert spawn_called["count"] == 1
    assert alive is True
    assert spawned is True
    assert not sock_path.exists() or sock_path.is_socket()
