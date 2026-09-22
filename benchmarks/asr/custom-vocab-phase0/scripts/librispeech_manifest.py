#!/usr/bin/env python3
"""Emit a JSONL manifest from a LibriSpeech split directory."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def iter_librispeech(split_dir: Path):
    for transcript in sorted(split_dir.glob("*/*/*.trans.txt")):
        by_id: dict[str, str] = {}
        with transcript.open("r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                utt_id, text = line.split(" ", 1)
                by_id[utt_id] = text
        for utt_id in sorted(by_id):
            audio = transcript.parent / f"{utt_id}.flac"
            if audio.exists():
                yield {"id": utt_id, "ref": by_id[utt_id], "audio": str(audio)}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--split-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--limit", type=int)
    args = parser.parse_args()

    if not args.split_dir.is_dir():
        parser.error(f"split directory does not exist or is not a directory: {args.split_dir}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with args.output.open("w", encoding="utf-8") as handle:
        for row in iter_librispeech(args.split_dir):
            if args.limit is not None and count >= args.limit:
                break
            handle.write(json.dumps(row, ensure_ascii=True, sort_keys=True) + "\n")
            count += 1
    print(f"Wrote {count} rows to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
