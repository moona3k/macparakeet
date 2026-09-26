#!/usr/bin/env python3
"""Verify persisted and exported output from the known synthesized speech fixture."""

import json
from pathlib import Path
import re
import sys
import unicodedata


def normalized(text):
    return " ".join(unicodedata.normalize("NFKC", text).split())


def lexical_tokens(text):
    """Word runs and individual punctuation marks, ignoring whitespace entirely."""
    return re.findall(r"\w+|[^\w\s]", unicodedata.normalize("NFKC", text))


def contains_ordered_tokens(haystack, needle):
    if not needle:
        return True
    span = len(needle)
    return any(haystack[start:start + span] == needle for start in range(len(haystack) - span + 1))


def verify(directory):
    produced = json.loads((directory / "transcribe.json").read_text())
    rows = json.loads((directory / "history.json").read_text())
    if not isinstance(produced, dict):
        raise ValueError("transcription output must be a JSON object")
    if not isinstance(rows, list) or len(rows) != 1:
        raise ValueError("isolated history must contain exactly one transcription")
    persisted = rows[0]
    if not isinstance(persisted, dict):
        raise ValueError("history row must be a JSON object")
    for row in (produced, persisted):
        if row.get("engine") != "parakeet" or row.get("engineVariant") != "v3":
            raise ValueError("qualification did not use the selected Parakeet v3 engine")
    if not produced.get("id") or persisted.get("id") != produced["id"]:
        raise ValueError("fresh-process history returned a different transcription ID")
    if produced.get("status") != "completed" or persisted.get("status") != "completed":
        raise ValueError("transcription was not durably completed")
    for field in ("rawTranscript", "cleanTranscript"):
        if (produced.get(field) or "") != (persisted.get(field) or ""):
            raise ValueError(f"fresh-process history changed {field}")
    text = persisted.get("cleanTranscript") or persisted.get("rawTranscript") or ""
    if not isinstance(text, str) or not text.strip():
        raise ValueError("persisted transcript is empty")
    # Tolerate punctuation/case and one missed content word, but reject unrelated output.
    expected = {"short", "local", "audio", "transcription", "export"}
    found = expected.intersection(re.findall(r"\w+", normalized(text).casefold()))
    if len(found) < 4:
        raise ValueError(f"fixture content mismatch: found {sorted(found)}, need four of {sorted(expected)}")
    markdown = (directory / "export.md").read_text()
    markdown = re.sub(r"(?m)^\*\*\[\d+(?::\d+)+(?:\.\d+)?\]\*\*\s*", "", markdown)
    # Word timings can rejoin punctuation with different adjacent whitespace than the
    # saved transcript; compare ordered lexical/punctuation tokens instead of raw substrings.
    if not contains_ordered_tokens(lexical_tokens(markdown), lexical_tokens(text)):
        raise ValueError("Markdown export does not contain the persisted transcript")
    return {"result": "pass", "id": produced["id"], "matchedWords": sorted(found),
            "freshProcessRead": True, "exportContainsTranscript": True}


if __name__ == "__main__":
    try:
        print(json.dumps(verify(Path(sys.argv[1])), indent=2))
    except (ValueError, OSError, KeyError, TypeError, IndexError) as error:
        print(f"Release demo verification failed: {error}", file=sys.stderr)
        sys.exit(1)
