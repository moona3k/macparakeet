"""Persistent cleanup daemon.

Listens on a Unix socket; serves requests sequentially (MLX is single-stream
on Apple Silicon — concurrent generations don't help and complicate cancellation).

Lifecycle:
  - On boot, the daemon does NOT load the model (lazy by default). The socket
    binds and listens immediately; the process is cheap until first use.
  - The model loads on the first cleanup request (cold call pays load latency).
  - A `warmup` request triggers an async load and returns ~immediately, so a
    caller can pre-heat the model before a real cleanup arrives.
  - The daemon exits after `--idle-exit-seconds` of no requests (30 min by
    default). Auto-spawned daemons clean themselves up; users don't have to
    manage the process.
  - Pass `--eager-load` to load on boot (old behavior).
"""

from __future__ import annotations

import argparse
import os
import socket
import signal
import stat
import sys
import threading
import time
from pathlib import Path

from .config import DEFAULT_SOCKET_PATH, DEFAULT_MODEL
from .llm import MLXEngine
from .protocol import read_request, send_response


DEFAULT_IDLE_EXIT_SECONDS = 30 * 60  # 30 minutes


def _unlink_if_socket(path: Path) -> None:
    """Remove `path` only if it's a Unix socket. Refuses to delete regular
    files or directories — protects the user from a misconfigured
    --socket pointing at real data."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return
    if not stat.S_ISSOCK(st.st_mode):
        raise RuntimeError(
            f"refusing to unlink non-socket path at {path!r} (mode={st.st_mode:o})"
        )
    path.unlink()


def _log(msg: str, *, debug: bool) -> None:
    if debug:
        sys.stderr.write(f"[macparakeet-cleanupd] {msg}\n")
        sys.stderr.flush()


class _ActivityTracker:
    """Records the last time the daemon saw a request (cleanup or warmup)."""

    def __init__(self) -> None:
        self.last_activity = time.monotonic()

    def touch(self) -> None:
        self.last_activity = time.monotonic()


def _start_idle_exiter(
    activity: _ActivityTracker,
    *,
    idle_seconds: float,
    stop: threading.Event,
    server: socket.socket,
    debug: bool,
) -> threading.Thread:
    """Background thread that exits the daemon after idle_seconds of inactivity."""

    def loop() -> None:
        interval = min(60.0, max(5.0, idle_seconds / 4))
        while not stop.is_set():
            stop.wait(interval)
            if stop.is_set():
                return
            idle_for = time.monotonic() - activity.last_activity
            if idle_for >= idle_seconds:
                _log(
                    f"idle for {idle_for:.0f}s ≥ {idle_seconds:.0f}s — exiting",
                    debug=debug,
                )
                stop.set()
                # Unblock the accept() so the main loop can drop out cleanly.
                try:
                    server.close()
                except Exception:
                    pass
                return

    t = threading.Thread(target=loop, name="idle-exiter", daemon=True)
    t.start()
    return t


def _start_async_load(engine: MLXEngine, *, debug: bool) -> None:
    """Kick off a background model load if not already loaded/loading."""
    if engine.is_loaded:
        return

    def run() -> None:
        try:
            t0 = time.perf_counter()
            engine.load()
            _log(
                f"warmup load complete in {time.perf_counter() - t0:.1f}s",
                debug=debug,
            )
        except Exception as e:
            _log(f"warmup load failed: {e}", debug=debug)

    threading.Thread(target=run, name="warmup-loader", daemon=True).start()


def serve(
    socket_path: str,
    model_id: str,
    *,
    debug: bool = False,
    idle_exit_seconds: float = DEFAULT_IDLE_EXIT_SECONDS,
    eager_load: bool = False,
) -> None:
    sock_path = Path(socket_path)
    sock_path.parent.mkdir(parents=True, exist_ok=True)
    _unlink_if_socket(sock_path)

    engine = MLXEngine(model_id)
    mode = "eager" if eager_load else "lazy-load"
    _log(
        f"ready ({mode}, model={model_id}, "
        f"idle-exit={idle_exit_seconds:.0f}s)",
        debug=debug,
    )

    if eager_load:
        _log("eager-load: warming up now…", debug=debug)
        t0 = time.perf_counter()
        engine.warmup()
        _log(f"eager-load complete in {time.perf_counter() - t0:.1f}s", debug=debug)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(sock_path))
    sock_path.chmod(0o600)
    server.listen(8)
    _log(f"listening on {sock_path}", debug=debug)

    stop = threading.Event()

    def shutdown(*_args):
        stop.set()
        try:
            server.close()
        except Exception:
            pass

    # Signal handlers can only be installed from the main thread. Tests run
    # serve() in a worker thread; skip handler install in that case.
    if threading.current_thread() is threading.main_thread():
        signal.signal(signal.SIGINT, shutdown)
        signal.signal(signal.SIGTERM, shutdown)

    activity = _ActivityTracker()
    _start_idle_exiter(
        activity,
        idle_seconds=idle_exit_seconds,
        stop=stop,
        server=server,
        debug=debug,
    )

    try:
        while not stop.is_set():
            try:
                conn, _ = server.accept()
            except OSError:
                break
            try:
                req = read_request(conn)
                if req is None:
                    send_response(conn, ok=False, error="empty request")
                    continue
                activity.touch()

                if req.get("warmup"):
                    already = engine.is_loaded
                    _start_async_load(engine, debug=debug)
                    send_response(conn, ok=True, text="")
                    _log(f"warmup ack (already_loaded={already})", debug=debug)
                    continue

                text = req.get("text", "")
                max_tokens = int(req.get("max_tokens", 150))
                prompt = req.get("prompt")
                t0 = time.perf_counter()
                cleaned = engine.clean(text, max_tokens=max_tokens, prompt=prompt)
                dt_ms = (time.perf_counter() - t0) * 1000
                custom = " custom-prompt" if prompt else ""
                _log(f"served {len(text)}ch in {dt_ms:.0f}ms{custom}", debug=debug)
                send_response(conn, ok=True, text=cleaned)
            except Exception as e:
                try:
                    send_response(conn, ok=False, error=str(e))
                except Exception:
                    pass
            finally:
                conn.close()
    finally:
        try:
            _unlink_if_socket(sock_path)
        except (FileNotFoundError, RuntimeError):
            pass


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="macparakeet-cleanupd")
    p.add_argument("--socket", default=DEFAULT_SOCKET_PATH)
    p.add_argument("--model", default=DEFAULT_MODEL)
    p.add_argument(
        "--idle-exit-seconds",
        type=float,
        default=DEFAULT_IDLE_EXIT_SECONDS,
        help="exit daemon after this many idle seconds (default: 1800)",
    )
    p.add_argument(
        "--eager-load",
        action="store_true",
        help="load model on boot (default: lazy load on first request)",
    )
    p.add_argument("--debug", action="store_true")
    args = p.parse_args(argv)

    serve(
        args.socket,
        args.model,
        debug=args.debug,
        idle_exit_seconds=args.idle_exit_seconds,
        eager_load=args.eager_load,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
