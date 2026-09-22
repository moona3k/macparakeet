# DAPT export runtime verification

Status: **PASS** on September 7, 2026 for all three representative exports. The existing candidate CLI exported three owned synthetic fixtures: aligned words with speakers, aligned words without speakers, and edited text with stale timing/speaker metadata that remained untimed and unattributed in DAPT.

Validation runs locally in two layers: direct XML Schema validation against the W3C DAPT XSD vendored in a pinned BBC checkout, followed by the BBC validator's complete DAPT rule set. DAPT's XSD is an informative implementation aid; the additional rules cover constraints beyond the schema. Sources: [W3C DAPT](https://w3c.github.io/dapt/), [BBC validator documentation](https://bbc.github.io/ttml-validator/).

No transcript upload, real audio, GUI invocation or Swift build/test is involved. The owned fixtures also exercise Markdown, SRT and JSON export preservation. Fixture rows are inserted directly into a schema created by the candidate CLI; this is not an import or GUI-edit test.

Runner: [`scripts/verify_dapt_exports.py`](scripts/verify_dapt_exports.py). Evidence directory: `/tmp/macparakeet-080-qa/dapt-runtime/`.

## Exact tools and execution

- Candidate source, from root's existing build record: `8548c099af5ee2ab0ed4dd9efe757d85c498cca0`.
- CLI binary SHA-256 before and after execution: `db8626c81735d0484878f396cae83c6a911a6cba9ff97d0a9ee139eb2cdcf690`.
- BBC validator commit: [`011bdfdd87c0422119ec2abd196ec2318956c716`](https://github.com/bbc/ttml-validator/tree/011bdfdd87c0422119ec2abd196ec2318956c716).
- Python `3.14.6`; `xmlschema==4.3.1`, `charset-normalizer==3.4.7`, `elementpath==5.1.4`; editable validator `0.1.0` at that commit.
- Direct XSD entry point: [`src/schemas/xsd/dapt/dapt.xsd`](https://github.com/bbc/ttml-validator/blob/011bdfdd87c0422119ec2abd196ec2318956c716/src/schemas/xsd/dapt/dapt.xsd), SHA-256 `d9222a3f69f74cf3ccbb7c32bb4c20a551d1628bc155b096f18194439f3ad23d`. This is the vendored W3C schema snapshot; it was not substituted with an ad hoc schema. All schema imports resolved locally with `allow="local"`.

The precreated virtualenv was completed with `.venv/bin/python -m pip install -e .` inside root's owned validator checkout. Exact resolved dependencies and install output are retained locally. The runner then executed:

```bash
/tmp/macparakeet-080-qa/ttml-validator/.venv/bin/python \
  docs/qa/2026-09-07-0.8.0/scripts/verify_dapt_exports.py \
  --cli .build/debug/macparakeet-cli \
  --validator /tmp/macparakeet-080-qa/ttml-validator \
  --output /tmp/macparakeet-080-qa/dapt-runtime/run-01 \
  --candidate 8548c099af5ee2ab0ed4dd9efe757d85c498cca0
```

For each file, it separately ran `xmlschema.XMLSchema(..., allow="local").iter_errors(...)` and:

```bash
validate-ttml -flavour dapt -ttml_in <fixture>.dapt.xml \
  -results_out <fixture>-bbc.json -json
```

## Observed results

| Fixture | Direct XSD | BBC DAPT | Semantic checks |
| --- | --- | --- | --- |
| Timed, two speakers | Pass, no schema errors | Exit 0 | Portuguese text and escaped punctuation preserved; two agents; aligned timing retained |
| Timed, no speakers | Pass, no schema errors | Exit 0 | English text and timing preserved; no agents; SRT retains 00:00:00,250–00:00:01,100 |
| Untimed, edited | Pass, no schema errors | Exit 0 | Edited text preserved; stale words and legacy speaker roster do not produce DAPT timing/agents; unknown language is `und` |

Each BBC run recorded 19 passing checks, three informational messages, one warning and no errors or skipped checks. The warning is `copyright element absent`. The selected DAPT rule configures copyright as optional (`copyright_required=False`), so this does not fail validation. The validator's DAPT summary reports no DAPT-related warnings. The app should not invent copyright metadata to silence this optional warning.

All three fixtures also passed DAPT stdout/file parity and Markdown/SRT/JSON preservation assertions. JSON retains the stored word timestamps and edit-state metadata; rendered Markdown/SRT use the edited text when applicable. Sixteen CLI invocations and three BBC validation invocations completed successfully. The remaining three recorded commands capture validator Python, dependency and Git identities.

## Evidence and limits

`run-01/` retains the 12 exported files, each DAPT stdout output, three XSD reports, three BBC JSON reports, per-command stdout/stderr, fixture definitions, commands, metadata and final result. The validator setup log is `/tmp/macparakeet-080-qa/cli-contract-runtime/validator-install.log`.

No product or validator repair was needed. Direct XSD validation and the BBC DAPT rules are two validation layers using the same pinned schema snapshot and Python XML Schema dependency; they are not independent schema implementations. The BBC checkout's optional DAPT test-suite submodule was not initialized or run. These results establish structural validity and the asserted semantics for the three exported fixtures, not editor interoperability, actual audio alignment or every DAPT document the app could produce.
