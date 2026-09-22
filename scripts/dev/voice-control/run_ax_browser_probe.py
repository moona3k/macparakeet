#!/usr/bin/env python3
"""Build exact production sources and qualify a foreground native Chrome fixture.

Serve this directory on 127.0.0.1:56474 and open flight-fixture.html in a
single-tab Chrome window first. This script never opens/restarts Chrome or
changes a profile. No CDP, extension, DOM injection, or automatic confirmation.
Credential path is explicit; credential value is never printed.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--env-file', type=Path)
parser.add_argument('--goal', default='Find one way flights from Zürich to London on 20 September.')
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
core = root / 'Sources/MacParakeetCore/Services/VoiceControl'
env = os.environ.copy()
if args.env_file:
    for line in args.env_file.read_text().splitlines():
        key, sep, value = line.removeprefix('export ').partition('=')
        if sep and key in ('JEV_API_KEY', 'TYPESAFE_API_KEY'):
            env['JEV_API_KEY'] = value.strip().strip('\"\'')
with tempfile.TemporaryDirectory(prefix='macparakeet-native-browser-') as build:
    folder = Path(build)
    # Extract this unchanged enum to avoid linking unrelated audio dependencies.
    source = (root / 'Sources/MacParakeetCore/Services/System/StreamingCursorInserter.swift').read_text()
    start = source.index('public enum StreamingCursorEventMarker')
    end = source.index('\n}', start) + 2
    marker = folder / 'StreamingCursorEventMarker.swift'
    marker.write_text('import CoreGraphics\n' + source[start:end])
    binary = folder / 'probe'
    files = ['VoiceControlTypes', 'VoiceControlDiagnostics', 'VoiceControlTurnRunner',
             'VoiceControlCommandRouter', 'JevDecisionClient', 'NativeVoiceControlAdapter']
    subprocess.run(['swiftc', '-parse-as-library', *[str(core / (name + '.swift')) for name in files],
                    str(marker), str(Path(__file__).with_name('AXBrowserProbe.swift')), '-o', str(binary)], check=True)
    subprocess.run([str(binary), args.goal], env=env, check=True)
