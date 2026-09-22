#!/usr/bin/env python3
"""Build exact production sources and qualify the dedicated Google Flights window.

The Google Flights tab in the existing Chrome process must already be focused.
This script never opens/restarts Chrome, changes a profile, uses CDP, an
extension, or DOM injection. Credential path is explicit; the value is never
printed. Evidence is content-minimized: no page summaries or account labels.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--env-file', type=Path)
parser.add_argument('--goal', default='Find one-way flights from Zürich to London on September 20.')
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
core = root / 'Sources/MacParakeetCore/Services/VoiceControl'
env = os.environ.copy()
if args.env_file:
    for line in args.env_file.read_text().splitlines():
        key, sep, value = line.removeprefix('export ').partition('=')
        if sep and key in ('JEV_API_KEY', 'TYPESAFE_API_KEY'):
            env['JEV_API_KEY'] = value.strip().strip('\"\'')
with tempfile.TemporaryDirectory(prefix='macparakeet-native-flights-') as build:
    folder = Path(build)
    source = (root / 'Sources/MacParakeetCore/Services/System/StreamingCursorInserter.swift').read_text()
    start = source.index('public enum StreamingCursorEventMarker')
    end = source.index('\n}', start) + 2
    marker = folder / 'StreamingCursorEventMarker.swift'
    marker.write_text('import CoreGraphics\n' + source[start:end])
    binary = folder / 'probe'
    files = ['VoiceControlTypes', 'VoiceControlDiagnostics', 'VoiceControlTurnRunner',
             'VoiceControlCommandRouter', 'JevDecisionClient', 'NativeVoiceControlAdapter']
    subprocess.run(['swiftc', '-parse-as-library', *[str(core / (name + '.swift')) for name in files],
                    str(marker), str(Path(__file__).with_name('AXFlightsProbe.swift')), '-o', str(binary)], check=True)
    subprocess.run([
        'osascript', '-e',
        'tell application "Google Chrome"\n'
        'repeat with w in windows\n'
        'if title of w contains "Google Flights" then\n'
        'set index of w to 1\n'
        'exit repeat\n'
        'end if\n'
        'end repeat\n'
        'activate\n'
        'end tell'
    ], check=True)
    subprocess.run(['sleep', '1'], check=True)
    subprocess.run([str(binary), args.goal], env=env, check=True)
