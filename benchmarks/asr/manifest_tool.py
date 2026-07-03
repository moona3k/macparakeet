#!/usr/bin/env python3
"""Validate and summarize the MacParakeet ASR benchmark manifest.

The manifest is the suite contract: engines, datasets, tasks, metrics, and
decision gates. This tool deliberately stays dependency-free so `run_all.sh
verify` can check the contract without downloading models or benchmark data.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

REQUIRED_TOP_LEVEL = (
    "schema_version",
    "suite",
    "engines",
    "datasets",
    "tasks",
    "metrics",
    "quality_gates",
)

REQUIRED_LIST_FIELDS = {
    "engines": ("id", "name", "runtime", "product_surfaces"),
    "datasets": ("id", "name", "tier", "status", "license"),
    "tasks": ("id", "name", "surface", "datasets", "engines", "primary_metric", "metrics", "status"),
    "metrics": ("id", "name", "kind"),
    "quality_gates": ("id", "name", "scope", "required_evidence"),
}

ALLOWED_SURFACES = {
    "dictation_final",
    "dictation_live_preview",
    "meeting_final",
    "meeting_live_preview",
    "file_media",
    "performance",
    "research",
}


def load_manifest(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        print(f"manifest error: file not found: {path}", file=sys.stderr)
        raise SystemExit(1)
    except json.JSONDecodeError as exc:
        print(f"manifest error: invalid JSON in {path}: {exc}", file=sys.stderr)
        raise SystemExit(1)


def _ids(rows: list[Any], kind: str, errors: list[str]) -> set[str]:
    seen: set[str] = set()
    for idx, row in enumerate(rows):
        if not isinstance(row, dict):
            continue
        item_id = row.get("id")
        if not isinstance(item_id, str) or not item_id.strip():
            errors.append(f"{kind}[{idx}] is missing a non-empty id")
            continue
        if item_id in seen:
            errors.append(f"{kind} has duplicate id '{item_id}'")
        seen.add(item_id)
    return seen


def _require_fields(rows: list[Any], kind: str, errors: list[str]) -> None:
    required = REQUIRED_LIST_FIELDS[kind]
    for idx, row in enumerate(rows):
        if not isinstance(row, dict):
            errors.append(f"{kind}[{idx}] must be an object")
            continue
        item_id = row.get("id", "<missing>")
        for field in required:
            if field not in row:
                errors.append(f"{kind}.{item_id} missing required field '{field}'")
        if kind == "tasks":
            for field in ("datasets", "engines", "metrics"):
                if field not in row:
                    continue
                value = row[field]
                if not isinstance(value, list) or not value:
                    errors.append(f"tasks.{item_id}.{field} must be a non-empty list")
        if kind == "engines":
            if "product_surfaces" not in row:
                continue
            surfaces = row["product_surfaces"]
            if not isinstance(surfaces, list) or not surfaces:
                errors.append(f"engines.{item_id}.product_surfaces must be a non-empty list")


def validate_manifest(data: Any) -> list[str]:
    errors: list[str] = []
    if not isinstance(data, dict):
        return ["manifest root must be a JSON object"]

    for field in REQUIRED_TOP_LEVEL:
        if field not in data:
            errors.append(f"top-level field '{field}' is required")
    if errors:
        return errors

    if data.get("schema_version") != 1:
        errors.append("schema_version must be 1")

    suite = data.get("suite")
    if not isinstance(suite, dict):
        errors.append("top-level field 'suite' must be an object")
    else:
        name = suite.get("name")
        purpose = suite.get("purpose")
        if not isinstance(name, str) or not name.strip():
            errors.append("suite.name must be a non-empty string")
        if purpose is not None and not isinstance(purpose, str):
            errors.append("suite.purpose must be a string")

    for kind in ("engines", "datasets", "tasks", "metrics", "quality_gates"):
        if not isinstance(data.get(kind), list):
            errors.append(f"top-level field '{kind}' must be a list")
    if errors:
        return errors

    for kind in ("engines", "datasets", "tasks", "metrics", "quality_gates"):
        _require_fields(data[kind], kind, errors)

    engine_ids = _ids(data["engines"], "engines", errors)
    dataset_ids = _ids(data["datasets"], "datasets", errors)
    metric_ids = _ids(data["metrics"], "metrics", errors)
    _ids(data["tasks"], "tasks", errors)
    _ids(data["quality_gates"], "quality_gates", errors)

    for engine in data["engines"]:
        if not isinstance(engine, dict):
            continue
        surfaces = engine.get("product_surfaces")
        if not isinstance(surfaces, list):
            continue
        for surface in surfaces:
            if surface not in ALLOWED_SURFACES:
                errors.append(f"engines.{engine.get('id')}.product_surfaces has unknown surface '{surface}'")

    for task in data["tasks"]:
        if not isinstance(task, dict):
            continue
        task_id = task.get("id")
        if "surface" in task:
            surface = task["surface"]
            if surface not in ALLOWED_SURFACES:
                errors.append(f"tasks.{task_id}.surface has unknown surface '{surface}'")
        datasets = task.get("datasets") if isinstance(task.get("datasets"), list) else []
        engines = task.get("engines") if isinstance(task.get("engines"), list) else []
        metrics = task.get("metrics") if isinstance(task.get("metrics"), list) else []
        for dataset in datasets:
            if dataset not in dataset_ids:
                errors.append(f"tasks.{task_id}.datasets references unknown dataset '{dataset}'")
        for engine in engines:
            if engine not in engine_ids:
                errors.append(f"tasks.{task_id}.engines references unknown engine '{engine}'")
        primary = task.get("primary_metric") if "primary_metric" in task else None
        if primary is not None and primary not in metric_ids:
            errors.append(f"tasks.{task_id}.primary_metric references unknown metric '{primary}'")
        if primary is not None and metrics and primary not in metrics:
            errors.append(f"tasks.{task_id}.primary_metric '{primary}' must also be listed in metrics")
        for metric in metrics:
            if metric not in metric_ids:
                errors.append(f"tasks.{task_id}.metrics references unknown metric '{metric}'")

    return errors


def _md_cell(value: Any) -> str:
    return str(value).replace("\n", " ").replace("|", "\\|")


def markdown_summary(data: dict[str, Any]) -> str:
    lines = [
        f"# {_md_cell(data['suite']['name'])}",
        "",
        _md_cell(data["suite"].get("purpose", "").strip()),
        "",
        "## Tasks",
        "",
        "| Task | Surface | Status | Datasets | Engines | Primary metric |",
        "|------|---------|--------|----------|---------|----------------|",
    ]
    for task in data["tasks"]:
        lines.append(
            "| {name} | `{surface}` | {status} | {datasets} | {engines} | `{metric}` |".format(
                name=_md_cell(task["name"]),
                surface=_md_cell(task["surface"]),
                status=_md_cell(task["status"]),
                datasets=", ".join(f"`{d}`" for d in task["datasets"]),
                engines=", ".join(f"`{e}`" for e in task["engines"]),
                metric=_md_cell(task["primary_metric"]),
            )
        )

    lines.extend([
        "",
        "## Engines",
        "",
        "| Engine | Runtime | Surfaces | Caveat |",
        "|--------|---------|----------|--------|",
    ])
    for engine in data["engines"]:
        lines.append(
            "| {name} | {runtime} | {surfaces} | {caveat} |".format(
                name=_md_cell(engine["name"]),
                runtime=_md_cell(engine["runtime"]),
                surfaces=", ".join(f"`{s}`" for s in engine["product_surfaces"]),
                caveat=_md_cell(engine.get("caveat", "")),
            )
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["validate", "summary"])
    ap.add_argument("manifest", nargs="?", type=Path, default=Path("manifest.json"))
    args = ap.parse_args()

    manifest = load_manifest(args.manifest)
    errors = validate_manifest(manifest)
    if errors:
        for error in errors:
            print(f"manifest error: {error}", file=sys.stderr)
        return 1

    if args.command == "validate":
        print(f"manifest ok: {args.manifest}")
    else:
        print(markdown_summary(manifest), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
