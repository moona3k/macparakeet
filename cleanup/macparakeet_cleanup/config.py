"""Shared configuration constants."""

import os
from pathlib import Path

DEFAULT_SOCKET_PATH = os.environ.get(
    "MACPARAKEET_CLEANUP_SOCKET",
    str(Path.home() / "Library" / "Application Support" / "MacParakeet" / "cleanup.sock"),
)

DEFAULT_MODEL = "mlx-community/Qwen2.5-3B-Instruct-4bit"
ALT_MODEL = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"

LLM_PROMPT = (
    "Clean this dictated text into a concise message. "
    "Remove filler words, false starts, and repetitions. "
    "Preserve the original meaning. Do not add new information. "
    "Format it as clean text suitable to send as a message. "
    "Return only the cleaned message."
)

LLM_MAX_TOKENS_DEFAULT = 150
LLM_TIMEOUT_SECONDS = 0.9
