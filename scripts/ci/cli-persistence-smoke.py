#!/usr/bin/env python3
"""Exercise real CLI persistence across processes using an isolated database.

Usage: python3 scripts/ci/cli-persistence-smoke.py /absolute/path/to/macparakeet-cli
No models, network calls, or existing app data are needed.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid


COMMAND_TIMEOUT_SECONDS = 30


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def run_json(cli, database, environment, *arguments, expected_exit=0):
    command = [str(cli), "prompts", *arguments, "--database", str(database), "--json"]
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            env=environment,
            timeout=COMMAND_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise AssertionError(
            f"CLI timed out after {COMMAND_TIMEOUT_SECONDS}s: {command!r}; "
            f"stdout={error.stdout!r}; stderr={error.stderr!r}"
        ) from error

    details = (
        f"command={command!r}; exit={result.returncode}; "
        f"stdout={result.stdout!r}; stderr={result.stderr!r}"
    )
    require(result.returncode == expected_exit, f"Unexpected CLI exit: {details}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise AssertionError(f"CLI stdout is not one JSON value: {details}") from error


def main():
    require(len(sys.argv) == 2, "Usage: cli-persistence-smoke.py /absolute/path/to/macparakeet-cli")
    cli = Path(sys.argv[1])
    require(cli.is_absolute(), f"CLI path must be absolute: {cli}")
    require(cli.is_file() and os.access(cli, os.X_OK), f"CLI is not executable: {cli}")

    with tempfile.TemporaryDirectory(prefix="macparakeet-cli-smoke-") as temporary:
        root = Path(temporary)
        database = root / "smoke.sqlite"
        environment = os.environ.copy()
        environment["MACPARAKEET_TELEMETRY"] = "0"
        environment["MACPARAKEET_DEBUG_APP_STATE_DIR"] = str(root / "app-state")

        collections = run_json(cli, database, environment, "collections", "list")
        require(isinstance(collections, list) and not collections, "Fresh database has collections")

        collection_name = f"CI collection {uuid.uuid4()}"
        collection = run_json(
            cli, database, environment, "collections", "add", "--name", collection_name
        )
        collection_id = collection["id"]
        require(collection["name"] == collection_name, "Collection add returned the wrong name")
        require(str(uuid.UUID(collection_id)) == collection_id.lower(), "Invalid collection UUID")

        prompt_name = f"CI prompt {uuid.uuid4()}"
        prompt_body = "Summarize the local transcript in one sentence."
        prompt = run_json(
            cli, database, environment, "add", "--name", prompt_name,
            "--content", prompt_body, "--collection", collection_id,
        )
        prompt_id = prompt["id"]
        require(prompt["collectionId"] == collection_id, "Prompt was not added to collection")
        require(prompt["content"] == prompt_body, "Prompt body changed on add")

        listed = run_json(cli, database, environment, "list")
        require(
            any(item["id"] == prompt_id and item["collectionId"] == collection_id for item in listed),
            "New process did not find saved prompt membership",
        )
        shown = run_json(cli, database, environment, "show", prompt_id)
        require(shown["content"] == prompt_body, "New process did not read saved prompt body")

        renamed_name = collection_name + " renamed"
        renamed = run_json(
            cli, database, environment, "collections", "rename", collection_id,
            "--name", renamed_name,
        )
        require(renamed["id"] == collection_id and renamed["name"] == renamed_name,
                "Collection rename returned unexpected record")
        collections = run_json(cli, database, environment, "collections", "list")
        require(
            any(item["id"] == collection_id and item["name"] == renamed_name for item in collections),
            "New process did not find renamed collection",
        )

        deleted = run_json(cli, database, environment, "collections", "delete", collection_id)
        require(deleted["deleted"] is True and deleted["id"] == collection_id,
                "Collection deletion returned unexpected record")
        shown = run_json(cli, database, environment, "show", prompt_id)
        require(shown.get("collectionId") is None and shown["content"] == prompt_body,
                "Deleting collection did not preserve and unfile its prompt")

        missing = run_json(
            cli, database, environment, "collections", "rename", collection_id,
            "--name", "missing", expected_exit=1,
        )
        require(missing.get("ok") is False and missing.get("errorType") == "lookup",
                f"Missing collection did not return a lookup JSON error: {missing!r}")
        require(database.is_file(), "CLI did not create the requested database")

    print("CLI persistence smoke passed: collection and prompt state survived separate processes")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, KeyError, TypeError, ValueError) as error:
        print(f"CLI persistence smoke failed: {error}", file=sys.stderr)
        sys.exit(1)
