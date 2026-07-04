#!/usr/bin/env python3
"""Compute exact normalized custom-term recall for Phase 0 OOV records."""

from __future__ import annotations

import argparse
import json
import re
import unicodedata
from pathlib import Path


def read_jsonl(path: Path) -> list[dict]:
    rows: list[dict] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def normalize(text: str) -> str:
    ascii_text = (
        unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode("ascii")
    )
    lowered = ascii_text.lower()
    return re.sub(r"[^a-z0-9]+", " ", lowered).strip()


def contains_phrase(haystack: str, phrase: str) -> bool:
    if not phrase:
        return False
    return re.search(rf"(?:^| ){re.escape(phrase)}(?: |$)", haystack) is not None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--records", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    if not args.manifest.is_file():
        parser.error(f"manifest file does not exist or is not a file: {args.manifest}")
    if not args.records.is_file():
        parser.error(f"records file does not exist or is not a file: {args.records}")

    manifest = {row["id"]: row for row in read_jsonl(args.manifest)}
    records = read_jsonl(args.records)

    total = 0
    recalled = 0
    missing: list[dict] = []
    per_record: list[dict] = []
    for record in records:
        row = manifest.get(record["id"])
        if not row:
            continue
        hyp_norm = normalize(record.get("hyp", ""))
        row_total = 0
        row_recalled = 0
        row_missing: list[str] = []
        for term in row.get("terms", []):
            total += 1
            row_total += 1
            term_norm = normalize(term)
            if contains_phrase(hyp_norm, term_norm):
                recalled += 1
                row_recalled += 1
            else:
                row_missing.append(term)
                missing.append(
                    {
                        "id": record["id"],
                        "term": term,
                        "hyp": record.get("hyp", ""),
                        "ref": row.get("ref", ""),
                    }
                )
        per_record.append(
            {
                "id": record["id"],
                "total_terms": row_total,
                "recalled_terms": row_recalled,
                "missing_terms": row_missing,
            }
        )

    summary = {
        "records": len(records),
        "total_terms": total,
        "recalled_terms": recalled,
        "recall": recalled / total if total else None,
        "missing": missing,
        "per_record": per_record,
    }

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")

    print(json.dumps({k: summary[k] for k in ("records", "total_terms", "recalled_terms", "recall")}, indent=2, sort_keys=True))
    if missing:
        print("Missing terms:")
        for item in missing:
            print(f"- {item['id']}: {item['term']} -> {item['hyp']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
