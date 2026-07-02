#!/usr/bin/env python3
"""Tests for the ASR benchmark manifest contract."""
from __future__ import annotations

import copy
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import manifest_tool

_fails: list[str] = []
_HERE = Path(__file__).resolve().parent


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"  ok   {name}")
    else:
        _fails.append(name)
        suffix = f": {detail}" if detail else ""
        print(f"  FAIL {name}{suffix}")


def test_manifest_validates() -> None:
    print("manifest validation:")
    data = manifest_tool.load_manifest(_HERE / "manifest.json")
    errors = manifest_tool.validate_manifest(data)
    check("manifest has no validation errors", errors == [], "; ".join(errors))


def test_manifest_covers_shipping_engines() -> None:
    print("shipping engine coverage:")
    data = manifest_tool.load_manifest(_HERE / "manifest.json")
    engine_ids = {engine["id"] for engine in data["engines"]}
    expected = {
        "parakeet-v2",
        "parakeet-v3",
        "parakeet-unified",
        "nemotron-en",
        "nemotron-multi",
        "whisper",
        "cohere",
    }
    check("all shipping/evaluated engines listed", expected <= engine_ids, str(expected - engine_ids))
    cohere = next(engine for engine in data["engines"] if engine["id"] == "cohere")
    check("cohere excluded from live preview", "dictation_live_preview" not in cohere["product_surfaces"])
    check("cohere caveat records no auto-detect", "no auto language detection" in cohere["caveat"])


def test_summary_mentions_gates() -> None:
    print("summary rendering:")
    data = manifest_tool.load_manifest(_HERE / "manifest.json")
    summary = manifest_tool.markdown_summary(data)
    check("summary includes full English task", "English full-set accuracy" in summary)
    check("summary includes Cohere engine", "Cohere Transcribe" in summary)
    check("summary includes product surface code", "`file_media`" in summary)


def test_unknown_references_fail() -> None:
    print("negative validation:")
    data = manifest_tool.load_manifest(_HERE / "manifest.json")
    broken = copy.deepcopy(data)
    broken["tasks"][0]["engines"].append("missing-engine")
    errors = manifest_tool.validate_manifest(broken)
    check("unknown engine rejected", any("missing-engine" in error for error in errors), str(errors))


def main() -> int:
    for test in (
        test_manifest_validates,
        test_manifest_covers_shipping_engines,
        test_summary_mentions_gates,
        test_unknown_references_fail,
    ):
        test()
    print()
    if _fails:
        print(f"FAILED {len(_fails)}: {', '.join(_fails)}")
        return 1
    print("all manifest tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
