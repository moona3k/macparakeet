"""macparakeet-cleanup CLI — reads transcript text, writes cleaned text."""

from __future__ import annotations

import argparse
import sys
import time

from .config import DEFAULT_SOCKET_PATH, LLM_MAX_TOKENS_DEFAULT, LLM_TIMEOUT_SECONDS
from .complexity import is_complex
from .protocol import send_request
from .rules import clean_rules


def _read_input(args: argparse.Namespace) -> str:
    if args.text:
        return " ".join(args.text)
    data = sys.stdin.read()
    return data


def _llm_clean(text: str, *, socket_path: str, max_tokens: int, timeout: float) -> str:
    return send_request(
        socket_path,
        text,
        max_tokens=max_tokens,
        timeout=timeout,
    )


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="macparakeet-cleanup",
        description="Clean dictated transcripts (rules / local LLM / auto).",
    )
    p.add_argument("text", nargs="*", help="text to clean (else read stdin)")
    p.add_argument(
        "--mode",
        choices=("rules", "llm", "auto"),
        default="auto",
        help="cleanup strategy (default: auto)",
    )
    p.add_argument("--socket", default=DEFAULT_SOCKET_PATH)
    p.add_argument("--max-tokens", type=int, default=LLM_MAX_TOKENS_DEFAULT)
    p.add_argument(
        "--timeout",
        type=float,
        default=LLM_TIMEOUT_SECONDS,
        help="LLM hard timeout in seconds (default: 0.9)",
    )
    p.add_argument("--debug", action="store_true")
    args = p.parse_args(argv)

    text = _read_input(args).strip()
    if not text:
        return 0

    t0 = time.perf_counter()

    if args.mode == "rules":
        out = clean_rules(text)
        chosen = "rules"
    elif args.mode == "llm":
        try:
            out = _llm_clean(
                text,
                socket_path=args.socket,
                max_tokens=args.max_tokens,
                timeout=args.timeout,
            )
            chosen = "llm"
        except Exception as e:
            if args.debug:
                sys.stderr.write(f"[cleanup] llm failed: {e}; falling back to rules\n")
            out = clean_rules(text)
            chosen = "rules-fallback"
    else:  # auto
        if is_complex(text):
            try:
                out = _llm_clean(
                    text,
                    socket_path=args.socket,
                    max_tokens=args.max_tokens,
                    timeout=args.timeout,
                )
                chosen = "llm"
            except Exception as e:
                if args.debug:
                    sys.stderr.write(f"[cleanup] llm failed: {e}; falling back to rules\n")
                out = clean_rules(text)
                chosen = "rules-fallback"
        else:
            out = clean_rules(text)
            chosen = "rules"

    dt_ms = (time.perf_counter() - t0) * 1000
    if args.debug:
        sys.stderr.write(f"[cleanup] mode={chosen} latency={dt_ms:.0f}ms\n")

    sys.stdout.write(out)
    if not out.endswith("\n"):
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
