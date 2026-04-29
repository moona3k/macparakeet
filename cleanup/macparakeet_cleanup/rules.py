"""Deterministic rules-based dictation cleanup.

Designed for <100ms on short dictations. Pure Python, regex-only.
Order matters: filler removal → repetition collapse → spacing/punctuation/casing.
"""

import re

# Standalone filler tokens (always safe to remove anywhere).
_HARD_FILLERS = {"um", "uh", "ah", "er", "erm", "umm", "uhh", "hmm"}

# Soft fillers — removed only at sentence start or as parenthetical asides
# ("like, I think..." → "I think..."). Mid-sentence "like" is preserved
# because it has real meaning ("a tool like this").
_SOFT_FILLER_PHRASES = [
    "you know",
    "i mean",
    "sort of",
    "kind of",
    "basically",
]
_SOFT_FILLER_WORDS = ["like", "actually", "literally"]

# Sentence terminators we recognize for capitalization rules.
_SENT_END = re.compile(r"([.!?])\s+")


def _strip_hard_fillers(text: str) -> str:
    """Remove um/uh/etc as standalone tokens, including trailing comma."""
    pattern = re.compile(
        r"(?i)(?<![A-Za-z'])(" + "|".join(_HARD_FILLERS) + r")(?![A-Za-z'])[,]?\s*"
    )
    return pattern.sub("", text)


def _strip_soft_fillers(text: str) -> str:
    """Remove soft fillers when bracketed by commas or at clause starts."""
    out = text
    for phrase in _SOFT_FILLER_PHRASES:
        # ", you know," → ", "
        out = re.sub(rf"(?i),\s*{re.escape(phrase)}\s*,", ",", out)
        # leading "you know, " at start of string or after sentence end
        out = re.sub(rf"(?i)(^|[.!?]\s+){re.escape(phrase)},\s*", r"\1", out)
        # trailing ", you know." → "."
        out = re.sub(rf"(?i),\s*{re.escape(phrase)}([.!?])", r"\1", out)
    for word in _SOFT_FILLER_WORDS:
        # ", like," → ", "
        out = re.sub(rf"(?i),\s*{re.escape(word)}\s*,", ",", out)
        # leading "like, " at sentence start
        out = re.sub(rf"(?i)(^|[.!?]\s+){re.escape(word)},\s+", r"\1", out)
    return out


def _collapse_word_repeats(text: str) -> str:
    """Collapse adjacent duplicate words: 'the the cat' → 'the cat'."""
    # Repeat until stable to handle 'the the the'.
    prev = None
    cur = text
    while prev != cur:
        prev = cur
        cur = re.sub(r"(?i)\b(\w+)(\s+\1\b)+", r"\1", cur)
    return cur


def _collapse_phrase_repeats(text: str) -> str:
    """Collapse adjacent repeated 2-4 word phrases.

    'I think I think we should' → 'I think we should'
    'we should we should go' → 'we should go'
    """
    prev = None
    cur = text
    while prev != cur:
        prev = cur
        # 4-word, 3-word, 2-word phrase repeats.
        for n in (4, 3, 2):
            cur = re.sub(
                r"(?i)\b((?:\w+\W+){" + str(n - 1) + r"}\w+)\W+\1\b",
                r"\1",
                cur,
            )
    return cur


def _collapse_sentence_restarts(text: str) -> str:
    """Collapse 'I went to, I went to the store' → 'I went to the store'.

    Detects a partial clause followed by a comma/dash and a longer restart
    that begins with the same prefix.
    """
    # "X X X, X X X Y Y" where the second clause starts with the first.
    pattern = re.compile(
        r"(?i)\b((?:\w+\W+){1,5}\w+)\s*[,—-]+\s*\1\b"
    )
    prev = None
    cur = text
    while prev != cur:
        prev = cur
        cur = pattern.sub(r"\1", cur)
    return cur


def _fix_spacing(text: str) -> str:
    out = text
    out = re.sub(r"\s+", " ", out)
    out = re.sub(r"\s+([,.!?;:])", r"\1", out)
    out = re.sub(r"([,.!?;:])(?=[^\s\d])", r"\1 ", out)
    out = re.sub(r",\s*,+", ",", out)
    out = re.sub(r"\.\s*\.\s*\.", "…", out)  # preserve real ellipses
    out = re.sub(r"\s+([,.!?])", r"\1", out)
    # Strip leading punctuation/comma left over from filler removal.
    out = re.sub(r"^[\s,;:]+", "", out)
    return out.strip()


def _fix_capitalization(text: str) -> str:
    if not text:
        return text

    def cap(m: re.Match) -> str:
        return m.group(0).upper()

    # First letter.
    out = re.sub(r"^[a-z]", cap, text)
    # After sentence terminators.
    out = re.sub(r"([.!?]\s+)([a-z])", lambda m: m.group(1) + m.group(2).upper(), out)
    # Standalone "i" → "I".
    out = re.sub(r"\bi\b", "I", out)
    out = re.sub(r"\bi'(m|ll|ve|d|re)\b", lambda m: "I'" + m.group(1), out)
    return out


def _ensure_terminal_punctuation(text: str) -> str:
    if not text:
        return text
    if text[-1] not in ".!?…":
        text += "."
    return text


def clean_rules(text: str) -> str:
    """Apply the full deterministic cleanup pipeline."""
    if not text or not text.strip():
        return ""
    out = text.strip()
    out = _strip_hard_fillers(out)
    out = _strip_soft_fillers(out)
    out = _collapse_phrase_repeats(out)
    out = _collapse_sentence_restarts(out)
    out = _collapse_word_repeats(out)
    out = _fix_spacing(out)
    out = _fix_capitalization(out)
    out = _ensure_terminal_punctuation(out)
    return out
