"""Heuristic for auto mode: is this transcript 'rambly enough' to need an LLM?

We bias toward rules-only because rules are ~1000x faster. The LLM is reserved
for inputs where rules are likely to leave a mess: long, very repetitive, or
heavy with false-start markers.
"""

import re

_HARD_FILLER_RE = re.compile(r"(?i)\b(um|uh|ah|er|erm|umm|uhh|hmm)\b")
_FALSE_START_RE = re.compile(r"[—–-]{1,2}|\.\.\.")


def _filler_density(text: str) -> float:
    words = text.split()
    if not words:
        return 0.0
    return len(_HARD_FILLER_RE.findall(text)) / len(words)


def _repetition_density(text: str) -> float:
    """Fraction of word tokens that are part of an adjacent duplicate."""
    words = re.findall(r"\w+", text.lower())
    if len(words) < 2:
        return 0.0
    dup = sum(1 for a, b in zip(words, words[1:]) if a == b)
    return dup / len(words)


def is_complex(text: str) -> bool:
    """Return True if the text likely benefits from LLM rewrite."""
    n_words = len(text.split())
    if n_words >= 60:
        return True
    if _filler_density(text) >= 0.10:
        return True
    if _repetition_density(text) >= 0.05:
        return True
    if len(_FALSE_START_RE.findall(text)) >= 2:
        return True
    # Multiple "I mean" / "you know" clusters suggest stream-of-consciousness.
    soft = len(re.findall(r"(?i)\b(you know|i mean|sort of|kind of)\b", text))
    if soft >= 2:
        return True
    return False
