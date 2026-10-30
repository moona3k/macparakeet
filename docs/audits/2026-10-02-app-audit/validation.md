# Validation, coverage and delivery record

## Revisions and PRs

- App audited base: `f43f4bed2ba7d4afdb005369759afc3d6cc44d34`.
- App change branch: `audit/app-review-20261002`; [find its PR](https://github.com/moona3k/macparakeet/pulls?q=is%3Apr+head%3Aaudit%2Fapp-review-20261002).
- Website base: `6a9f8ffd48338820b83677a6fbe8137558278e71`.
- Website fix: `30743ed31f1b02176f9e8a9ea4098c81b477a041`,
  [PR #102](https://github.com/moona3k/macparakeet-website/pull/102).
- App stable release when inspected: v0.8.9; this main-branch audit includes
  later development. Initial audit delivery opened PRs without merging or
  deploying. The later owner-authorized landing is tracked in
  [follow-through](follow-through.md); deployment and release remain separate.

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
| Library initial repair (before review refinement) | All 71 tests pass | Favorite/delete/audio-detach generation handling and existing Library behavior |
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

## Landing review follow-up

After the owner authorized merge, review identified a main-actor read in the
new Library replacement refresh. Five thread-ownership regression assertions
failed before the refinement. The corrected loader reuses the existing
asynchronous path; all 74 focused Library cases pass, including stale
result/error and refresh-failure coverage. No second full local suite was run.
Exact revised-head hosted CI is required before merge.

The final review also reproduced bulk mutation stale snapshots (three failed
cases/five assertions) and GUI post-Core transcript-correction loss (one failed
case/two assertions). After those repairs, all 264 focused GUI cases pass:
80 Library, 166 transcription view-model, 16 batch and two Core/SQLite
persistence cases. The shared service mock now models Core's in-place commit
through both base and speaker-override protocol paths. An initial combined run
exposed four mock-dispatch failures; correcting that test double yielded the
final passing selection. No additional full local suite was run.

Website PR #102 was merged after rerunning all 146 telemetry tests and the
86-page build. An actual local browser probe also exercised the built stats
page with legacy and current snapshots. Legacy hover text reports step events;
current hover text reports sessions. Both had zero page errors. The sanitized
[browser receipt](evidence/onboarding-dashboard-browser.json) records the
source tree and script hash. This is runtime rendering evidence with injected
public-data fixtures, not deployed receiver proof.

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

## Final landing and physical follow-through

App [PR #1205](https://github.com/moona3k/macparakeet/pull/1205) and
[cancellation PR #1206](https://github.com/moona3k/macparakeet/pull/1206) merged
on October 2 after their final heads passed hosted tests, Swift 6 and release/
bundle checks, with no unresolved review threads. Each run reports 7,929 xUnit
cases with zero failures/errors plus 30 Swift Testing cases; xUnit does not
report skipped-case counts. The telemetry allowlist comparison and opt-in
cache-invalidation job skipped. Final receipts and test summaries:
[#1205](evidence/pr1205-final-ci.json),
[#1205 test summary](evidence/pr1205-test-summary.md),
[#1206](evidence/pr1206-final-ci.json),
[#1206 test summary](evidence/pr1206-test-summary.md).

After both merges, 440 distinct focused cases passed on combined `main`
`f3a8758ae7be4c0b3fdd65aa37a5a5cfea3072bd`: 424 in the main selection and
16 batch cases in a separate invocation after correcting the filter's suite
name. This rebuilt from the integrated source in its owning worktree and
covers CLI/GUI persistence, Library, both diarization adapters and transcription
orchestration together. [Receipt](evidence/integrated-main-tests.json).
No second full local suite was run. The hosted results above are separate
per-PR results, not a claim that post-merge main CI had finished.

A final review's stale-error concern was already prevented by the current
clearing behavior. Two targeted cases passed with a temporarily strengthened
assertion; the patch was then removed without changing the reviewed source.
[Adjudication receipt](evidence/library-stale-error-adjudication.json).

The owner skipped first-run qualification and authorized physical capture on
this Mac. Short native dual-source and microphone-only recordings completed,
recognized the known phrases in the normal-gain runs and survived database
reopen. The lower-gain probe's absent recognized phrase is retained explicitly.
The [physical report](native-audio.md) and [sanitized receipt](evidence/native-audio.json)
record source coverage, artifacts, unavailable AEC assets and remaining limits.
No raw physical media, incidental transcript or screenshot was published.

The final native-audio report/receipt received an independent factual/privacy
review with no blockers. This audit used direct engineering review, source
inspection and deterministic checks; no Jev classification step was used.
