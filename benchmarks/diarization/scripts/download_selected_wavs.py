#!/usr/bin/env python3
"""Download only the selected VoxConverse test WAVs.

Prefers per-file copies on Hugging Face (test split). Falls back to extracting
those members from the official Oxford zip if it is already on disk, or
downloads that zip when --allow-full-zip is set.

Audio is written under $VOXCONVERSE_ROOT (default ~/asr-bench/voxconverse).
"""
from __future__ import annotations

import argparse
import csv
import subprocess
import sys
import urllib.request
from pathlib import Path

HF_REPO = "ggfox00000/dia-voxconverse-test"
HF_URL = (
    "https://huggingface.co/datasets/ggfox00000/dia-voxconverse-test/"
    "resolve/main/audio/test/{file_id}.wav"
)
OXFORD_TEST_ZIP = (
    "https://www.robots.ox.ac.uk/~vgg/data/voxconverse/data/voxconverse_test_wav.zip"
)

HERE = Path(__file__).resolve().parent.parent
SELECTED = HERE / "selected_files.tsv"


def load_selected() -> list[dict[str, str]]:
    with SELECTED.open(newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def duration_seconds(wav: Path) -> float | None:
    try:
        import wave

        with wave.open(str(wav), "rb") as w:
            frames = w.getnframes()
            rate = w.getframerate()
            if rate <= 0:
                return None
            return frames / float(rate)
    except Exception:
        return None


def download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    req = urllib.request.Request(url, headers={"User-Agent": "macparakeet-diarization-eval"})
    with urllib.request.urlopen(req, timeout=120) as resp, tmp.open("wb") as out:
        while True:
            chunk = resp.read(1024 * 1024)
            if not chunk:
                break
            out.write(chunk)
    tmp.replace(dest)


def try_hf(file_id: str, dest: Path) -> bool:
    url = HF_URL.format(file_id=file_id)
    try:
        download(url, dest)
        return dest.is_file() and dest.stat().st_size > 10_000
    except Exception as exc:
        print(f"  HF failed for {file_id}: {exc}", file=sys.stderr)
        if dest.exists():
            dest.unlink()
        part = dest.with_suffix(dest.suffix + ".part")
        if part.exists():
            part.unlink()
        return False


def extract_from_zip(zip_path: Path, file_id: str, dest: Path) -> bool:
    listing = subprocess.check_output(["unzip", "-Z1", str(zip_path)], text=True)
    members = [line.strip() for line in listing.splitlines() if line.strip().endswith(f"{file_id}.wav")]
    if not members:
        return False
    member = members[0]
    dest.parent.mkdir(parents=True, exist_ok=True)
    subprocess.check_call(
        ["unzip", "-p", str(zip_path), member],
        stdout=dest.open("wb"),
    )
    return dest.is_file() and dest.stat().st_size > 10_000


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--root",
        type=Path,
        default=Path.home() / "asr-bench" / "voxconverse",
        help="Audio root; WAVs go to <root>/wav/<split>/<id>.wav",
    )
    ap.add_argument(
        "--oxford-zip",
        type=Path,
        default=None,
        help="Existing voxconverse_test_wav.zip (used if Hugging Face fails)",
    )
    ap.add_argument(
        "--allow-full-zip",
        action="store_true",
        help="Download the ~4.3 GB Oxford test zip if per-file fetch fails",
    )
    args = ap.parse_args()
    rows = load_selected()
    oxford = args.oxford_zip
    if oxford is None:
        candidate = args.root / "voxconverse_test_wav.zip"
        if candidate.is_file():
            oxford = candidate

    ok = 0
    for row in rows:
        dest = args.root / row["wav_relpath"]
        expected_end = float(row["rttm_end_s"])
        if dest.is_file() and dest.stat().st_size > 10_000:
            dur = duration_seconds(dest)
            print(f"exists {row['file_id']}: {dest} ({dur:.1f}s)" if dur else f"exists {row['file_id']}: {dest}")
            ok += 1
            continue
        print(f"fetch {row['file_id']} -> {dest}")
        got = try_hf(row["file_id"], dest)
        if not got and oxford and oxford.is_file():
            print(f"  extracting from {oxford}")
            got = extract_from_zip(oxford, row["file_id"], dest)
        if not got and args.allow_full_zip:
            zip_dest = args.root / "voxconverse_test_wav.zip"
            if not zip_dest.is_file():
                print(f"  downloading Oxford zip to {zip_dest}")
                download(OXFORD_TEST_ZIP, zip_dest)
            oxford = zip_dest
            got = extract_from_zip(oxford, row["file_id"], dest)
        if not got:
            print(f"FAILED {row['file_id']}", file=sys.stderr)
            continue
        dur = duration_seconds(dest)
        if dur is not None and abs(dur - expected_end) > 15:
            print(
                f"  warning: duration {dur:.1f}s vs RTTM end {expected_end:.1f}s",
                file=sys.stderr,
            )
        size_mb = dest.stat().st_size / (1024 * 1024)
        print(f"  ok {size_mb:.1f} MB, {dur:.1f}s" if dur else f"  ok {size_mb:.1f} MB")
        ok += 1

    print(f"{ok}/{len(rows)} files ready under {args.root}")
    return 0 if ok == len(rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
