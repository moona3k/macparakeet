# Synthetic CLI contract verification

Status: **PASS** for the bounded synthetic matrix on September 7, 2026. Root owns the candidate build and all Swift gates. Run 02 completed 18 CLI invocations and 10 loopback provider requests, with every asserted outcome passing.

The runner uses the existing DEBUG CLI from candidate `8548c099af5ee2ab0ed4dd9efe757d85c498cca0`, an owned DEBUG state directory, an owned `CFFIXED_USER_HOME`, an explicit owned SQLite database, telemetry disabled, and a synthetic HTTP server bound to loopback. It never changes app configuration, model selection or Keychain. The environment override is an experiment for this run, not an official full-isolation recipe.

Fixture setup is explicit: the CLI initializes its schema and adds a custom prompt; Python SQLite inserts an invented transcription and the prompt's inference settings. This verifies the executable/persistence boundary, not GUI editing or real inference quality. The legacy migration fixture reconstructs the pre-v0.29 column shape from this owned database; it is not a database produced by a v0.7.3 binary.

Reusable runner: [`scripts/verify_cli_contracts.py`](scripts/verify_cli_contracts.py). Runtime evidence is retained under `/tmp/macparakeet-080-qa/cli-contract-runtime/` with binary identity, arguments, exit codes, stdout/stderr, synthetic requests and stored results. No Swift build/test, audio or GUI invocation is performed by this runner.

## Historical run-02 execution

This recorded command uses the original runner identified by the SHA-256 below,
not the current reusable runner. Keep the original runner and CLI 3.3.0 binary
together when reproducing run-02; the current runner requires the newer schema
and defaults to CLI 4.0.0.

```bash
python3 docs/qa/2026-09-07-0.8.0/scripts/verify_cli_contracts.py \
  --cli .build/debug/macparakeet-cli \
  --output /tmp/macparakeet-080-qa/cli-contract-runtime/run-02 \
  --candidate 8548c099af5ee2ab0ed4dd9efe757d85c498cca0
```

- The runner now defaults to expecting CLI `4.0.0` (PR #982). Reproducing this run-02 against the `3.3.0` candidate binary requires `--expected-cli-version 3.3.0`. The runner SHA-256 recorded below identifies the pre-#982 runner that produced run-02, not the current file.
- The current runner also targets the versioned prompt schema that PR #961 merged after run-02: it seeds inference settings through `prompts set` instead of writing the removed `prompts.inferenceSettings` column, and its legacy fixture reconstructs only the pre-v0.29 transcription columns while asserting the active `prompt_versions` settings survive migration and the removed `prompts.inferenceSettings` column stays absent. It does not reconstruct the v0.31 prompt column, because the one-shot v0.36 rebuild cannot rerun to remove it again. Run-02 predates that schema, so the reproduction command above requires the `3.3.0` binary and the recorded pre-#982 runner; the current runner runs against a `4.0.0` binary with one more CLI invocation (`seed-settings`).
- Executed binary SHA-256: `db8626c81735d0484878f396cae83c6a911a6cba9ff97d0a9ee139eb2cdcf690`.
- Candidate source identity was supplied by root's build record; `--version` and `spec --json` independently returned CLI `3.3.0`.
- Runner SHA-256: `7fd4ee9979a7c77e912fda2fd44074e84db0abea4dd7899ce4d1bcf7b65a0271`.
- `run-02/result.json`, `commands.json`, `requests.json`, `saved-results.json`, `legacy-before.json`, `legacy-after.json` and `additional-checks.json` retain the evidence. Individual commands have separate stdout/stderr files.

## Observed outcomes

| Boundary | Executed assertion | Result |
| --- | --- | --- |
| Version/catalog | Both identify CLI 3.3.0 | Pass |
| Prompt settings read | Directly seeded settings return through `prompts show --json` | Pass |
| Summarize receipt | No saved prompt needed; JSON contains temperature 0.7 and provider-default thinking, matching the request | Pass |
| Prompt request | Temperature 0.25, Top P 0.85, Top K 24, max tokens 256 and enabled/low thinking match the saved settings | Pass |
| Nonstream receipt | Response JSON and persisted result retain the exact effective settings | Pass |
| Stream success | Complete text and the effective receipt persist after the terminal marker | Pass |
| Authentication/rate limit | Exit 1 with JSON `auth`/`rate_limit`; existing results unchanged | Pass |
| Invalid response | Exit 1 with JSON `invalid_response`; existing results unchanged | Pass |
| Partial stream then error | Exit 1; no result saved, existing result rows unchanged | Pass |
| Empty stream | Exit 1; no result saved, existing result rows unchanged | Pass |
| Compatible clean EOF | Content-bearing EOF without `[DONE]` remains an accepted success | Pass |
| Cancellation | SIGINT sent only after the server emitted content; native signal exit -2 maps to shell exit 130; no new result | Pass |
| Hide/show settings | Two CLI toggles preserve the inference settings exactly | Pass |
| Legacy-shaped schema | CLI migration restores all four new columns, preserves one synthetic transcript and three results, and leaves missing metadata/settings null | Pass |
| Database integrity | Post-upgrade `integrity_check` is `ok`; `foreign_key_check` has no violations | Pass |
| Provider isolation | All ten requests reached the owned loopback server without an Authorization header | Pass |

## What did not work and what this does not prove

Run 01 used a text UUID for the direct SQLite transcription fixture. The CLI could read it, but saving a related result correctly failed its foreign-key check because GRDB encodes UUIDs as 16-byte BLOBs. The fixture was corrected to match the CLI-created prompt's storage representation. This was a harness defect, not a product defect; its stdout, request and failure envelope remain in `run-01/`.

The matrix does not prove GUI prompt editing, GUI cancellation, real provider compatibility, inference quality or full production-user isolation. SIGINT verifies process cancellation and persistence, not cleanup through the GUI's Cancel control. The legacy fixture verifies a reconstructed schema upgrade; an actual old-binary-created database remains distinct evidence. No application implementation changes resulted from this run.
