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
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

_WORD_RE = re.compile(r"[^A-Z0-9]+")


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


def run_cli(
    cli: Path,
    files: list[Path],
    output_dir: Path,
    log_prefix: Path,
    parakeet_model: str,
) -> float:
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
        parakeet_model,
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


def words_for_wer(text: str) -> list[str]:
    return _WORD_RE.sub(" ", text.upper().replace("'", "")).split()


def edit_counts(reference: list[str], hypothesis: list[str]) -> tuple[int, int, int]:
    rows = len(reference) + 1
    cols = len(hypothesis) + 1
    costs = [[0] * cols for _ in range(rows)]
    counts = [[(0, 0, 0)] * cols for _ in range(rows)]

    for i in range(1, rows):
        costs[i][0] = i
        counts[i][0] = (0, i, 0)
    for j in range(1, cols):
        costs[0][j] = j
        counts[0][j] = (0, 0, j)

    for i in range(1, rows):
        for j in range(1, cols):
            candidates: list[tuple[int, tuple[int, int, int]]] = []

            sub_count, del_count, ins_count = counts[i - 1][j - 1]
            substitution = 0 if reference[i - 1] == hypothesis[j - 1] else 1
            candidates.append(
                (
                    costs[i - 1][j - 1] + substitution,
                    (sub_count + substitution, del_count, ins_count),
                )
            )

            sub_count, del_count, ins_count = counts[i - 1][j]
            candidates.append((costs[i - 1][j] + 1, (sub_count, del_count + 1, ins_count)))

            sub_count, del_count, ins_count = counts[i][j - 1]
            candidates.append((costs[i][j - 1] + 1, (sub_count, del_count, ins_count + 1)))

            costs[i][j], counts[i][j] = min(candidates, key=lambda item: item[0])

    return counts[-1][-1]


def score_records(records: Path) -> tuple[int, int, int, int, int]:
    files = 0
    ref_words = 0
    substitutions = 0
    deletions = 0
    insertions = 0

    for line in records.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        rec = json.loads(line)
        ref = words_for_wer(rec["ref"])
        hyp = words_for_wer(rec["hyp"])
        sub_count, del_count, ins_count = edit_counts(ref, hyp)
        files += 1
        ref_words += len(ref)
        substitutions += sub_count
        deletions += del_count
        insertions += ins_count

    return files, ref_words, substitutions, deletions, insertions


def print_score(records: Path) -> None:
    files, ref_words, substitutions, deletions, insertions = score_records(records)
    errors = substitutions + deletions + insertions
    wer = (errors / ref_words * 100) if ref_words else 0.0
    print(f"files={files} ref_words={ref_words} S={substitutions} D={deletions} I={insertions}")
    print(f"CORPUS WER = {wer:.2f}%")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", type=Path)
    parser.add_argument("--cli", type=Path)
    parser.add_argument("--records", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--selection", choices=["first", "stride"], default="first")
    parser.add_argument("--parakeet-model", choices=["v2", "v3", "unified"], default="unified")
    parser.add_argument("--keep-output", action="store_true")
    parser.add_argument("--score-only", action="store_true")
    args = parser.parse_args()

    records = args.records.expanduser().resolve()

    if args.score_only:
        print_score(records)
        return 0

    if args.dataset is None:
        parser.error("--dataset is required unless --score-only is set")
    if args.cli is None:
        parser.error("--cli is required unless --score-only is set")

    dataset = args.dataset.expanduser().resolve()
    cli = args.cli.expanduser().resolve()

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
    elapsed = run_cli(cli, files, output_dir, log_prefix, args.parakeet_model)
    write_records(files, refs, output_dir, records)
    print(f"records={records}")
    print(f"elapsed_seconds={elapsed:.2f}")
    print_score(records)

    if cleanup:
        shutil.rmtree(work_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
