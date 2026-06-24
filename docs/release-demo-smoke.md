# Release Demo Smoke

This smoke path proves a released MacParakeet CLI can run a local demo without
touching the user's app database. It checks CLI availability, records health
readiness, synthesizes a tiny local audio fixture, transcribes it into an
isolated SQLite database, and exports the saved transcription to Markdown.

Run it against the installed app-bundled CLI:

```bash
scripts/dev/release_demo_smoke.sh
```

If the released CLI is somewhere else, pass it explicitly:

```bash
scripts/dev/release_demo_smoke.sh --cli /path/to/macparakeet-cli
```

For development verification only, allow a SwiftPM fallback:

```bash
scripts/dev/release_demo_smoke.sh --allow-swift-run
```

Evidence is written under `.codex/release-demo-smoke/<UTC timestamp>/` unless
`--output-dir` is provided. A passing run produces:

- `summary.md` with the pass result, CLI path, isolated database, transcription
  ID, transcript preview, and evidence file list
- `commands.log` with every command and exit status
- `health.json` plus `health.stderr`
- `fixture.wav`, generated locally via `say` and `afconvert`
- `transcribe.json` plus `transcribe.stderr`
- `export.md` plus `export.stdout`/`export.stderr`

Pass/fail criteria:

- `health --json` exits successfully and emits valid JSON
- the fixture WAV is non-empty
- `transcribe --format json --database <isolated-db>` exits successfully, emits
  valid JSON, returns `status = completed`, and contains transcript text
- `export <transcription-id> --format markdown --database <isolated-db>` exits
  successfully and writes a non-empty Markdown file

Notes:

- The script intentionally does not use `--no-history`; export needs a persisted
  transcription ID. The `--database` option keeps that persistence inside the
  evidence directory instead of the user's MacParakeet database.
- The script does not repair models, download helper binaries, change signing,
  or alter distribution credentials. `health --json` is a non-mutating readiness
  probe; missing models or helpers remain visible in the saved evidence.
