"""Tests for the CLI: stdin and argv input, mode selection, fallback."""

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# Prefer the project venv when present, otherwise fall back to the interpreter
# pytest is running under. Hard-coding `.venv/bin/python` made the suite fail
# on contributor machines that don't bootstrap a venv.
_VENV_PY = ROOT / ".venv" / "bin" / "python"
PYTHON = _VENV_PY if _VENV_PY.exists() else Path(sys.executable)


def _run(args: list[str], *, stdin: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(PYTHON), "-m", "macparakeet_cleanup.cli", *args],
        input=stdin,
        capture_output=True,
        text=True,
        cwd=ROOT,
        timeout=30,
    )


def test_cli_argv_rules():
    r = _run(["--mode", "rules", "um", "the", "the", "cat"])
    assert r.returncode == 0
    assert r.stdout.strip() == "The cat."


def test_cli_stdin_rules():
    r = _run(["--mode", "rules"], stdin="uh hello world")
    assert r.returncode == 0
    assert r.stdout.strip() == "Hello world."


def test_cli_no_extra_logging_without_debug():
    r = _run(["--mode", "rules", "hello"])
    assert r.stderr == ""


def test_cli_debug_flag_emits_stderr():
    r = _run(["--debug", "--mode", "rules", "hello"])
    assert "mode=" in r.stderr


def test_cli_empty_input_yields_empty():
    r = _run(["--mode", "rules"], stdin="")
    assert r.returncode == 0
    assert r.stdout == ""


def test_cli_llm_falls_back_to_rules_when_daemon_missing_no_spawn(tmp_path):
    # With --no-spawn, the CLI must not auto-spawn the daemon; LLM fails;
    # the output should be the rules-cleaned version.
    r = _run([
        "--mode", "llm",
        "--no-spawn",
        "--socket", str(tmp_path / "missing.sock"),
        "--debug",
        "um hello world",
    ])
    assert r.returncode == 0
    assert r.stdout.strip() == "Hello world."
    assert "rules-fallback" in r.stderr


def test_cli_auto_uses_rules_for_short_input_no_spawn(tmp_path):
    r = _run([
        "--mode", "auto",
        "--no-spawn",
        "--socket", str(tmp_path / "missing.sock"),
        "--debug",
        "hello world",
    ])
    assert r.returncode == 0
    # Short, simple input — auto should pick rules and never touch daemon.
    assert r.stdout.strip() == "Hello world."
    assert "mode=rules" in r.stderr


def test_cli_rules_mode_ignores_prompt():
    """Rules path is deterministic regex; --prompt must not change its behavior."""
    r = _run([
        "--mode", "rules",
        "--prompt", "Translate to French.",
        "um the the cat",
    ])
    assert r.returncode == 0
    assert r.stdout.strip() == "The cat."


def test_cli_apply_prompt_interpolation():
    """Unit-level: a prompt with {{transcript}} substitutes and clears system override."""
    from macparakeet_cleanup.cli import _apply_prompt

    user, system = _apply_prompt("hello", "Clean this: {{transcript}}")
    assert user == "Clean this: hello"
    assert system is None


def test_cli_apply_prompt_no_placeholder_uses_system_override():
    """Unit-level: a prompt without {{transcript}} becomes the system prompt."""
    from macparakeet_cleanup.cli import _apply_prompt

    user, system = _apply_prompt("hello", "You are a cleanup model.")
    assert user == "hello"
    assert system == "You are a cleanup model."


def test_cli_apply_prompt_none_passes_through():
    """Unit-level: no override prompt → daemon defaults stay."""
    from macparakeet_cleanup.cli import _apply_prompt

    user, system = _apply_prompt("hello", None)
    assert user == "hello"
    assert system is None


def test_cli_resolve_prompt_file_wins_over_literal(tmp_path):
    """Unit-level: --prompt-file beats --prompt when both are set."""
    import argparse
    from macparakeet_cleanup.cli import _resolve_prompt

    prompt_path = tmp_path / "p.txt"
    prompt_path.write_text("from-file")

    args = argparse.Namespace(
        prompt="from-literal",
        prompt_file=str(prompt_path),
    )
    assert _resolve_prompt(args) == "from-file"
