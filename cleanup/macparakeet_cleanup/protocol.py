"""Wire protocol between CLI client and daemon.

Each request is a single JSON line. Each response is a single JSON line.
Newline-delimited so we don't need a length prefix; cleanup payloads are tiny.

Cleanup request:  {"text": "...", "max_tokens": 150, "timeout": 0.9,
                   "prompt": "..." (optional — overrides default cleanup prompt)}
Warmup request:   {"warmup": true}
Response:         {"ok": true, "text": "..."}        (cleanup)
                  {"ok": true, "loaded": true|false} (warmup)
               or {"ok": false, "error": "..."}
"""

import json
import socket
from typing import Optional


def send_request(
    socket_path: str,
    text: str,
    max_tokens: int = 150,
    timeout: float = 1.5,
    prompt: Optional[str] = None,
) -> str:
    """Send a cleanup request to the daemon. Returns cleaned text or raises.

    If `prompt` is provided, it replaces the daemon's default cleanup prompt
    for this call. Callers using the daemon as a generic local LLM endpoint
    pass their own system prompt this way; cleanup-only callers omit it.
    """
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect(socket_path)
        body = {
            "text": text,
            "max_tokens": max_tokens,
            "timeout": timeout,
        }
        if prompt is not None:
            body["prompt"] = prompt
        payload = json.dumps(body) + "\n"
        sock.sendall(payload.encode("utf-8"))
        # Read response (single line).
        chunks = []
        while True:
            chunk = sock.recv(8192)
            if not chunk:
                break
            chunks.append(chunk)
            if b"\n" in chunk:
                break
        raw = b"".join(chunks).decode("utf-8").strip()
        if not raw:
            raise RuntimeError("daemon returned empty response")
        resp = json.loads(raw)
        if not resp.get("ok"):
            raise RuntimeError(resp.get("error", "unknown daemon error"))
        return resp["text"]
    finally:
        sock.close()


def read_request(conn: socket.socket) -> Optional[dict]:
    """Server-side: read a single JSON request line from a connection."""
    chunks = []
    while True:
        chunk = conn.recv(8192)
        if not chunk:
            break
        chunks.append(chunk)
        if b"\n" in chunk:
            break
    raw = b"".join(chunks).decode("utf-8").strip()
    if not raw:
        return None
    return json.loads(raw)


def send_response(conn: socket.socket, *, ok: bool, text: str = "", error: str = "") -> None:
    payload = {"ok": ok}
    if ok:
        payload["text"] = text
    else:
        payload["error"] = error
    conn.sendall((json.dumps(payload) + "\n").encode("utf-8"))


def send_warmup(socket_path: str, *, timeout: float = 0.5) -> None:
    """Fire-and-forget warmup ping. Returns as soon as the daemon ACKs receipt.

    The daemon dispatches the actual model load to a background thread, so this
    call returns in milliseconds even on a cold model. Raises only if the
    daemon is unreachable (e.g. socket missing).
    """
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect(socket_path)
        sock.sendall((json.dumps({"warmup": True}) + "\n").encode("utf-8"))
        # Read the small ACK response (don't block long).
        chunks = []
        while True:
            chunk = sock.recv(1024)
            if not chunk:
                break
            chunks.append(chunk)
            if b"\n" in chunk:
                break
        raw = b"".join(chunks).decode("utf-8").strip()
        if not raw:
            raise RuntimeError("daemon returned no warmup ack")
        resp = json.loads(raw)
        if not resp.get("ok"):
            raise RuntimeError(resp.get("error", "warmup failed"))
    finally:
        sock.close()
