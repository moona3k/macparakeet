"""macparakeet-cleanup CLI — reads transcript text, writes cleaned text."""

from __future__ import annotations

import argparse
import sys
import time

from .config import (
    DEFAULT_MODEL,
    DEFAULT_SOCKET_PATH,
    LLM_MAX_TOKENS_DEFAULT,
    LLM_TIMEOUT_SECONDS,
)
from .complexity import is_complex
from .protocol import send_request, send_warmup
from .rules import clean_rules
from .spawn import ensure_daemon


# Matches MacParakeet's `AIFormatter.transcriptPlaceholder`. Lowercase form
# is also accepted for ergonomic CLI use.
TRANSCRIPT_PLACEHOLDERS = ("{{TRANSCRIPT}}", "{{transcript}}")


def _read_input(args: argparse.Namespace) -> str:
    if args.text:
        return " ".join(args.text)
    data = sys.stdin.read()
    return data


def _resolve_prompt(args: argparse.Namespace) -> str | None:
    """Resolve the optional override system prompt from --prompt-file or --prompt.

    --prompt-file wins if both are provided. Returns None when no override is
    set, in which case the daemon's built-in cleanup prompt is used.
    """
    if args.prompt_file:
        with open(args.prompt_file, "r", encoding="utf-8") as f:
            return f.read()
    if args.prompt is not None:
        return args.prompt
    return None


def _apply_prompt(transcript: str, prompt: str | None) -> tuple[str, str | None]:
    """Decide how to combine transcript + override prompt.

    Returns (user_text, system_prompt_override).

    - No override prompt → (transcript, None). Daemon uses its built-in prompt.
    - Override contains {{TRANSCRIPT}} (or {{transcript}}) → substitute and
      send the result as the user message. System prompt stays at the daemon
      default. This matches MacParakeet's existing formatter template shape.
    - Override has no placeholder → treat it as a custom system prompt;
      transcript becomes the user message.
    """
    if prompt is None:
        return transcript, None
    for placeholder in TRANSCRIPT_PLACEHOLDERS:
        if placeholder in prompt:
            return prompt.replace(placeholder, transcript), None
    return transcript, prompt


def _llm_clean(
    text: str,
    *,
    socket_path: str,
    max_tokens: int,
    timeout: float,
    prompt: str | None,
) -> str:
    return send_request(
        socket_path,
        text,
        max_tokens=max_tokens,
        timeout=timeout,
        prompt=prompt,
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
    p.add_argument(
        "--warmup",
        action="store_true",
        help="ping the daemon to start loading the model in the background, then exit",
    )
    p.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help="model the auto-spawned daemon should load",
    )
    p.add_argument(
        "--no-spawn",
        action="store_true",
        help="don't auto-spawn the daemon if it isn't running",
    )
    p.add_argument(
        "--prompt",
        default=None,
        help=(
            "override system prompt as a literal string. If it contains "
            "{{transcript}}, that placeholder is substituted with the input "
            "and the result is sent as the user message; otherwise the "
            "string is used as the system prompt and the input is the user "
            "message. Only applies in LLM mode (rules ignore it)."
        ),
    )
    p.add_argument(
        "--prompt-file",
        default=None,
        help="read --prompt from a file path. Wins over --prompt if both set.",
    )
    p.add_argument("--debug", action="store_true")
    args = p.parse_args(argv)

    def _ensure() -> bool:
        """Ensure the daemon is alive. If we just spawned it, warm it up
        eagerly and bump the request timeout to absorb the model load."""
        if args.no_spawn:
            return True  # caller takes responsibility
        alive, spawned = ensure_daemon(args.socket, model=args.model, debug=args.debug)
        if not alive:
            if args.debug:
                sys.stderr.write("[cleanup] daemon auto-spawn failed\n")
            return False
        if spawned:
            if args.debug:
                sys.stderr.write("[cleanup] daemon spawned; warming up\n")
            try:
                send_warmup(args.socket, timeout=2.0)
            except Exception:
                pass
            # The daemon is up but the model is still loading. The first
            # cleanup call after a spawn pays the full load latency, so
            # widen the timeout for this run.
            args.timeout = max(args.timeout, 5.0)
        return True

    if args.warmup:
        _ensure()
        try:
            send_warmup(args.socket, timeout=args.timeout)
            if args.debug:
                sys.stderr.write("[cleanup] warmup sent\n")
            return 0
        except Exception as e:
            if args.debug:
                sys.stderr.write(f"[cleanup] warmup failed: {e}\n")
            return 1

    text = _read_input(args).strip()
    if not text:
        return 0

    override_prompt = _resolve_prompt(args)

    t0 = time.perf_counter()

    def run_llm() -> str:
        user_text, system_override = _apply_prompt(text, override_prompt)
        return _llm_clean(
            user_text,
            socket_path=args.socket,
            max_tokens=args.max_tokens,
            timeout=args.timeout,
            prompt=system_override,
        )

    if args.mode == "rules":
        out = clean_rules(text)
        chosen = "rules"
    elif args.mode == "llm":
        _ensure()
        try:
            out = run_llm()
            chosen = "llm"
        except Exception as e:
            if args.debug:
                sys.stderr.write(f"[cleanup] llm failed: {e}; falling back to rules\n")
            out = clean_rules(text)
            chosen = "rules-fallback"
    else:  # auto
        if is_complex(text):
            _ensure()
            try:
                out = run_llm()
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
