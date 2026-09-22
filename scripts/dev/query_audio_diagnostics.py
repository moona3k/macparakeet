#!/usr/bin/env python3
"""Read a bounded local audio diagnostic tail as JSON. Never uploads data."""

import argparse
from collections import Counter
from datetime import datetime, timezone
import errno
import heapq
import json
import os
from pathlib import Path
import re
import shlex
import stat


MAX_SCAN_BYTES = 5_000_000
MAX_RETURNED_RECORDS = 1_000
IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*$")


def default_log_path():
    override = os.environ.get("MACPARAKEET_AUDIO_DIAGNOSTICS_LOG_PATH", "")
    if override.strip():
        return Path(override).expanduser()
    debug_root = os.environ.get("MACPARAKEET_DEBUG_APP_STATE_DIR", "")
    if debug_root.strip():
        return Path(debug_root).expanduser() / "logs" / "dictation-audio.log"
    return Path.home() / "Library" / "Logs" / "MacParakeet" / "dictation-audio.log"


def parse_timestamp(value):
    """Require a timezone; normalize explicit offsets to UTC."""
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp must include Z or an explicit UTC offset")
    return parsed.astimezone(timezone.utc)


def parse_line(line):
    tokens = shlex.split(line, comments=False, posix=True)
    if len(tokens) < 2 or not IDENTIFIER.fullmatch(tokens[1]):
        raise ValueError("missing timestamp or event")
    timestamp = parse_timestamp(tokens[0])
    fields = {}
    unparsed_tokens = 0
    duplicate_fields = 0
    for token in tokens[2:]:
        key, separator, value = token.partition("=")
        if not separator or not IDENTIFIER.fullmatch(key):
            unparsed_tokens += 1
            continue
        if key in fields:
            duplicate_fields += 1
        fields[key] = value
    return timestamp, {
        "timestamp": timestamp.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "event": tokens[1],
        "fields": fields,
    }, unparsed_tokens, duplicate_fields


def query_log(path, *, since=None, events=(), process_session=None, limit=100,
              max_scan_bytes=MAX_SCAN_BYTES):
    if not 1 <= limit <= MAX_RETURNED_RECORDS:
        raise ValueError(f"limit must be between 1 and {MAX_RETURNED_RECORDS}")
    if not 2 <= max_scan_bytes <= MAX_SCAN_BYTES:
        raise ValueError(f"scan budget must be between 2 and {MAX_SCAN_BYTES}")
    if since is not None and since.tzinfo is None:
        raise ValueError("since must include a timezone")

    scan = {
        "max_bytes": max_scan_bytes,
        "file_size_bytes": None,
        "bytes_read": 0,
        "boundary_probe_bytes": 0,
        "truncated": False,
        "changed_during_read": False,
        "discarded_partial_start_bytes": 0,
        "discarded_partial_end_bytes": 0,
        "incomplete_lines": 0,
        "complete_lines": 0,
        "parsed_records": 0,
        "unparsed_lines": 0,
        "unparsed_field_tokens": 0,
        "duplicate_fields": 0,
    }
    result = {
        "schema_version": 1,
        "status": "available",
        "scan": scan,
        "matched_records": 0,
        "returned_records": 0,
        "limit": limit,
        "event_counts": {},
        "records": [],
    }

    try:
        # O_NONBLOCK prevents an accidental FIFO path from hanging an agent.
        # It has no effect on normal files. Inspect the open handle so a rename
        # during log compaction cannot mix bytes from different files.
        descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as handle:
            before = os.fstat(handle.fileno())
            if not stat.S_ISREG(before.st_mode):
                raise OSError(errno.EINVAL, "diagnostic input must be a regular file")
            scan["file_size_bytes"] = before.st_size
            # The retained tail has its own byte budget. A separate one-byte
            # look-behind preserves a full record aligned with its first byte.
            start = max(0, before.st_size - max_scan_bytes)
            previous = b"\n"
            if start > 0:
                handle.seek(start - 1)
                previous = handle.read(1)
                scan["boundary_probe_bytes"] = len(previous)
            handle.seek(start)
            data = handle.read(max_scan_bytes)
            scan["bytes_read"] = len(data)
            scan["truncated"] = start > 0
            if start > 0 and data:
                if previous != b"\n":
                    first_newline = data.find(b"\n")
                    discarded = len(data) if first_newline < 0 else first_newline + 1
                    scan["discarded_partial_start_bytes"] = discarded
                    scan["incomplete_lines"] += int(not data.startswith(b"\n"))
                    data = data[discarded:]
            after = os.fstat(handle.fileno())
            scan["changed_during_read"] = (
                before.st_size != after.st_size or before.st_mtime_ns != after.st_mtime_ns
                or scan["bytes_read"] != min(before.st_size, max_scan_bytes)
            )
            try:
                current = os.stat(path)
                scan["changed_during_read"] |= (
                    (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns)
                    != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
                )
            except OSError:
                # An opened tail remains useful when its path disappears or
                # becomes inaccessible, but cannot be presented as stable.
                scan["changed_during_read"] = True
    except FileNotFoundError:
        result["status"] = "missing"
        return result
    except OSError as error:
        result["status"] = "unreadable"
        scan["error_code"] = error.errno
        return result

    if not scan["file_size_bytes"]:
        result["status"] = "empty"
        return result

    if data and not data.endswith(b"\n"):
        end = data.rfind(b"\n") + 1
        scan["discarded_partial_end_bytes"] = len(data) - end
        scan["incomplete_lines"] += 1
        data = data[:end]

    allowed_events = set(events)
    counts = Counter()
    newest = []
    # Do not stop on an old timestamp: async appends and clock changes can put
    # older events physically after newer events. Rank by timestamp, with file
    # order breaking ties; uptime_ns remains available for clock-change analysis.
    for position, encoded in enumerate(data.split(b"\n")[:-1]):
        scan["complete_lines"] += 1
        try:
            timestamp, record, unparsed_tokens, duplicates = parse_line(encoded.decode("utf-8"))
        except (UnicodeError, ValueError):
            scan["unparsed_lines"] += 1
            continue
        scan["parsed_records"] += 1
        scan["unparsed_field_tokens"] += unparsed_tokens
        scan["duplicate_fields"] += duplicates
        if since is not None and timestamp < since:
            continue
        if allowed_events and record["event"] not in allowed_events:
            continue
        if process_session is not None and record["fields"].get("process_session") != process_session:
            continue
        result["matched_records"] += 1
        counts[record["event"]] += 1
        candidate = (timestamp, position, record)
        if len(newest) < limit:
            heapq.heappush(newest, candidate)
        else:
            heapq.heappushpop(newest, candidate)

    result["records"] = [item[2] for item in sorted(newest, reverse=True)]
    result["returned_records"] = len(newest)
    result["event_counts"] = dict(sorted(counts.items()))
    if scan["parsed_records"] == 0:
        result["status"] = "unparseable"
    elif not result["matched_records"]:
        result["status"] = "no_matches"
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--path", type=Path, default=None, help="Diagnostic log path (defaults to the app log)")
    parser.add_argument("--since", help="Inclusive ISO-8601 timestamp with timezone, e.g. 2026-09-06T00:00:00Z")
    parser.add_argument("--event", action="append", default=[], help="Exact event name; repeat to include several")
    parser.add_argument("--process-session", help="Exact per-launch process_session field")
    parser.add_argument("--limit", type=int, default=100, help=f"Newest records to return, 1–{MAX_RETURNED_RECORDS}")
    args = parser.parse_args(argv)
    try:
        since = parse_timestamp(args.since) if args.since else None
        result = query_log(
            args.path.expanduser() if args.path is not None else default_log_path(),
            since=since, events=args.event, process_session=args.process_session, limit=args.limit,
        )
    except ValueError as error:
        parser.error(str(error))
    print(json.dumps(result, ensure_ascii=True, indent=2))
    return 1 if result["status"] == "unreadable" else 0


if __name__ == "__main__":
    raise SystemExit(main())
