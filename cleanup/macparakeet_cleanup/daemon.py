"""Persistent cleanup daemon.

Listens on a Unix socket; serves requests sequentially (MLX is single-stream
on Apple Silicon — concurrent generations don't help and complicate cancellation).

The daemon never cold-starts the model per request; load happens once at boot.
"""

from __future__ import annotations

import argparse
import os
import signal
import socket
import sys
import threading
import time
from pathlib import Path

from .config import DEFAULT_SOCKET_PATH, DEFAULT_MODEL, LLM_TIMEOUT_SECONDS
from .llm import MLXEngine
from .protocol import read_request, send_response


def _log(msg: str, *, debug: bool) -> None:
    if debug:
        sys.stderr.write(f"[macparakeet-cleanupd] {msg}\n")
        sys.stderr.flush()


def serve(socket_path: str, model_id: str, *, debug: bool = False) -> None:
    sock_path = Path(socket_path)
    sock_path.parent.mkdir(parents=True, exist_ok=True)
    if sock_path.exists():
        sock_path.unlink()

    engine = MLXEngine(model_id)
    _log(f"loading model {model_id}…", debug=debug)
    t0 = time.perf_counter()
    engine.warmup()
    _log(f"model warm in {time.perf_counter()-t0:.1f}s", debug=debug)

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

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

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
                text = req.get("text", "")
                max_tokens = int(req.get("max_tokens", 150))
                t0 = time.perf_counter()
                cleaned = engine.clean(text, max_tokens=max_tokens)
                dt_ms = (time.perf_counter() - t0) * 1000
                _log(f"served {len(text)}ch in {dt_ms:.0f}ms", debug=debug)
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
            sock_path.unlink()
        except FileNotFoundError:
            pass


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="macparakeet-cleanupd")
    p.add_argument("--socket", default=DEFAULT_SOCKET_PATH)
    p.add_argument("--model", default=DEFAULT_MODEL)
    p.add_argument("--debug", action="store_true")
    args = p.parse_args(argv)
    serve(args.socket, args.model, debug=args.debug)
    return 0


if __name__ == "__main__":
    sys.exit(main())
