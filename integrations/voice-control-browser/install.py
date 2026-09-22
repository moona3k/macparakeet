#!/usr/bin/env python3
"""Explicit user-scoped installation; does not launch or modify browser profiles."""
import argparse
import json
import os
from pathlib import Path
import re
import secrets

parser = argparse.ArgumentParser()
parser.add_argument('--extension-id', required=True)
parser.add_argument('--host', required=True, type=Path)
parser.add_argument('--browser', choices=['chrome', 'chromium', 'chrome-for-testing'], default='chrome')
parser.add_argument('--user-data-dir', type=Path, help='Explicit disposable/custom browser profile root')
args = parser.parse_args()
if not re.fullmatch('[a-p]{32}', args.extension_id):
    parser.error('extension-id must be the exact 32-character Chromium extension ID')
host = args.host.expanduser().resolve()
if not host.is_file() or not os.access(host, os.X_OK):
    parser.error('host must be an existing executable')
root = Path.home() / 'Library/Application Support'
private = root / 'MacParakeet/VoiceControlBrowser'
private.mkdir(parents=True, exist_ok=True, mode=0o700)
if private.is_symlink() or private.stat().st_uid != os.getuid() or private.stat().st_mode & 0o777 != 0o700:
    parser.error('private bridge directory must be owned by you with mode 0700')
origin = f'chrome-extension://{args.extension_id}/'
config = private / 'pairing.json'
if config.exists():
    parser.error('pairing already exists; preserve it and remove it explicitly before pairing a different extension')
location = root / {'chrome':'Google/Chrome','chromium':'Chromium','chrome-for-testing':'Google/ChromeForTesting'}[args.browser] / 'NativeMessagingHosts'
if args.user_data_dir:
    location = args.user_data_dir.expanduser().resolve() / 'NativeMessagingHosts'
location.mkdir(parents=True, exist_ok=True)
manifest = location / 'com.macparakeet.voice_control.json'
if manifest.exists():
    parser.error('native host manifest already exists; preserve and review it before replacing')
with os.fdopen(os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as stream:
    json.dump({'extensionOrigin': origin, 'token': secrets.token_hex(32)}, stream)
try:
    with manifest.open('x') as stream:
        json.dump({'name':'com.macparakeet.voice_control','description':'MacParakeet Voice Control','path':str(host),'type':'stdio','allowed_origins':[origin]},stream,indent=2)
except Exception:
    config.unlink()  # Roll back only the file this invocation just created.
    raise
print('Browser bridge installed. Enable Voice Control in MacParakeet, then connect a tab from the extension.')
