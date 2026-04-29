"""Tests for the CLI: stdin and argv input, mode selection, fallback."""

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PYTHON = ROOT / ".venv" / "bin" / "python"


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


def test_cli_llm_falls_back_to_rules_when_daemon_missing():
    # Point at a socket that doesn't exist; daemon failure should fall back.
    r = _run([
        "--mode", "llm",
        "--socket", "/tmp/macparakeet-cleanup-nonexistent-xyz.sock",
        "--debug",
        "um hello world",
    ])
    assert r.returncode == 0
    # The output should be the rules-cleaned version.
    assert r.stdout.strip() == "Hello world."
    assert "rules-fallback" in r.stderr


def test_cli_auto_uses_rules_for_short_input():
    r = _run([
        "--mode", "auto",
        "--socket", "/tmp/macparakeet-cleanup-nonexistent-xyz.sock",
        "--debug",
        "hello world",
    ])
    assert r.returncode == 0
    # Short, simple input — auto should pick rules and never touch daemon.
    assert r.stdout.strip() == "Hello world."
    assert "mode=rules" in r.stderr
