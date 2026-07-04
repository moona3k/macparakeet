#!/usr/bin/env python3
"""Generate deterministic macOS say audio for the Phase 0 OOV manifest."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read_jsonl(path: Path) -> list[dict]:
    rows: list[dict] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def installed_voices() -> set[str]:
    proc = subprocess.run(["say", "-v", "?"], check=True, text=True, capture_output=True)
    voices: set[str] = set()
    for line in proc.stdout.splitlines():
        if not line.strip():
            continue
        # Voice names occupy the first fixed-width column before the locale.
        locale_pos = line.find(" en_")
        if locale_pos == -1:
            continue
        voices.add(line[:locale_pos].rstrip())
    return voices


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=ROOT / "oov_utterances.jsonl")
    parser.add_argument("--output", type=Path, default=ROOT / "generated" / "oov_manifest.jsonl")
    parser.add_argument("--audio-dir", type=Path, default=ROOT / "generated" / "oov-audio")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    rows = read_jsonl(args.input)
    voices = installed_voices()
    missing = sorted({row["voice"] for row in rows if row["voice"] not in voices})
    if missing:
        raise SystemExit(f"Missing macOS say voices: {', '.join(missing)}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.audio_dir.mkdir(parents=True, exist_ok=True)

    out_rows: list[dict] = []
    for row in rows:
        audio_path = args.audio_dir / f"{row['id']}.aiff"
        if args.force or not audio_path.exists():
            subprocess.run(
                [
                    "say",
                    "-v",
                    row["voice"],
                    "-r",
                    str(row["rate"]),
                    "-o",
                    str(audio_path),
                    row["ref"],
                ],
                check=True,
            )
        out_row = dict(row)
        out_row["audio"] = audio_path.relative_to(args.output.parent).as_posix()
        out_rows.append(out_row)

    with args.output.open("w", encoding="utf-8") as handle:
        for row in out_rows:
            handle.write(json.dumps(row, ensure_ascii=True, sort_keys=True) + "\n")

    print(f"Wrote {len(out_rows)} utterances to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
