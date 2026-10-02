# Validation, coverage and delivery record

## Revisions and PRs

- App audited base: `f43f4bed2ba7d4afdb005369759afc3d6cc44d34`.
- App change branch: `audit/app-review-20261002`; [find its PR](https://github.com/moona3k/macparakeet/pulls?q=is%3Apr+head%3Aaudit%2Fapp-review-20261002).
- Website base: `6a9f8ffd48338820b83677a6fbe8137558278e71`.
- Website fix: `30743ed31f1b02176f9e8a9ea4098c81b477a041`,
  [PR #102](https://github.com/moona3k/macparakeet-website/pull/102).
- App stable release when inspected: v0.8.9; this main-branch audit includes
  later development. No merge, deployment or release is part of delivery.

Both repositories were fetched and reviewed in isolated worktrees. The
original dirty checkouts, existing model assets and unrelated open PRs were
preserved. Corpus assets were public cached recordings; model assets were
cloned and hash-checked. Temporary test databases were synthetic.

## Executed checks

| Check | Result | What it proves / limit |
| --- | --- | --- |
| Clean `swift build --build-tests --jobs 8` | Exit 0, 206.30s wall / 201.90s reported build | Current local SwiftPM app/CLI/benchmark/tests compile; different toolchain from CI |
| Initial diarization/attribution/telemetry selection | 190 XCTest + 26 Swift Testing pass; 88 TelemetryService cases | Deterministic service and contract behavior |
| Library regressions before fix | 5 cases, 4 failed tests / 6 failed assertions; favorite-pagination control passed | Real stale publication/pagination defects, not just source suspicion |
| Library after fix | All 71 tests pass | Favorite/delete/audio-detach generation handling and existing Library behavior |
| CLI regressions before fix | 19 command tests: 8 failed assertions; 4 persistence tests: 45 failed assertions | Deletion/status and stale metadata loss/resurrection; deletion during Core recognition remains a passing control |
| CLI regressions after fix | 17 command + 4 persistence tests pass | Two obsolete stale-copy helper tests replaced with real Core/SQLite integration coverage |
| Onboarding native render probe | 8 before / 9 after images; scroll assertion passed | Actual production SwiftUI layout with synthetic injected state; not full app/TCC/hotkey E2E |
| Final combined focused batch | 22 pass: 21 CLI cases + temporary render case | Corrected CLI and scrollable recovery layout together |
| Full final Swift suite | 7,918 xUnit cases, 6 failures from the audit environment override, 0 other failures; 30 Swift Testing pass; 164.58s wall | One local full invocation; this is not reported as a green suite. Corrected-environment focused result is recorded below |
| Corrected-environment final focused run | 216 cases, 2 explicitly skipped, 0 failures; exit0 | All six environment-affected cases resolved as pass or intended opt-in skip; changed areas rebuilt and pass |
| CLI process smoke | Passed, collections/prompts persisted across separate processes | Built Debug CLI, production DB boundary and output; no real speech |
| CLI contract probes | 7 invocation scenarios recorded; all 139 product leaf commands cataloged | Actual exits/stdout/stderr/health behavior; no provider or packaged CLI claim |
| Synthetic 10K-row CLI probe | Five samples each: exact-ID median154ms; ambiguous-prefix149ms | No demonstrated latency regression in this warm probe; different terminal validation errors |
| CI Python helper tests | 46 pass | Local CI policy/helper behavior |
| Ask helper | Pinned Node 24.13.1 built; 14 helper tests pass | Local helper tool/message behavior, no real LLM/provider execution |
| Acoustic diarization | 4 offline runs, 2 backends × 2 public recordings | Model regression evidence; training overlap and protocol explicitly recorded |
| Real product model E2E | 1 passed in 33.58s; 706.89 MiB peak process RSS | Real Parakeet + speaker models, meeting/file, source offset, persistence, silence reset |
| Receiver onboarding regression | Fails on baseline, passes after correction | Real SQLite aggregation: current steps, same-session dedupe and legacy steps |
| Website telemetry/stats selection | 146 pass, 0 skipped on Node26.8.2 | Receiver and metric regressions, including actual TypeScript handler execution |
| Website build | `pnpm install --frozen-lockfile`, `pnpm build` pass; 86 pages | Local Astro production build; not deployed Pages/worker |
| Fresh app/receiver event comparison | 104 emitted app names accepted by 110-name receiver | Event-name compatibility only; no production ingestion or complete property-schema proof |
| Public stats GET | HTTP200, fresh snapshot age364s at 19:06:51 UTC | Public read/aggregation availability; no POST or authenticated D1 inspection |
| Exact baseline hosted CI | Run37041613709 passed; 7,908 xUnit cases, 30 Swift Testing cases | Existing macOS14/Xcode16.1 CI lanes, with skips/gaps documented separately |

The first CLI test fixture failed because its STT substitute did not honor the
pinned engine contract. That setup failure was corrected before the genuine
red run; it is not counted as a discovered product bug. The real-model E2E's
initial SwiftPM invocation hit macOS nested-sandbox rejection before tests;
direct invocation of the prebuilt XCTest bundle under the same network-deny
sandbox then passed. These setup failures are retained in local logs.

## Reproduction entrypoints

Run from the owning worktree. The following ordinary commands repeat the
bounded verification; keep real-model/native qualification in their separate
documented lanes. Do not run every command during each edit iteration.

```sh
swift build --build-tests --jobs 8
MACPARAKEET_TELEMETRY=0 swift test --jobs 8 --filter \
  'RetranscribeCommandTests|RetranscribePersistenceTests|TranscriptionLibraryViewModelTests'
python3 scripts/ci/cli-persistence-smoke.py "$PWD/.build/debug/macparakeet-cli"
scripts/build_ask_helper.sh .build/ask-runtime/AskAgentHelper .build/ask-runtime/node
MACPARAKEET_ASK_TEST_HELPER="$PWD/.build/ask-runtime/AskAgentHelper/ask-helper.cjs" \
  .build/ask-runtime/node --test Sources/AskAgentHelper/test/*.test.js
```

The single local final-suite invocation below used telemetry suppression and
an app-state override. Five default-path/preference tests correctly rejected
that environment, and the opt-in Split fixture refused to seed a non-temporary
directory. The full invocation therefore exited 1. This is audit harness error,
not evidence of six product regressions. The affected suites and all changed
areas were then rerun with the override removed: 216 cases, zero failures,
and two intended skips (real SIGINT opt-in and manual Split fixture seeding).
No second full suite was run.
An app-state override is useful for isolated runtime/model work, but must not
be applied blindly to tests whose contract checks default paths. It also does
not isolate preferences, Keychain or TCC.

```sh
MACPARAKEET_TELEMETRY=0 \
MACPARAKEET_DEBUG_APP_STATE_DIR="$PWD/.build/audit-state/full-suite" \
MACPARAKEET_ASK_TEST_NODE="$PWD/.build/ask-runtime/node" \
MACPARAKEET_CLI_TEST_EXECUTABLE="$PWD/.build/debug/macparakeet-cli" \
  /usr/bin/time -l swift test --jobs 8 --parallel \
  --xunit-output .build/audit-evidence/final-swift-tests.xml
```

The corrected run uses `env -u MACPARAKEET_DEBUG_APP_STATE_DIR` and the filter
`AppPathsTests|ConfigCommandTests|MeetingSplitCommandTests|SplitAndTranscribeFixtureSeedTests|RetranscribeCommandTests|RetranscribePersistenceTests|TranscriptionLibraryViewModelTests`.
It also rebuilds the final formatting-only adjustments to the changed Swift
files. Formatting review reports no warnings intersecting added/changed lines;
pre-existing warnings elsewhere were retained rather than reformatted.

For receiver repetition, `pnpm test:telemetry` runs the repository's telemetry
selections, including rollup tests; `pnpm build` checks Astro output. Node must
support actual handler imports, otherwise inspect/report skipped tests rather
than calling a skipped route test green.

The [native render reproducer](evidence/gui-onboarding/README.md) explains how
to temporarily add the audit capture test and remove it again. It is archived
outside the test target; no permanently skipped screenshot probe was added to
CI. The diarization [run receipt](evidence/diarization/run-receipt.json),
[product receipt](evidence/diarization/product-e2e-summary.json) and benchmark
README define the separate model/scorer inputs, sandbox and hashes.

## Evidence inventory and independent review

The [machine-readable validation receipt](evidence/validation-receipt.json)
records the tested code commit, results and hashes of retained local logs.

Committed evidence contains sanitized JSON metrics, source/model hashes,
synthetic screenshots and a public-fixture replay script. Full logs, test XML,
public acoustic predictions and raw public-corpus ASR output remain under
`.build/audit-evidence/` rather than bloating committed reports. Public stats
evidence keeps selected aggregate values, not private error text or identifiers.

- Diarization reviewer checked both model routes and real product projection;
  independently reviewed the CLI production/test diff with no blocker.
- CLI/data reviewer checked persistence and process boundaries; independently
  reviewed the Library and receiver fix diffs with no blocker.
- GUI reviewer reproduced the stale Library snapshot and native layout
  defects, then checked the after renders and actual scroll behavior.
- Local Greptile CLI review of committed source fixes was attempted at
  `bab48ccea` but could not run: the installed CLI is not signed in and no
  `GREPTILE_API_KEY` was supplied. This is unavailable review evidence, not a
  pass; independent reviews below remain the completed review lane.
- Root reviewer traced each proposed repair and reviewed cross-report claims;
  a separate synthesis review challenged documentation/evidence consistency.
- Website PR #102 automated review at `30743ed` reported no issues (cubic);
  CodeRabbit supplied a summary, not a full line-by-line paid review.

Review findings are evaluated against code/evidence, not treated as automatic
approval. The audit uses explicit local verification and independent reviews;
no auto-merge workflow or `no-mistakes` pipeline was started. No Jev decision
step was used; all audit judgments came from direct agent analysis and tests.

## Coverage boundaries and next gates

| Lane | Current evidence | Still required for stronger claim |
| --- | --- | --- |
| CLI automation | Parser/body tests, runtime contract probes, real DB/process smoke, mutation regressions | Packaged installed CLI with actual model/provider for each supported engine |
| GUI/onboarding | Source flow/state review, focused models, actual synthetic SwiftUI renders | Disposable native account; clean install, TCC, hotkeys, focus, real insertion, relaunch |
| Speaker quality | Current acoustic comparisons and one real product E2E | Held-out reference-word attribution, overlap/short turns, mic-room scope, sustained workload |
| Audio capture | Source/lifecycle tests; existing hosted synthetic process recovery | Physical microphone/system/Bluetooth/echo, device changes and real long calls |
| Observability | Client tests, real receiver handler tests, local schema comparison, fresh public read | Staging ingest/store/retry/redaction, receiver #101 rollout and production version confirmation |
| Performance | Current hosted timings, local build, Debug model diagnostics, public aggregate tails | Optimized repeated matched workloads, constrained hardware, memory-pressure and actual insertion |
| Security/data | Targeted consent, schema, process/path and persistence review | Broader dependency/cryptographic/decoder audit; full synthetic backup/restore drill |
| Distribution | Existing baseline Release/bundle lanes | Exact candidate signing/notarization, installed upgrade and physical/native release qualification |

Passing unit tests, a large count, a fresh dashboard and a model result are
different evidence lanes. None substitutes for the missing native, device,
receiver or release proof described above.
