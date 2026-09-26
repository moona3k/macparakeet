# Test value audit: contracts, false confidence, and stronger boundaries

Audit date: 25 September 2026, Pacific time. Product source snapshot: `59e7adf085277ea82ee9bb5f15a7b8cb315ebd91`. CI evidence: [PR #1161](https://github.com/moona3k/macparakeet/pull/1161), initially `8a8a597b`, subsequently repaired at `8ce7f43e`. Neither CI commit changes `Sources/`, `Tests/`, `Package.swift`, or `Package.resolved`.

This is an evidence-backed audit and proposed sequence. It makes **no test deletions or product changes**. The discovery covers the tracked test tree, with deeper owner/history reviews of the candidates below; it is not a claim that every test declaration has been individually reviewed.

## Recommendation

**Keep improving confidence per test, rather than reducing the test count.** The CI change already demonstrated that orchestration was the large delay: the first paired hosted comparison fell from 55m 11s to 27m 55s without removing a test. The remaining suite contains some misleading assertions and duplicates, but the evidence does not justify a broad purge or replacing deterministic tests with UI automation.

The most useful next batches are:

1. Consolidate error-description coverage: fill gaps in the exact STT error table, then remove the weaker STT/audio non-nil checks. This improves the contract while reducing repetition.
2. Remove disconnected clipboard assertions from cancellation tests, and put any missing no-paste regression at the real dictation coordinator boundary. Preserve the service's real cancellation and persistence checks.
3. Add the existing cheap release-version and privacy-verifier fixtures to distribution CI. They catch meaningful regressions and currently are not routed into ordinary CI.
4. Separate the test-local AEC research measurements from default regression coverage only after preserving their reproducible measurement workflow. Keep production streaming, renderer, and durable-audio tests.
5. Extend integration coverage where layers actually meet: CLI meeting read/edit/export across processes, then one native Library save/relaunch/export journey. Keep deterministic concurrency tests for precisely controlled races.

Small duplicate/mock-only cleanups are worthwhile maintenance work, but are not a credible explanation for the old 55-minute wait.

## Method and scope

The audit applies [OpenClaw's test-audit skill at commit 80930af](https://github.com/openclaw/openclaw/blob/80930af448ebabc84174146b56bc106d37fab3b4/.agents/skills/test-audit/SKILL.md). A candidate needs a concrete failure it can detect, its real production owner/callers, overlapping proof, relevant history, and a safe validation path. A suspicious pattern starts an investigation; it is not a deletion rule. Public contracts, persistence, privacy, platform behavior, and observable ordering can justify apparently simple tests. MacParakeet's Swift commands and review workflow replace OpenClaw-specific Node tooling.

Three discovery passes covered Core/audio/STT/storage; UI/view models/CLI/integration; and a mechanical inventory. A separate reviewer challenged the proposed deletions. The primary review examined tooling/privacy boundaries, reproduced a historical verifier defect, and reconciled the hosted evidence. These were technical source/history reviews and deterministic searches; no Jev classification was used.

The tree contains **440 tracked Swift files under Tests**: 414 in `MacParakeetTests` and 26 in `CLITests`, including helpers. Both targets are in the normal SwiftPM run. The new hosted XML contains **7,567 XCTest entries** and a companion report for **30 Swift Testing cases**. XCTest's report omits skip markers; these numbers must not be relabeled as 7,567 successful executed assertions or as independent contracts. Model, permission, hardware, and explicit environment gates still skip some paths.

`rg` searches for source reads, duplicated assertions, mocks, sleeps, and skip guards supplied leads. Most file reads were of actual exported artifacts, persisted records, or logs. Apparent assertion-free functions often called assertion-bearing helpers. Those matches were not counted as defects. This matters: an automated pattern score would have produced false positives in precisely the tests that exercise real boundaries.

## What CI now establishes

The [before run](https://github.com/moona3k/macparakeet/actions/runs/36205356185) and [first after run](https://github.com/moona3k/macparakeet/actions/runs/36207574811) use identical product source and tests. The first after run predates the logging-only repair at `8ce7f43e`; it is timing evidence for the initial scheduling change, not final-head validation of that repair.

| Measurement | Before | First after |
|---|---:|---:|
| Workflow creation to final job completion | 55m 11s | 27m 55s |
| Workflow creation to `Swift Test` step | 45m 05s | 6m 26s |
| `Swift Test` step | 10m 01s, includes compilation | 7m 19s, already-built tests |
| Summed occupied runner time | 55m 04s macOS | 45m 15s macOS + 3s Linux |
| Test inventory | 7,567 XCTest selections + 30 Swift Testing passes | Same inventory in retained XML/logs |
| Downloadable evidence | No log artifact despite a successful upload step | Test and distribution artifacts downloaded and inspected |

The observed reductions are 49% elapsed time and 18% occupied runner time **for this pair only**. They are not billing figures or a controlled estimate of savings attributable solely to the workflow: Release and Xcode build durations also varied between runners. The [earlier CI audit](2026-09-25-ci-cost-and-test-strategy.md) remains the 24-successful-run baseline and separates measured evidence from scheduling estimates.

The new real CLI smoke passed in approximately one second. It creates and reads prompts/collections in separate executable processes, renames a collection, deletes it while preserving its prompt, and checks the missing-ID JSON error. This adds parser/process/SQLite composition proof that in-process command tests do not supply. It does not exercise speech recognition, GUI/TCC, or a signed release.

Per-case xUnit times measure a test process lifetime, including startup and setup/teardown under concurrent load. They are useful profiling leads, not method-only CPU measurements; summing parallel cases does not yield elapsed savings. Two NLMS cases each report about 21.72 seconds, while some simple cases also have long process durations. No deletion recommendation below relies on those numbers alone.

## Candidate ledger

### A. Error-description contract consolidation — first cleanup batch

**Tests and owners.** `AudioFileConverterTests.testAudioProcessorErrorDescriptions` (`Tests/MacParakeetTests/Audio/AudioFileConverterTests.swift:194`) only checks seven constructed errors have non-nil descriptions. The production enum is `AudioProcessorError` in `Sources/MacParakeetCore/Audio/AudioProcessorProtocol.swift:161`; recorder, converter, dictation, and telemetry paths consume it. `DictationServiceErrorTests.swift:26` already checks the exact descriptions of all seven and three input-unavailable variants.

The analogous `STTClientTests.testSTTErrorDescriptions` (`Tests/MacParakeetTests/STT/STTClientTests.swift:221`) checks eight non-nil values. `STTError` in `Sources/MacParakeetCore/STT/STTClientProtocol.swift:179` is emitted by real runtime/scheduler/engine paths. The exact table in `DictationServiceErrorTests.swift:12` misses `engineBusy` and `engineStartFailed`, so deleting the non-nil check immediately would discard weak but unique coverage. `modelDownloadFailed` is missing from both tables.

**Failure and history.** Wrong/swapped text passes the non-nil assertions; the exact table catches it. The weaker checks date to the initial `92460f82f` suite, while later capture failure work, including `6b65b34ad`, strengthened the error contracts. These are real user-visible errors, not dead production code.

**Action and remaining proof.** Extend the exact STT table for the missing variants, then remove the two non-nil replay methods. Preserve error propagation/classification tests: they exercise distinct contracts. No production seam is removed; only test repetition decreases. Risk is low after the table is complete. This is a confidence improvement, not a meaningful runtime optimization: the observed two process durations are about 0.06 seconds each.

**Focused verification:** `swift test --filter 'DictationServiceErrorTests|AudioFileConverterTests|STTClientTests'`. Introduce a temporary wrong description at an added variant to establish the new assertion catches its intended failure. That mutation was not run in this audit.

### B. Disconnected clipboard assertions — remove the false claim

**Exact tests.** `CancelFlowTests.testCancelDoesNotPasteOrSave` and `testSTTErrorDuringStop`, in `Tests/MacParakeetTests/Integration/CancelFlowTests.swift:26` and `:98`, assert `mockClipboard.pasteCallCount == 0`. The mock is created at lines 9/16 but is never supplied to `DictationService`. The initializer at lines 19–23 receives audio, STT, and the repository only.

**Failure and owner.** Those two clipboard assertions cannot detect a product paste. The same tests' database-empty and STT-error assertions are real and must stay. Actual paste ownership lives in `Sources/MacParakeet/App/DictationFlowCoordinator.swift:814`; service cancellation remains in `Sources/MacParakeetCore/Services/Dictation/DictationService.swift:803`.

**History and overlap.** Commit `f14f00ff0` deliberately removed the unused clipboard parameter from the service and stated that the coordinator owns pasting. The test mock survived that refactor. `DictationFlowCoordinatorTests.swift:210` and `:286` use connected clipboard fixtures for practice dismissal, clipboard-only operation, and pending delivery. They do **not** establish an exact replacement for ordinary cancel-before-STT no-paste behavior.

**Action.** Remove only the unused mock/setup and two vacuous assertions; rename the first test to its actual no-save contract. Retain cancellation, capture, persistence, error, and race assertions. If no-paste-on-cancel needs additional proof, add a deterministic coordinator test: hold STT completion, cancel, release the old result, and assert the connected clipboard remains untouched. Do not claim that removing the disconnected mock creates that missing proof.

The document challenge found a second required assertion: cancellation during processing can cancel the coordinator task and suppress paste while a non-cooperative STT completion still reaches service persistence. This is source evidence, not a runtime reproduction. The new test must settle the service after releasing STT and inspect History as well as the clipboard. Follow the existing policy in `spec/02-features.md:396–397,2255`: default cancellation discards; explicitly preserved discarded takes require History and are `cancelled`, never `completed`. Preserve newer-session ownership while repairing any reproduced gap. A negative timed wait alone cannot prove completion or non-delivery.

No production code is deleted. Cleanup risk is low; the new race test needs careful session ownership and deterministic waits. **Focused verification:** `swift test --filter 'CancelFlowTests|DictationFlowCoordinatorTests'` plus the relevant service cancellation race suite for any behavioral change.

### C. MockSTTClient self-tests — small maintenance cleanup

`STTClientTests.swift:232–284` contains `testMockSTTClientTranscribe`, `testMockSTTClientError`, `testMockSTTClientWarmUp`, `testMockSTTClientShutdown`, and `testMockSTTClientClearModelCache`. They configure or invoke `Tests/MacParakeetTests/STT/MockSTTClient.swift` and assert its returned values, counters, or flags. No real engine, scheduler, or audio is invoked.

These scaffold-era tests (`92460f82f`) can detect changes to the fake, but product-owner tests already consume it, including the real service/repository flow in `Integration/DictationFlowTests.swift:23`. Remove these simple self-tests only; keep the fixture and its consumer tests. This is not a rule against testing sophisticated concurrency/fault-injection helpers: a complicated helper can have its own independent correctness risk.

No production seam or meaningful runtime cost is removed. Risk is low; a fixture typo should fail the consuming contract tests. **Focused verification:** `swift test --filter 'STTClientTests|DictationFlowTests'`, with consumer tests for any helper field actually changed. The helper itself need not change for this cleanup.

### D. Test-local AEC characterization — preserve the research, reconsider its routing

**Exact tests.** `MeetingAecMeasurementTests.testNLMSDoubleTalkQuantifiesTheTradeoff` and `testNLMSDoubleTalkSIRSweepReportsOverlapAccuracyAndEchoOnlyResidual`, in `Tests/MacParakeetTests/Services/Capture/MeetingAecMeasurementTests.swift:117` and `:156`, run synthetic signals through the test-local `MeetingAecNLMSProcessor` in `MeetingAecMeasurementHarness.swift:487`.

**Actual contract.** The first characterizes a deliberately weak baseline and asserts limited double-talk improvement. The SIR sweep gates echo-only residual reduction while printing overlap measurements. Both use a real `StreamingMeetingEchoSuppressor`, so they are not wholly disconnected from production. However, a shipping LocalVQE model/loader/factory failure can leave both green. Their quality thresholds concern a research processor, not the shipping model's speech quality.

**History and callers.** `5e9120c9b` (#624) introduced a pre-engine-selection measurement yardstick; `983654e96` (#669) added the SIR table. The NLMS implementation is test-only, but renderer and opt-in model-scoring tests reuse it. The production wrapper is constructed by `MeetingEchoSuppressionFactory` and used by cleaned-mic rendering.

**Remaining proof and action.** Direct wrapper tests in `MeetingEchoSuppressorTests.swift:5–104` cover frame carriage, reference alignment, batch invariance, and flush. `MeetingCleanedMicRendererTests.swift:30–120` drives real alignment/file writing and decoding. Keep both. Move the two characterization cases to an explicit measurement workflow only after preserving the historical outputs, invocation, and harness users. Do not delete the shared harness as collateral cleanup. Opt-in model tests remain separately necessary; no current default test establishes real LocalVQE speech quality.

This is a separate AEC-owned batch, not part of error-copy cleanup. Risk is medium if reproducibility is lost; observed process durations cannot establish the wall-time gain. **Focused verification:** `swift test --filter 'MeetingAecMeasurementTests|MeetingEchoSuppressorTests|MeetingCleanedMicRendererTests'`, plus an explicit invocation of the retained measurement workflow. No AEC tests were rerun locally during this audit.

### E. Search composition and duplicate availability assertions — lower priority

`DictationFlowTests.testDictationSearchAfterSave` (`Integration/DictationFlowTests.swift:97`) starts/stops the real service with fake capture/STT, waits 600 ms, inserts a second row directly, and queries the repository. It never drives the history view model. It catches real save/search composition failures, but `testFullDictationFlow`, `DictationRepositoryTests.testSearchFindsMatchingDictations` and its siblings, and history-view-model search tests already cover the constituent owners. Production search is a SQL `LIKE` query (`DictationRepository.swift:253`), not an FTS index despite an old test heading. No dedicated regression provenance beyond the original suite was found.

Removal is reasonable but optional: it removes test LOC and a fixed wait, not production complexity. A stronger replacement, if needed, would exercise the actual view model with mixed rows in a real temporary repository. **Focused verification:** `swift test --filter 'DictationFlowTests|DictationRepositoryTests|DictationHistoryViewModelTests'`. Do not report 600 ms as wall-time savings in a parallel run.

`MeetingTranscriptProcessingPresentationTests.testCompletedTranscriptRetainsExistingActionAvailability` (`Views/MeetingTranscriptProcessingPresentationTests.swift:44`) repeats the identical pure `canEdit(.completed)` assertion at lines 45 and 54. Keep the first, the retranscribe check, and other state cases; remove the second opportunistically. Commit `b132f7fed` explains the real completed-state availability contract. This is four lines, no independent failure detection, and no reason for its own PR. **Focused verification:** `swift test --filter MeetingTranscriptProcessingPresentationTests`.

### F. CLI registration probe — conditional consolidation

`SpecCommandTests.testSpecCommandIsRegisteredAtTopLevel` (`Tests/CLITests/SpecCommandTests.swift:72`) checks the root command type list. The same file's catalog/root/path checks at lines 194 onward cover registration, while the required distribution job executes the packaged binary's `spec --json` and parses its output. Those boundaries catch missing registration and more.

The public `spec` API and its catalog tests must remain. Commit `142a7f9bbb` introduced the agent-facing contract and binary smoke validation. This one narrow method is conditionally redundant if both stronger checks stay. No production export is removed. **Focused verification:** `swift test --filter SpecCommandTests` and the packaged CLI smoke. This is lower priority than false-confidence fixes.

### G. Library query/style claim — repair, do not delete

`LibrarySourceLabelStyleTests.testMappingMatchesEveryQueryNarrowing` (`Tests/MacParakeetTests/ViewModels/LibrarySourceLabelStyleTests.swift:63`) enumerates twelve scope/filter/style pairs but calls only `sourceLabelStyle`. It never exercises `TranscriptionLibraryViewModel.makeQuery`, so a query broadening can leave the purported query-drift guard green.

The test still detects style mapping changes and new filter cases. Its contract is meaningful source attribution, and `6c9f0966c` added the table to replace an earlier tautology. Real query tests exist in `TranscriptionLibraryViewModelTests`, but no demonstrated test pairs the actual mixed-source results and style across these combinations. The production style helper has real callers; it is not a test-only seam.

Tighten the claim now or replace the test with a real view-model/GRDB fixture for the risky combinations. Do not simply delete the table because neighboring style tests overlap. A replacement should fail when the query includes an incompatible source while the label style remains unchanged. **Focused verification:** `swift test --filter 'LibrarySourceLabelStyleTests|TranscriptionLibraryViewModelTests'`. Replacement risk is moderate until that mutation is demonstrated.

### H. VAD simulation assertions — retain the wrapper contract, improve expectations

`MeetingVADChunkingSimulatorTests.swift:13–65` compares simulation output with another run of the same fixed chunker and checks positive timing values. Shared chunker defects can agree on both sides, and a positive clock delta says little. The trailing-batch case does not establish the identity of the final retained samples.

But `MeetingVADChunkingSimulator` is called by the real `meeting-vad-sim` CLI (`Sources/CLI/Commands/MeetingVADSimCommand.swift:42`), so wrapper batching and report assembly are legitimate contracts. Commit `8fb75bd49` introduced this corpus-replay tool deliberately. Independent fixed-chunker tests remain, but do not by themselves prove simulator report assembly.

Retain the file; replace mirrored expectations with hand-calculated chunk boundaries/sample counts and final-tail identity when next touching this tool. Drop timing positivity only as part of that coherent improvement. The observed process time is about 0.15 seconds; this is test quality work. **Focused verification:** `swift test --filter 'MeetingVADChunkingSimulatorTests|FixedMeetingLiveAudioChunkerTests|MeetingVADSimCommandTests'`.

### I. Test-only database insertion wrapper — remove the seam, retain the CLI contract

`DatabaseManager.recordAppliedMigrationIdentifierForTesting` (`Sources/MacParakeetCore/Database/DatabaseManager.swift:72`) is a DEBUG-only one-row SQL insertion wrapper. Its sole repository caller is `ModelLifecycleCommandTests.swift:45`, which inserts a future migration marker and verifies that the CLI health probe reports schema skew instead of decoding an incompatible database as healthy. Commit `0179db4df` introduced that important stale-CLI protection.

The same test file already writes the migration ledger through `db.dbQueue.write` for another fixture. Inline this fixture-owned insertion there, remove the production test-only wrapper, and keep the existing schema-skew assertions. Preserve `unknownAppliedMigrationIdentifiers` and `registeredMigrationIdentifiers`: the real health command uses them. This is a small, low-risk production simplification with an unchanged owner-boundary test. **Focused verification:** `swift test --filter ModelLifecycleCommandTests`.

## Valuable tests that a mechanical cleanup would wrongly remove

### Release policy fixtures need more routing, not less proof

`scripts/dist/test_verify_app_privacy_surface.sh:133` executes the real verifier against valid and deliberately malformed ATS dictionaries. `test_verify_release_version.sh:65` executes the version guard against valid, missing, malformed, and dev/sentinel metadata. Their non-test caller is `sign_notarize.sh:161,241`. Ordinary CI currently invokes neither fixture script. Its unsigned/sentinel bundle smoke is not equivalent negative-policy coverage.

Both fixtures passed locally in about 2.89 and 1.10 seconds respectively while run concurrently; these are host observations, not CI forecasts. The privacy fixture uses fake `codesign` output, so it proves verifier policy handling, not real signing or networking enforcement.

**Historical fault replay performed:** the current valid ATS control and extra-domain negative case were run in a temporary tree against the verifier immediately before `c9f7376a5`. The valid control passed; the extra-domain assertion failed because the old verifier accepted it. Current fixtures passed against the current verifier. This demonstrates the intended regression. An initial full historical replay stopped on a different explicit-false policy change; the narrowed replay removed that confounder rather than treating any failure as success.

Keep these tests and add them to a distribution-fixture follow-up. The expected dictionary is an independent release/privacy policy, not an incidental source snapshot. The version guard's history is `55ffeb3d4`; the privacy allowlist fix is `c9f7376a5`. No production or test deletion is appropriate.

### Voiceprint source scanner is fragile, but has no equivalent replacement yet

`SpeakerVoiceprintTelemetryTests.swift` scans identity-related files, checks filename sentinels, forbids direct telemetry calls, and inspects the settings preference call. It is coupled to names and call spelling, can be upset by harmless refactors, and does not prove absence of all possible data disclosure.

Its history matters: `16816670e` replaced a fixed file list that failed open and a prefix parser that could miss later call arguments. Consent tests in `SettingsViewModelTests.swift:3610` prove real settings/defaults behavior but do not assert the emitted preference event's exact properties. Deleting the scanner now would remove existing privacy protection without demonstrated replacement.

Retain it pending a behavioral preference-event test through the existing production `Telemetry.configure` interface and real settings view model. No new production test hook is needed. Only after replacement could the bespoke call parser and its own test be removed. Separately assess whether the broad source-level architectural guard remains useful. Do not describe this scan as comprehensive privacy proof.

### Fake collaborators can still expose real bugs

- `MeetingEchoSuppressorTests` uses a fake processor to exercise real buffering, alignment, flush, and fallback. The fake does not supply those outcomes. Keep it.
- `MeetingCleanedMicRendererTests` exercises production rendering and decodes a real output file. Keep its duration/alignment/finalization invariants, while labeling the processor substitution.
- `MeetingAudioStorageWriterTests.swift:97` writes and decodes durable stereo media across a long timeline gap. Fixture length alone is not a deletion reason.
- `MerkabaPillIconViewTests` holds distinct Core Animation reentry states described by regression commit `ec531795e`. A screenshot would not reliably replace those deterministic lifecycle checks.
- `BrandGlyphImageTests` loads actual packaged PDFs and checks platform rendering properties. This is resource wiring, not a copied inventory.
- The new CLI process smoke and its three driver tests have distinct jobs: product persistence across processes versus deliberately forced invalid JSON, wrong exit, and timeout handling. Keep both.
- Internal split-export hooks and dictation cancellation/replacement gates make real mid-write, source-mutation, and stale-session races deterministic. Their non-test callers leave the hooks unset, but that does not make them disposable. `MeetingSplitAudioExporterTests.swift:507–660` and `DictationServiceTests.swift:219–459` exercise production paths under held ordering; commits `ce3c7ad52`, `b07815b17`, and `7b3b64af2` record the regressions. Do not replace these with sleeps or generic GUI tests. STT vocabulary and microphone/HAL test adapters also lack demonstrated equivalent replacements.

## Integration roadmap after the CI change

The earlier [CI cost/test strategy report](2026-09-25-ci-cost-and-test-strategy.md#4-integration-and-end-to-end-opportunities) describes the detailed journeys. This audit sharpens their test ownership:

| Boundary | Primary proof to add or strengthen | Keep elsewhere |
|---|---|---|
| Dictation coordinator → delivery | Cancel with STT completion held; release stale result; assert connected clipboard untouched | Service cleanup/session ordering and database no-save checks |
| CLI → persistence → export | Seed a synthetic meeting through real migrations with an owned artifact folder, use separate CLI processes to read/update notes/export, compare durable content and materialized artifacts | Parser/error-envelope and repository edge cases |
| Native Library → durable save | Edit, save, relaunch, export through the real Dev app with owned state and stable Accessibility identifiers | Deterministic view-model save/navigation races |
| Capture writer → recovery after process exit | Reuse child-process interruption fixture, recover once in a fresh process, inspect playable artifacts and idempotency | Low-level writer/manifest invariants and recovery repository cases |
| Real model/audio route → user output | Provisioned Apple Silicon qualification with pinned assets and explicit permission/device state | Default deterministic CI with controlled collaborators |

These boundaries justify integration tests because they catch wiring and lifecycle failures. They do not make every unit test inferior. Precise cancellation, timeout, malformed-data, and signal-handler conditions are often stronger and cheaper to force below a GUI. Use UI/model tests for the risks only those environments expose.

Two implementation constraints emerged from the deeper document review. First, `--database` does not isolate paths stored inside a meeting row. `meetings notes set` refreshes artifacts best-effort using those paths; seed every artifact/audio locator under the owned temporary root and assert materialized notes/manifest destinations and contents. A passing JSON response alone can conceal a failed artifact refresh. Second, the existing SIGKILL writer fixture proves retained raw audio playability but creates no complete recovery lock/database/artifact session. Cross-process recovery needs that production-format state before interruption, then fresh-process recovery and idempotency assertions; it cannot be obtained merely by renaming the existing writer test.

## Verification and next implementation boundary

This audit ran the two release-policy fixture scripts and the isolated historical ATS replay. It did not run a local full Swift suite, new native UI/model checks, or Swift mutation tests. Hosted CI provides unchanged-suite execution evidence; it does not prove hypothetical deletion/replacement patches. Each proposed batch still needs its listed focused checks, an independent review, and one final full gate under repository policy.

Actual LOC changed by this audit: **zero production/tooling/test/support lines**; documentation only. Most deletion candidates unlock only test LOC, not production simplification. Keep the next code PR centered on one owner/contract rather than combining every small finding. The error-description consolidation is the smallest confidence-improving batch; cancellation delivery deserves its own focused boundary review. AEC routing should remain separate because its research purpose and measured runtime need different acceptance evidence.
