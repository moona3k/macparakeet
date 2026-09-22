#!/usr/bin/env python3
"""Submit a Voice Control inbox command, then wait for the local session log.

Does not use CDP, extensions, or DOM injection. Chrome focusing is tester
setup only. The product path is the running MacParakeet-Dev Voice Control
session.
"""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

POINTER = Path('/tmp/macparakeet-voice-control')
DEFAULT_COMMAND = POINTER / 'command.json'
DEFAULT_LATEST = POINTER / 'latest.json'
WHERE = POINTER / 'WHERE'


def resolve_paths() -> tuple[Path, Path]:
    command = DEFAULT_COMMAND
    latest = DEFAULT_LATEST
    if WHERE.exists():
        mapping = {}
        for line in WHERE.read_text().splitlines():
            key, sep, value = line.partition('=')
            if sep:
                mapping[key.strip()] = value.strip()
        if mapping.get('command'):
            command = Path(mapping['command'])
        if mapping.get('latest'):
            latest = Path(mapping['latest'])
    return command, latest


def load_latest(path: Path) -> dict | None:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return None


def summarize(session: dict) -> str:
    records = session.get('records') or []
    last = records[-1] if records else {}
    summary = session.get('summary') or {}
    why = summary.get('why') or last.get('outcome')
    return (
        f"phase={session.get('phase')} status={session.get('status')!r} "
        f"app={session.get('applicationName')!r} outcome={summary.get('outcome')!r} "
        f"why={why!r} actor={summary.get('actor')!r} route={summary.get('route')!r} "
        f"records={len(records)} last={last.get('stage')}/{last.get('outcome')}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--action', default='submit')
    parser.add_argument('--text', default='')
    parser.add_argument('--activate', default='com.google.Chrome')
    parser.add_argument('--wait', type=float, default=25)
    parser.add_argument('--quiet-after', type=float, default=1.2)
    args = parser.parse_args()
    command_path, latest_path = resolve_paths()
    before = load_latest(latest_path)
    before_updated = (before or {}).get('updatedAt')
    payload = {'action': args.action, 'activate': args.activate}
    if args.text:
        payload['text'] = args.text
    if not args.activate:
        payload.pop('activate', None)
    command_path.parent.mkdir(parents=True, exist_ok=True)
    command_path.write_text(json.dumps(payload))
    deadline = time.time() + args.wait
    last_seen = None
    stable_since = None
    while time.time() < deadline:
        session = load_latest(latest_path)
        if session and session.get('updatedAt') != before_updated:
            summary = summarize(session)
            if summary != last_seen:
                print(summary)
                last_seen = summary
                stable_since = time.time()
            elif stable_since and time.time() - stable_since >= args.quiet_after:
                phase = session.get('phase')
                if phase in {'clarification', 'paused', 'done', 'failed', 'confirmation', 'idle'}:
                    print(latest_path)
                    return 0 if phase in {'done', 'paused', 'clarification', 'confirmation'} else 2
        time.sleep(0.2)
    print('timeout waiting for voice-control log')
    print(latest_path)
    return 3


if __name__ == '__main__':
    raise SystemExit(main())
