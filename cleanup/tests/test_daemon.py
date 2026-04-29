"""Tests for the daemon: lazy load, warmup endpoint, idle unload, CLI --warmup."""

from __future__ import annotations

import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
PYTHON = ROOT / ".venv" / "bin" / "python"
sys.path.insert(0, str(ROOT))


# ---- helpers ------------------------------------------------------------------


class FakeEngine:
    """Stand-in for MLXEngine. Records load/unload/clean calls; instant ops."""

    def __init__(self, model_id: str):
        self.model_id = model_id
        self._loaded = False
        self.last_used = time.monotonic()
        self.load_calls = 0
        self.unload_calls = 0
        self.clean_calls = 0
        # Per-call delay to simulate model load time.
        self.load_delay_s = 0.0

    @property
    def is_loaded(self) -> bool:
        return self._loaded

    def load(self) -> None:
        if self._loaded:
            return
        if self.load_delay_s:
            time.sleep(self.load_delay_s)
        self._loaded = True
        self.load_calls += 1

    def unload(self) -> None:
        if not self._loaded:
            return
        self._loaded = False
        self.unload_calls += 1

    def warmup(self) -> None:
        self.load()

    def clean(self, text: str, max_tokens: int = 150) -> str:
        self.load()
        self.last_used = time.monotonic()
        self.clean_calls += 1
        return f"CLEANED:{text}"


def _serve_in_thread(socket_path: str, engine: FakeEngine, **kwargs) -> threading.Thread:
    """Run the daemon's serve() in a thread with a fake engine."""
    from macparakeet_cleanup import daemon as daemon_mod

    # Monkey-patch MLXEngine for this thread's serve() invocation.
    original = daemon_mod.MLXEngine
    daemon_mod.MLXEngine = lambda model_id: engine  # type: ignore[assignment]

    def runner():
        try:
            daemon_mod.serve(socket_path, "fake-model", **kwargs)
        finally:
            daemon_mod.MLXEngine = original  # type: ignore[assignment]

    t = threading.Thread(target=runner, daemon=True)
    t.start()
    # Wait up to 2s for the socket to appear.
    for _ in range(200):
        if Path(socket_path).exists():
            return t
        time.sleep(0.01)
    raise RuntimeError("daemon socket never appeared")


def _shutdown(socket_path: str, thread: threading.Thread) -> None:
    """Send SIGTERM-equivalent: close socket via direct unlink + thread death."""
    # The cleanest cross-thread shutdown is to send a signal at process level,
    # but tests share a process. Instead we send a malformed connection and
    # then unlink the socket to break the accept loop.
    try:
        os.kill(os.getpid(), 0)  # noop; kept for clarity
    except Exception:
        pass
    # Connect briefly to unblock accept(), then close server by killing socket file.
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.5)
        s.connect(socket_path)
        s.close()
    except Exception:
        pass
    try:
        Path(socket_path).unlink()
    except FileNotFoundError:
        pass
    thread.join(timeout=2.0)


# ---- tests --------------------------------------------------------------------


def test_lazy_load_model_not_loaded_at_boot():
    with tempfile.TemporaryDirectory() as td:
        sock = str(Path(td) / "d.sock")
        engine = FakeEngine("fake")
        thread = _serve_in_thread(sock, engine, idle_exit_seconds=3600)
        try:
            # No requests yet — model must NOT have been loaded.
            assert engine.load_calls == 0
            assert engine.is_loaded is False
        finally:
            _shutdown(sock, thread)


def test_eager_load_loads_at_boot():
    with tempfile.TemporaryDirectory() as td:
        sock = str(Path(td) / "d.sock")
        engine = FakeEngine("fake")
        thread = _serve_in_thread(sock, engine, idle_exit_seconds=3600, eager_load=True)
        try:
            assert engine.is_loaded is True
            assert engine.load_calls == 1
        finally:
            _shutdown(sock, thread)


def test_first_cleanup_request_triggers_load():
    from macparakeet_cleanup.protocol import send_request

    with tempfile.TemporaryDirectory() as td:
        sock = str(Path(td) / "d.sock")
        engine = FakeEngine("fake")
        thread = _serve_in_thread(sock, engine, idle_exit_seconds=3600)
        try:
            assert engine.is_loaded is False
            out = send_request(sock, "hello", timeout=2.0)
            assert out == "CLEANED:hello"
            assert engine.is_loaded is True
            assert engine.load_calls == 1
            assert engine.clean_calls == 1
        finally:
            _shutdown(sock, thread)


def test_warmup_request_triggers_async_load_and_returns_fast():
    from macparakeet_cleanup.protocol import send_warmup

    with tempfile.TemporaryDirectory() as td:
        sock = str(Path(td) / "d.sock")
        engine = FakeEngine("fake")
        engine.load_delay_s = 0.5  # simulate slow model load
        thread = _serve_in_thread(sock, engine, idle_exit_seconds=3600)
        try:
            t0 = time.perf_counter()
            send_warmup(sock, timeout=2.0)
            elapsed = time.perf_counter() - t0
            # Warmup must return well before the simulated 500ms load completes.
            assert elapsed < 0.2, f"warmup blocked for {elapsed:.3f}s"
            # Wait for the async load to complete.
            for _ in range(100):
                if engine.is_loaded:
                    break
                time.sleep(0.02)
            assert engine.is_loaded is True
        finally:
            _shutdown(sock, thread)


def test_warmup_is_noop_when_already_loaded():
    from macparakeet_cleanup.protocol import send_request, send_warmup

    with tempfile.TemporaryDirectory() as td:
        sock = str(Path(td) / "d.sock")
        engine = FakeEngine("fake")
        thread = _serve_in_thread(sock, engine, idle_exit_seconds=3600)
        try:
            send_request(sock, "x", timeout=2.0)
            assert engine.load_calls == 1
            send_warmup(sock, timeout=2.0)
            time.sleep(0.05)  # let any spurious async thread settle
            assert engine.load_calls == 1, "warmup should not reload an already-loaded model"
        finally:
            _shutdown(sock, thread)


def test_idle_exit_terminates_daemon_after_timeout():
    """The daemon process should exit (thread should die, socket should disappear)
    after `idle_exit_seconds` of no requests."""
    from macparakeet_cleanup.protocol import send_request

    with tempfile.TemporaryDirectory() as td:
        sock = str(Path(td) / "d.sock")
        engine = FakeEngine("fake")
        # Idle threshold small enough to test fast, but >= 1.25s so the
        # exiter's interval (max(5, idle/4)) = 5s won't dominate.
        # Use idle=2s so check interval ≈ 5s — too slow. Override interval
        # by patching the helper instead.
        from macparakeet_cleanup import daemon as daemon_mod
        orig_start = daemon_mod._start_idle_exiter

        def fast_start(activity, *, idle_seconds, stop, server, debug):
            # Re-implement with a tiny check interval for the test.
            import threading as th, time as tm

            def loop():
                while not stop.is_set():
                    stop.wait(0.05)
                    if stop.is_set():
                        return
                    if tm.monotonic() - activity.last_activity >= idle_seconds:
                        stop.set()
                        try:
                            server.close()
                        except Exception:
                            pass
                        return

            t = th.Thread(target=loop, name="idle-exiter-test", daemon=True)
            t.start()
            return t

        daemon_mod._start_idle_exiter = fast_start
        try:
            thread = _serve_in_thread(sock, engine, idle_exit_seconds=0.3)
            try:
                # Touch the daemon once, confirm it works.
                send_request(sock, "ping", timeout=2.0)
                assert engine.is_loaded is True

                # Wait past the idle window. The daemon should self-exit.
                time.sleep(0.7)
                thread.join(timeout=2.0)
                assert not thread.is_alive(), "daemon thread did not exit on idle"
                assert not Path(sock).exists(), "socket file not cleaned up"
            finally:
                _shutdown(sock, thread)
        finally:
            daemon_mod._start_idle_exiter = orig_start


def test_activity_resets_idle_timer():
    """Requests should keep the daemon alive as long as they keep arriving."""
    from macparakeet_cleanup.protocol import send_request, send_warmup
    from macparakeet_cleanup import daemon as daemon_mod

    orig_start = daemon_mod._start_idle_exiter

    def fast_start(activity, *, idle_seconds, stop, server, debug):
        import threading as th, time as tm

        def loop():
            while not stop.is_set():
                stop.wait(0.05)
                if stop.is_set():
                    return
                if tm.monotonic() - activity.last_activity >= idle_seconds:
                    stop.set()
                    try:
                        server.close()
                    except Exception:
                        pass
                    return

        t = th.Thread(target=loop, name="idle-exiter-test", daemon=True)
        t.start()
        return t

    daemon_mod._start_idle_exiter = fast_start
    try:
        with tempfile.TemporaryDirectory() as td:
            sock = str(Path(td) / "d.sock")
            engine = FakeEngine("fake")
            # 1.5s idle window; we'll ping every 0.3s for a while. Wide enough
            # margins to survive scheduler hiccups under CI load.
            thread = _serve_in_thread(sock, engine, idle_exit_seconds=1.5)
            try:
                # Send several requests inside the idle window.
                for _ in range(4):
                    send_warmup(sock, timeout=2.0)
                    time.sleep(0.3)
                # Daemon should still be alive — activity kept resetting the timer.
                assert thread.is_alive()
                assert Path(sock).exists()
                # Now stop pinging. It should exit shortly after.
                time.sleep(2.0)
                thread.join(timeout=2.0)
                assert not thread.is_alive()
            finally:
                _shutdown(sock, thread)
    finally:
        daemon_mod._start_idle_exiter = orig_start


def test_cli_warmup_flag_against_running_daemon():
    """End-to-end: CLI --warmup hits the daemon and exits 0."""
    with tempfile.TemporaryDirectory() as td:
        sock = str(Path(td) / "d.sock")
        engine = FakeEngine("fake")
        engine.load_delay_s = 0.3
        thread = _serve_in_thread(sock, engine, idle_exit_seconds=3600)
        try:
            r = subprocess.run(
                [str(PYTHON), "-m", "macparakeet_cleanup.cli",
                 "--warmup", "--no-spawn", "--socket", sock,
                 "--timeout", "2.0", "--debug"],
                capture_output=True, text=True, timeout=10, cwd=ROOT,
            )
            assert r.returncode == 0, r.stderr
            assert "warmup sent" in r.stderr
            # Wait for async load to finish.
            for _ in range(100):
                if engine.is_loaded:
                    break
                time.sleep(0.02)
            assert engine.is_loaded is True
        finally:
            _shutdown(sock, thread)


def test_cli_warmup_returns_nonzero_when_daemon_missing_no_spawn():
    r = subprocess.run(
        [str(PYTHON), "-m", "macparakeet_cleanup.cli",
         "--warmup", "--no-spawn",
         "--socket", "/tmp/macparakeet-cleanup-nope.sock", "--debug"],
        capture_output=True, text=True, timeout=5, cwd=ROOT,
    )
    assert r.returncode != 0
    assert "warmup failed" in r.stderr
