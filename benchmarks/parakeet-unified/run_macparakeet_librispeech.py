#!/usr/bin/env python3
"""Run MacParakeet CLI on LibriSpeech test-clean and emit scorer JSONL.

The runner uses `transcribe --output-dir` instead of stdout transcript mode so
CoreML/E5RT diagnostics cannot contaminate hypotheses. It is intentionally
small and dependency-free; pair the generated JSONL with
`~/asr-bench/score_wer.py`.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def load_references(dataset: Path) -> dict[str, str]:
    refs: dict[str, str] = {}
    for trans_file in sorted(dataset.glob("*/*/*.trans.txt")):
        for line in trans_file.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            utt_id, text = line.split(" ", 1)
            refs[utt_id] = text
    return refs


def selected_audio(
    dataset: Path,
    refs: dict[str, str],
    limit: int | None,
    selection: str,
) -> list[Path]:
    files = [path for path in sorted(dataset.glob("*/*/*.flac")) if path.stem in refs]
    if limit is not None and selection == "first":
        files = files[:limit]
    elif limit is not None and limit < len(files):
        if limit == 1:
            files = [files[0]]
        else:
            span = len(files) - 1
            files = [files[round(i * span / (limit - 1))] for i in range(limit)]
    return files


def run_cli(cli: Path, files: list[Path], output_dir: Path, log_prefix: Path) -> float:
    command = [
        str(cli),
        "transcribe",
        *[str(path) for path in files],
        "--format",
        "transcript",
        "--output-dir",
        str(output_dir),
        "--engine",
        "parakeet",
        "--parakeet-model",
        "unified",
        "--speaker-detection",
        "off",
        "--no-history",
    ]
    started = time.monotonic()
    result = subprocess.run(
        command,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    elapsed = time.monotonic() - started
    log_prefix.with_suffix(".stdout.log").write_text(result.stdout, encoding="utf-8")
    log_prefix.with_suffix(".stderr.log").write_text(result.stderr, encoding="utf-8")
    if result.returncode != 0:
        raise SystemExit(
            f"macparakeet-cli exited {result.returncode}; see {log_prefix}.stderr.log"
        )
    return elapsed


def write_records(files: list[Path], refs: dict[str, str], output_dir: Path, records: Path) -> None:
    records.parent.mkdir(parents=True, exist_ok=True)
    with records.open("w", encoding="utf-8") as handle:
        for audio in files:
            transcript = output_dir / f"{audio.stem}.txt"
            if not transcript.exists():
                raise SystemExit(f"missing transcript output: {transcript}")
            rec = {
                "id": audio.stem,
                "ref": refs[audio.stem],
                "hyp": transcript.read_text(encoding="utf-8").strip(),
            }
            handle.write(json.dumps(rec, ensure_ascii=False) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--records", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--selection", choices=["first", "stride"], default="first")
    parser.add_argument("--keep-output", action="store_true")
    args = parser.parse_args()

    dataset = args.dataset.expanduser().resolve()
    cli = args.cli.expanduser().resolve()
    records = args.records.expanduser().resolve()

    if not dataset.exists():
        raise SystemExit(f"dataset not found: {dataset}")
    if not cli.exists():
        raise SystemExit(f"cli not found: {cli}")

    refs = load_references(dataset)
    files = selected_audio(dataset, refs, args.limit, args.selection)
    if not files:
        raise SystemExit("no matching .flac files found")

    if args.work_dir:
        work_dir = args.work_dir.expanduser().resolve()
        work_dir.mkdir(parents=True, exist_ok=True)
        cleanup = False
    else:
        work_dir = Path(tempfile.mkdtemp(prefix="macparakeet-unified-bench-"))
        cleanup = not args.keep_output

    output_dir = work_dir / "transcripts"
    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)

    log_prefix = work_dir / "macparakeet-cli"
    print(f"files={len(files)}")
    print(f"work_dir={work_dir}")
    elapsed = run_cli(cli, files, output_dir, log_prefix)
    write_records(files, refs, output_dir, records)
    print(f"records={records}")
    print(f"elapsed_seconds={elapsed:.2f}")

    if cleanup:
        shutil.rmtree(work_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
