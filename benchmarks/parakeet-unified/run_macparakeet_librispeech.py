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

PUNCT_RE = re.compile(r"[^\w\s']", flags=re.UNICODE)
APOS_RE = re.compile(r"(^'+|'+$)")


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


def normalize_for_wer(text: str) -> list[str]:
    text = PUNCT_RE.sub(" ", text.lower())
    tokens: list[str] = []
    for token in text.split():
        token = APOS_RE.sub("", token)
        if token:
            tokens.append(token)
    return tokens


def edit_counts(hypothesis: list[str], reference: list[str]) -> tuple[int, int, int]:
    rows = len(hypothesis) + 1
    cols = len(reference) + 1
    dp = [[0] * cols for _ in range(rows)]
    for i in range(rows):
        dp[i][0] = i
    for j in range(cols):
        dp[0][j] = j

    for i in range(1, rows):
        for j in range(1, cols):
            if hypothesis[i - 1] == reference[j - 1]:
                dp[i][j] = dp[i - 1][j - 1]
            else:
                dp[i][j] = 1 + min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1])

    i = len(hypothesis)
    j = len(reference)
    insertions = deletions = substitutions = 0
    while i > 0 or j > 0:
        if i > 0 and j > 0 and hypothesis[i - 1] == reference[j - 1]:
            i -= 1
            j -= 1
        elif i > 0 and j > 0 and dp[i][j] == dp[i - 1][j - 1] + 1:
            substitutions += 1
            i -= 1
            j -= 1
        elif i > 0 and dp[i][j] == dp[i - 1][j] + 1:
            insertions += 1
            i -= 1
        elif j > 0 and dp[i][j] == dp[i][j - 1] + 1:
            deletions += 1
            j -= 1
        else:
            break
    return insertions, deletions, substitutions


def score_records(records: Path) -> tuple[int, int, int, int, int]:
    files = total_ref_words = total_insertions = total_deletions = total_substitutions = 0

    for line in records.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        rec = json.loads(line)
        ref = normalize_for_wer(rec["ref"])
        hyp = normalize_for_wer(rec.get("hyp", ""))
        insertions, deletions, substitutions = edit_counts(hyp, ref)
        files += 1
        total_ref_words += len(ref)
        total_insertions += insertions
        total_deletions += deletions
        total_substitutions += substitutions

    return files, total_ref_words, total_insertions, total_deletions, total_substitutions


def print_score(records: Path) -> None:
    files, ref_words, insertions, deletions, substitutions = score_records(records)
    errors = insertions + deletions + substitutions
    wer = (errors / ref_words * 100) if ref_words else 0.0
    print(f"files={files}  ref_words={ref_words}  I={insertions} D={deletions} S={substitutions}")
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
