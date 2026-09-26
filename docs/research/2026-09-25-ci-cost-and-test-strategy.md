# CI cost and test strategy: evidence and recommendations

Research date: 25 September 2026, Pacific time. Source snapshot: [`59e7adf085277ea82ee9bb5f15a7b8cb315ebd91`](https://github.com/moona3k/macparakeet/tree/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91). This is an investigation and proposed sequence, not an implemented optimization. No workflows, tests, product code, or user data were changed; no local builds, full-suite runs, or physical-device tests were performed.

## What the evidence says

**Fix build orchestration before deleting tests.** In 24 recent successful CI jobs, the median job took **52.7 minutes**. Four build stages *before* `Swift Test` consumed **77.5% of aggregate job time**. In three inspected successful logs, actual XCTest execution occupied approximately **7.2–8.3 minutes**. There are lower-value tests worth replacing, but deleting them cannot explain away most of the wait.

**Add more tests across real boundaries, especially executable → database → export and app UI → durable state.** End-to-end tests are better at finding composition failures; small deterministic tests are better at forcing cancellation races, error branches, and audio boundary conditions. MacParakeet needs both. Its [testing spec already favors integration](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/spec/09-testing.md#philosophy), but several existing “end-to-end” tests replace the audio/STT boundary, and hosted CI does not launch the native app.

The highest recommendations, in order:

1. Repair missing diagnostic artifacts and collect per-case timings, build timings, and skip counts.
2. Get tests out from behind the Release packaging work; retain both kinds of validation.
3. Combine the warning build with the test build, keeping flags consistent; narrow redundant Release products after measurement.
4. Measure XCTest process-launch overhead before changing thousands of tests or adding shards.
5. Replace weak assertions and test-only DSP sweeps selectively, preserving meaningful production and data-integrity checks.
6. Strengthen the existing real CLI smoke, add one native library persistence journey, and compose existing meeting crash/recovery coverage across processes.

## 1. Where the time goes

### Sample and method

The GitHub API sample contains the latest **70 CI runs** at collection, created between **2026-09-24 20:40:25Z and 2026-09-26 00:37:50Z**: 24 successful, 5 failed, 39 cancelled, and 2 still running. Successful runs supply the timing baseline; failed/cancelled/in-progress runs are not averaged into successful runtime. These are recent, busy-day observations, not a month-long controlled benchmark.

Job duration is `job.completed_at - job.started_at`; step duration uses the corresponding step timestamps. “Before job start” is `job.started_at - run.created_at`, which can include scheduling, approval, or other pre-execution delay. It is not proof of a particular queue cause. Workflow completion/update timestamps can include post-job bookkeeping. Workflow variants on PRs are included in the census; conclusions about the current workflow are checked against the pinned source above.

| Successful-job stage | Median | Observed range | What it buys |
|---|---:|---:|---|
| SwiftPM Release build | 13.8 min | 10.2–19.0 | Optimized compilation of the default products |
| Xcode Release bundle smoke | 16.2 min | 10.6–20.2 | Shipping app build path, assembly, compiled Markdown resource checks |
| Concurrency warning build | 5.8 min | 4.2–7.9 | Normal dependency graph with concurrency diagnostics |
| Separate Swift 6 build | 5.0 min | 3.8–6.7 | Compatibility compilation with some dependencies/features omitted |
| `Swift Test` | 10.2 min | 8.6–13.3 | Test compilation/linking **and** execution |
| Dependency cache restore | 0.6 min | 0.3–0.8 | Source/download reuse, not compiled-product reuse |
| Informational formatting | 0.3 min | 0.2–0.3 | Advisory formatting output |
| Echo packaging fixtures | 0.2 min | 0.1–0.3 | Shell-level packaging contracts |
| Entire job | **52.7 min** | **39.6–64.2** | All gates, sequentially |

Medians are computed independently and must not be added as though they describe one run. The four pre-test build stages totaled **976.0 of 1,258.5 successful runner-minutes**, yielding the 77.5% share. The [current workflow](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/.github/workflows/ci.yml#L91-L176) puts all these stages into one job.

### Compilation versus running test cases

| Successful run | Whole job | Whole test step | Command to “Build complete” | XCTest progress span | XCTest selections |
|---|---:|---:|---:|---:|---:|
| [36192120824, main](https://github.com/moona3k/macparakeet/actions/runs/36192120824) | 39.6 min | 8.9 min | 101.5 sec | 432.8 sec | 7,561 |
| [36188404222, PR](https://github.com/moona3k/macparakeet/actions/runs/36188404222) | 52.7 min | 10.0 min | 122.0 sec | 473.2 sec | 7,550 |
| [36181790480, PR](https://github.com/moona3k/macparakeet/actions/runs/36181790480) | 64.2 min | 11.2 min | 168.9 sec | 498.6 sec | 7,528 |

The first run's Swift compiler reports an 88.31-second build; 101.5 seconds also includes command planning/setup. The execution figures are the first-to-last XCTest progress timestamps, an approximation of execution wall time rather than summed test-body time. [SwiftPM emits these progress entries on completion](https://github.com/swiftlang/swift-package-manager/blob/release/6.0/Sources/Commands/SwiftTestCommand.swift#L1146-L1162), and workers overlap: **the gap between adjacent entries is not the duration of the named test**. The first run also reports 30 Swift Testing tests in 0.005 seconds. Selection counts include cases that may skip and are not equivalent to hardware/model tests passing.

### Waiting and abandoned work

Successful workflows had a median creation-to-update elapsed time of 53.8 minutes, but the range reached 106.8 minutes. The median before-job-start interval was 0.4 minutes; the maximum was **63.7 minutes**. Thus some exceptionally long waits include substantial time outside executing the job. [Run 36174905766](https://github.com/moona3k/macparakeet/actions/runs/36174905766) illustrates this: approximately 43.0 job minutes plus 63.7 minutes before it began.

The 39 cancelled runs consumed approximately **536.4 job-minutes**, or **8.9 runner-hours**, during this sample. Thirty-four reached runner setup; five did not. Eleven cancelled main pushes account for about 163.7 of those minutes. These are timestamp-based resource estimates, not billed charges. Cancellation is already enabled and saves the remainder of superseded jobs. Removing it would make this worse. Faster feedback and fewer intermediate pushes are more useful than a long artificial debounce.

Feature-branch push/PR duplication was **already fixed**: automatic branch pushes run only for `main`; PRs validate their merge refs. Main validation still checks the integrated commit and should not be discarded as an identical rerun. The [September 8 historical baseline](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/spec/09-testing.md#timing-baseline-and-optimization-priorities) already recorded this distinction.

### What failed, and when feedback arrived

| Failed run | Job time | Observed failure |
|---|---:|---|
| [36197082945](https://github.com/moona3k/macparakeet/actions/runs/36197082945) | 48.2 min | Ask Pi Helper packaging could not open `Sources/AskAgentHelper/dist/Legal/dependencies.json`; Swift tests did not run. This is a PR-specific step absent from the audited snapshot. |
| [36177180327](https://github.com/moona3k/macparakeet/actions/runs/36177180327) | 53.1 min | `TranscriptDocumentLayoutTests.testLongMarkdownAndWideBlocksStayInsideCompactAndRegularPanes`: measured width 900, expected at most 886. |
| [36105383544](https://github.com/moona3k/macparakeet/actions/runs/36105383544) | 3.8 min | Dependency update failed cloning GRDB's SQLiteLib submodule. |
| [36090788455](https://github.com/moona3k/macparakeet/actions/runs/36090788455) | 40.3 min | `DictationServiceTests.testStopRecordingFallsBackToRecordedFileWhenLiveNemotronFails`: expected 1, observed 0. |
| [36090668970](https://github.com/moona3k/macparakeet/actions/runs/36090668970) | 48.7 min | The same dictation fallback assertion failed. |

These are failure signatures, not independently reproduced root causes or a measured flake rate. They show why earlier behavior feedback matters: UI and dictation assertions currently surface after lengthy unrelated builds. Keep the first failure evidence when rerunning; do not turn “passes on retry” into a substitute for investigating nondeterminism. There is already a useful repository precedent: [a capture test was fixed by waiting for the mock callback to be installed](https://github.com/moona3k/macparakeet/commit/47cfacae619b0ea99dd1a0ef0fb33bd18e67f46f), with a deliberate delayed-start reproduction, rather than raising the timeout.

### Runner and cache facts

Inspected logs identify **`macos-14-arm64` and Apple Swift 6.0.2**, not Intel. GitHub currently documents the standard arm64 macOS runner as 3 M1 CPUs and 7 GB RAM; adding more workers or multiple compilers within that VM is not automatically faster. [GitHub runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

The [cache paths](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/.github/workflows/ci.yml#L80-L89) are `.build/checkouts`, `.build/repositories`, and the shared SwiftPM cache. They exclude normal build products, `.build-swift6-no-whisper`, and Xcode DerivedData. A successful cache restore therefore does not remove the repeated compilation.

Live cache inventory returned five archives, about **10.18 GB decimal / 9.48 GiB total**, with four around 2.05 GB for the same dependency key across main/PR scopes and one older main entry. This is a reason to budget cache size, not evidence that eviction is occurring. The configured storage cap was not inspected. GitHub caches are immutable and PR caches have restricted ref scope; adding a huge `.build` archive without a key/invalidation/storage design can just add transfer and eviction costs. [GitHub cache reference](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching).

## 2. Build and workflow recommendations

### P0: make CI evidence survive

**The inspected runs did not upload their intended log artifacts.** Their logs say `No files were found with the provided path: .ci-logs/. No artifacts will be uploaded.` The workflow uploads a hidden directory without `include-hidden-files: true`, and explicitly ignores missing files. Hidden directories are excluded by default by `upload-artifact`. This is a concrete defect, independently confirmed in successful and failed logs. [Workflow upload configuration](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/.github/workflows/ci.yml#L178-L185), [action documentation](https://github.com/actions/upload-artifact#uploading-hidden-files).

Use a dedicated nonhidden output directory, or explicitly include hidden files only under the intended log directory. Add a visible diagnostic when a step that produced logs uploads nothing. Record:

- Source SHA, runner architecture/core count, Xcode/Swift versions, build flags and feature modes.
- Build versus test execution duration, cache hit/miss and transfer size, and slowest tests/classes.
- Selected, passed, failed, and skipped cases, with skip reasons for model/hardware coverage.
- Machine-readable XCTest results using the toolchain's `--xunit-output` support; verify the format includes the expected skipped/result details before treating it as complete. Keep a separate Swift Testing summary.

Use Xcode build timing summaries/retained logs when investigating compilation; the bundle script currently redirects normal `xcodebuild` output to `/dev/null`. No full recompilation is necessary merely to fix the artifact path. Prove the change with one hosted run that actually exposes a downloadable artifact. **This improves diagnosis, not CI runtime by itself.**

### P1: run behavioral validation before or alongside packaging

The current arrangement defers every test failure until four builds finish. Start with two substantive jobs, plus the existing cheap checks:

| Lane | Contents | Intended result |
|---|---|---|
| Behavior and compatibility | One consistent debug/test build, full deterministic suite, real CLI subprocess smoke; Swift 6 compatibility after behavioral results or as a separately visible step | Earlier product regression feedback |
| Distribution | Narrow Release CLI build, Xcode Release app bundle, packaged resource checks, packaged CLI contract smoke | Preserve the shipping build path and artifact wiring |

Keep an aggregate completion verdict that requires all applicable gates to succeed. Explicitly validate failed, cancelled, and deliberately skipped dependency jobs; a green aggregator must not conceal a failed child. Preserve PR merge-ref and integrated-main validation. Do not add broad path filters that silently skip shared dependency/configuration changes.

A simple replay of the 24 successful runs—taking the maximum of `(Release + bundle)` and `(concurrency + Swift 6 + tests)`—gives a median **30.3 minutes**, versus the observed 52.7. This is an **optimistic scheduling model**, not a benchmark or promise. It omits extra runner queueing, duplicated setup/dependency resolution, cache contention, and changes to build reuse. Measure both wall time and total runner-minutes before rollout. Given the observed pre-start delays, ten shards or a large matrix would be premature.

### P1: reduce duplicate compilation without losing coverage

The separate warning build uses `-warn-concurrency`; `swift test` then uses different flags against the same `.build` directory. Prefer applying the same intended diagnostics during test compilation, rather than paying for a standalone debug build and then another build configuration. **Do not promise the whole 5.8-minute warning stage as savings**: a cold test build still needs the shared code compiled. The eliminated work is the redundant/incompatible compilation, and must be measured.

The normal Release build builds the default product set, including the app and `diarization-benchmark`; the bundle step then compiles the app through Xcode. Try narrowing the first build to `--product macparakeet-cli`, while preserving compilation of the benchmark in an appropriate check. Core and dependency compilation remain substantial, so the savings are unknown. The [bundle script already builds/copies the CLI separately](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/scripts/dist/build_app_bundle.sh#L87-L99) and [requires Xcode for the app](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/scripts/dist/build_app_bundle.sh#L130-L228).

**Keep the Xcode bundle check.** Its history documents actual missing compiled assets/nonportable resource accessors; the Markdown color/icon probe protects defects that a SwiftPM source build misses. This is expensive validation with a concrete purpose. [Resource regression check](https://github.com/moona3k/macparakeet/commit/cf9103d36ff3340000c753173ca17e5161402dda), [shipping build-path rationale](https://github.com/moona3k/macparakeet/commit/d16dab8a5c9463e0ca1d80d0a58c5b36a540c4ee).

### P1: make “Concurrency Safety” an honest gate

The warning stage succeeds despite warnings. In run 36192120824 it emitted 629 warning lines, representing 25 distinct textual warnings, including first-party Markdown code and dependencies. Calling that an enforced safety check overstates the evidence.

Retain useful diagnostics but define what fails the check: for example, a ratchet on new first-party concurrency diagnostics rather than globally treating every third-party warning as fatal. Keep the Swift 6 compatibility build for now: it has error semantics but [omits WhisperKit and the Markdown graph](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/Package.swift#L6-L10), including conditional first-party paths. It also runs `swift build`, so **it does not compile the test targets in Swift 6 mode**. The test build has its own concurrency warnings. A future first-party target-level language-mode migration could remove duplication more cleanly, but would require separate dependency/manifest work and is not a quick CI edit. [Swift's language-mode and checking guidance](https://github.com/swiftlang/swift-migration-guide/blob/main/Guide.docc/EnableDataRaceSafety.md).

### P2: compiled caches only after a controlled trial

Evaluate source-cache reuse for Xcode and the alternate Swift 6 path first; then trial a bounded compiled cache for the largest remaining lane. Key it by architecture, toolchain/SDK, dependency lockfile/manifest, configuration, relevant flags and feature modes, with a versioned cache schema and a deliberate save/restore policy. Preserve normal build dependency checks after restore; a cache hit is not permission to skip compilation validation.

Test warm same-head, changed-source, changed-dependency, and cold-cache runs. Record restore/save time and size. Do not combine incompatible SwiftPM/Xcode build databases, and do not cache signing credentials or model/user state. Keep a cold correctness check available. Avoid presenting cache correctness or a speedup as established before these trials.

## 3. Test cost, value, and “theater”

### First measure the runner overhead

The snapshot has 440 Swift test-source files, and hosted logs select roughly 7,500 XCTest cases. The [SwiftPM release/6.0 runner](https://github.com/swiftlang/swift-package-manager/blob/release/6.0/Sources/Commands/SwiftTestCommand.swift#L1094-L1162) queues individual cases and runs each using a `TestRunner` that launches a new subprocess. This makes thousands of process launches, dynamic loads, initializations and teardowns a plausible cost. The source is the corresponding release family, not a verified exact commit of Apple's installed binary.

There is not yet evidence that process overhead dominates those 7–8 minutes. First collect xUnit timings, then compare a representative same-build subset with fixed worker counts and serial execution; trace a small sample to confirm process behavior. If justified, do one deliberate full-suite comparison as a separately scoped performance experiment. Use `--skip-build` for execution comparisons and identical binaries/fixtures; track failures, not only speed. More workers can increase memory pressure; serial execution can expose shared-state contamination or simply be slower. Prefer selective migration of suitable pure tests to Swift Testing over a wholesale framework rewrite if the measurements support it.

### Concrete candidates and what to preserve

| Candidate | Assessment | Recommended replacement or disposition |
|---|---|---|
| [AEC measurement sweeps](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/Tests/MacParakeetTests/Services/Capture/MeetingAecMeasurementTests.swift#L69-L230) | Eleven delay offsets and a three-SIR sweep largely characterize test-local oracle/NLMS DSP, not the shipping model. The SIR sweep prints near-end results without asserting them. | Keep a compact fixture/metric sanity case; move exploratory sweeps to explicitly invoked characterization. Retain production streaming alignment/flush/fallback tests and real-model qualification. |
| [Estimator speed ceiling](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/Tests/MacParakeetTests/Services/Capture/MeetingEchoDelayEstimatorTests.swift#L90-L145) | Repeated representative DSP work plus a shared-runner wall-clock threshold mixes correctness and performance. | Keep lag correctness/scalar equivalence. Measure whether the runtime ceiling belongs in a controlled performance lane, with a meaningful regression baseline. |
| [Scheduler fixed waits](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/Tests/MacParakeetTests/STT/STTSchedulerTests.swift#L80-L170) and [caption timing](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/Tests/MacParakeetTests/DictationFlow/DictationFlowCoordinatorLoadCaptionTests.swift#L18-L75) | Valuable behavior tested using scheduler-dependent waits; caption coverage includes 620 ms against a 700 ms boundary. | Synchronize on entered/queued/completed events; inject a clock for time-window semantics where warranted. Retain one real timer integration check. Never replace a negative timing assertion with a wait that cannot prove the prohibited action stayed absent. |
| [Real SwiftUI settling tests](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/Tests/MacParakeetTests/Views/TranscriptTimestampedLayoutSmokeTests.swift#L183-L358) | Run-loop pumping, scrolling, and settling deadlines are costly-looking but catch an actual view update-loop failure. | Keep representative live-view checks and the hang watchdog. Move only measured expensive scale variants if equivalent regression coverage remains. |
| [VAD simulator](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/Tests/MacParakeetTests/Audio/MeetingVADChunkingSimulatorTests.swift#L13-L49) | A 23-second synthetic signal is replayed twice; `processingSeconds > 0` and `realtimeFactor > 0` provide little behavioral signal. | Preserve chunk equality/coverage. Shorten the signal only if it still crosses all intended boundaries; replace weak timing assertions with finite/consistent report checks. Twenty-three seconds of sample data does not imply a 23-second test. |
| [Error descriptions](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/Tests/MacParakeetTests/Audio/AudioFileConverterTests.swift#L194-L202) | Non-nil messages detect absence but not incorrect/swapped copy. | Improve a few contract assertions when touching this area. These are cheap and not a credible major runtime target. |

These are source-based value assessments, **not a measured ranking of slowest cases**. A static search found 449 sleep references in 81 files; that is neither 449 executed sleeps nor a duration estimate. Do not add sleep constants together to claim saved CI minutes.

The AEC distinction matters. Its [measurement harness](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/Tests/MacParakeetTests/Services/Capture/MeetingAecMeasurementHarness.swift#L487-L575) defines test-only NLMS/oracle processors. The default measurements do exercise the production streaming wrapper and passthrough, but do not call the shipping LocalVQE loader, factory, cleaned-mic renderer or adaptive delay estimator. A shipping model/renderer defect can therefore leave them green. Preserve wrapper contracts; use a deterministic processor for factory/renderer integration; reserve actual model/speech quality claims for the real asset-backed lane.

**Do not remove these to improve the test count:** database migrations/recovery, capture session ownership, cancellation/restart ordering, source audio preservation, clipping/alignment invariants, public CLI envelopes, privacy boundaries, and packaging resources. These have consequences beyond a cosmetic regression. [MeetingAudioStorageWriterTests](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/Tests/MacParakeetTests/Audio/MeetingAudioStorageWriterTests.swift#L97-L150), for example, materialize a long timeline gap and decode retained stereo media. That is useful real integration, even if its fixture can eventually be optimized.

For each removal or consolidation, write down a specific production fault the replacement should catch, introduce that fault locally in a disposable experiment where practical, and verify detection. Cheap, clear policy tests are not theater simply because they assert a constant. A long test is not valuable simply because it performs DSP.

## 4. Integration and end-to-end opportunities

### Current coverage is stronger than the directory names imply, but has limits

- [TranscriptionFlowTests](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/Tests/MacParakeetTests/Integration/TranscriptionFlowTests.swift#L12-L75) compose real service/repository/export logic, but fake conversion and STT and accept a nonexistent `/tmp/interview.mp3`. [DictationFlowTests](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/Tests/MacParakeetTests/Integration/DictationFlowTests.swift#L11-L59) similarly fake capture/STT. These are useful service integration, not physical speech-to-paste proof.
- CLI tests include real command execution and database behavior **in process**, not just argument parsing. For example, [PromptsCommandTests](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/Tests/CLITests/PromptsCommandTests.swift#L145-L258) call command objects. Add subprocess coverage for the boundaries that in-process calls cannot prove, rather than duplicating every CLI permutation.
- [`release_demo_smoke.sh`](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/scripts/dev/release_demo_smoke.sh#L241-L280) already executes a real CLI, synthesizes speech with `say`, converts WAV, performs real STT, saves to a selected SQLite database, and exports Markdown. Its pass criteria are currently completed status, nonempty transcript, and export-file existence.
- Opt-in suites already cover [native AX/OCR Voice Control](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/Tests/MacParakeetTests/VoiceControl/NativeVoiceControlE2ETests.swift#L7-L37), [Nemotron/Parakeet on recorded dual-source audio](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/Tests/MacParakeetTests/Services/Diarization/NemotronDiarizationE2ETests.swift#L8-L60), [real microphone behavior](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/Tests/MacParakeetTests/Audio/MicrophoneEngineRealPlatformTests.swift#L56), real LocalVQE, and long-meeting benchmarks. Their existence does not mean normal CI runs them.
- The bundle smoke inspects resources; it does not launch the application. It substitutes `/usr/bin/true` for FFmpeg and omits bundled Node/yt-dlp, so it cannot establish release media-helper functionality either.

### The next few journeys

| Priority and lane | Journey | Real components and deliberate substitutions | Assertions that matter |
|---|---|---|---|
| P1, ordinary CI after building CLI | One subprocess persistence/JSON round trip against a test-owned database | Real built CLI, argument parser, process exit/stdout/stderr, SQLite and export; seed synthetic text rather than invoking STT | Separate invocations agree on IDs/content, JSON stays parseable, errors have correct exit semantics, export contains the saved content |
| P1, provisioned Apple Silicon qualification | Strengthen the existing `release_demo_smoke.sh` | Real bundled CLI, audio conversion, model/ANE, SQLite, exporter; generated/owned WAV replaces the microphone | Read back the saved row in another invocation; compare ID/status/text; assert expected normalized words and transcript inclusion in exported Markdown, not just nonempty output |
| P1, dedicated logged-in Mac | One native Library read/edit/save/relaunch/export journey | Actual Dev app, SwiftUI/AppKit, local persistence/export; start from a synthetic seeded item so no model is necessary | Visible text changes, save completes, reopening/relaunch preserves the change, export matches |
| P2, macOS integration lane | Writer interruption → fresh process → recover → materialize artifacts | Real AVFoundation media writer, filesystem, GRDB, recovery and artifact generation; stub STT for this persistence test | Exactly one recovered record, playable retained audio, stable locator, correct lock settlement, manifest/Markdown consistency, repeat recovery is idempotent |
| Release/relevant regression | Physical dictation and dual-source meeting checks | Signed app, actual mic/system route, TCC, hotkeys, local model, destination app and saved audio | Dictation pastes once; cancel/restart cannot paste stale text; both meeting sources remain attributable/playable after stop/relaunch; Bluetooth and missing/late-source behavior are exercised |

The native UI journey should begin with stable Accessibility identifiers on the few necessary controls, observable save/completion states, and bounded condition waits. Extend it later to actual file import with STT once the simpler persistence journey is reliable. Keep pending-save/navigation races in deterministic view-model coverage; a later targeted UI version needs two items and a controllable delayed-save seam. Do not begin with broad screenshot snapshots or a generic automation framework.

For the cheap CLI journey, create one completed synthetic meeting through a narrow Core test seeder, then execute separate binaries with `meetings show <id> --json --database <db>`, `meetings notes set <id> --text <text> --json --database <db>`, `meetings notes get <id> --json --database <db>`, and `meetings export <id> --format md --stdout --database <db>`. Assert the export contains both seeded transcript and updated notes; also check the documented missing-ID error and exit behavior. These are [existing command surfaces](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/Sources/CLI/Commands/MeetingsCommand.swift#L673-L753), and [existing tests demonstrate the Core seeding pattern](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/Tests/CLITests/MeetingsCommandTests.swift#L19-L47). Generate the database with current migrations instead of committing a binary SQLite fixture. Use the hosted runner's disposable account, or verified local isolation; database startup can also create AppPaths directories.

For recovery, reuse the [existing child-process kill-9 writer fixture](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/Tests/MacParakeetTests/Services/MeetingRecording/MeetingRecordingCrashRecoveryTests.swift#L9-L46) and service tests. The added value is composing the separate guarantees through restart and durable artifacts, according to the [recovery contract](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/spec/contracts/meeting-recovery-retention.md) and [artifact contract](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/spec/contracts/meeting-artifacts-v1.md). Initially run it explicitly; promote it to routine CI only after its duration and determinism are established.

### Native automation feasibility and isolation

Apple distinguishes direct-call tests from UI automation: XCTest/XCUIAutomation remains the UI surface, and `XCUIApplication` supports launch arguments/environment. This repository has SwiftPM test targets but no checked-in Xcode UI-test target/test plan. Prototype a minimal UI runner/host before promising unattended hosted XCUITest. A small Accessibility smoke against the existing Dev app is an alternative; follow the repository's native automation rules. [Apple XCTest](https://developer.apple.com/documentation/xctest/), [XCUIApplication](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication).

Use `scripts/dev/run_app.sh` for testable Dev builds. Preserve its macro-validation setting, signing, and owned-process shutdown. **`--database` is not full state isolation.** There is an important documentation mismatch: the integration guide describes `MACPARAKEET_DEBUG_APP_STATE_DIR` as DEBUG-only, but [current AppPaths source](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/Sources/MacParakeetCore/Services/AppPaths.swift#L294-L313) accepts an explicit absolute override without a DEBUG guard, and the Dev launcher documents support for optimized Release. Verify the intended executable in a disposable account before relying on isolation; neither database selection nor this path override isolates shared UserDefaults/Keychain. Use a disposable macOS account for packaged Release/model qualification and avoid preference mutations in lightweight CLI tests. Preprovision pinned local models, then fail or explicitly skip if prerequisites are missing: the existing smoke script has no general no-download switch. `MACPARAKEET_TELEMETRY=0` disables telemetry, not all networking. [Repository isolation guidance](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/integrations/README.md#safe-automation-and-isolation).

Permissions and physical routes remain separate evidence. A prerecorded “microphone” file does not test the microphone; an AX fixture does not test speech recognition; a green app launch does not prove Bluetooth or acoustic echo performance. Keep model downloads and interactive permission prompts out of ordinary PR tests. Record build, OS, device/route, permission state and real-versus-stubbed boundaries for qualification results. [Apple capture authorization](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media).

## 5. Implementation order and acceptance criteria

| Step | Narrow deliverable | Evidence needed before claiming success |
|---|---|---|
| 1 | Repair artifacts; add timing/result summaries and capture build diagnostics | One hosted run with retrievable logs, discovered/result/skip counts, and separate compilation/execution times |
| 2 | Consistent test-build flags and earlier behavior lane; retain distribution/Swift 6 checks | Same required checks and test inventory; representative before/after cold/warm runs; earlier failure feedback; total runner cost reported |
| 3 | Trial Release product narrowing and bounded cache reuse | No missing app/CLI/benchmark/resource coverage; source and lockfile invalidation behave correctly; net measured savings after transfers |
| 4 | Measure XCTest workers/process overhead; fix top measured timer/fixture costs | Same assertions and fault detection, fewer flaky outcomes, measured execution improvement; no blanket coverage cuts |
| 5 | Add cheap CLI subprocess round trip and strengthen existing model smoke | Intentionally corrupted persistence/export or wrong executable routing makes the relevant test fail |
| 6 | Add one native persistence flow and composed recovery flow | Repeated reliable runs on owned state; failure screenshots/logs; replay of the motivating regression; explicit remaining physical gates |

Do not implement all lanes, caches, framework migration, and test deletion in one PR: that would make speed and failure-detection changes impossible to attribute. The scheduling estimate suggests that **roughly half an hour for the full gate is a reasonable first experiment**, not an established target. A sub-ten-minute complete cold Release/build/UI/model pipeline is unsupported by these measurements.

The local workflow also deserves alignment. [`ci_local.sh`](https://github.com/moona3k/macparakeet/blob/59e7adf085277ea82ee9bb5f15a7b8cb315ebd91/scripts/dev/ci_local.sh) performs a clean Release build plus tests, while `.no-mistakes.yaml` runs `swift test` without hosted parallel mode. Avoid invoking both as repeated full-suite rituals. Follow focused iteration and one final full gate, and identify whether a claim refers to local serial execution or hosted parallel execution.

Update testing guidance alongside an implementation: the spec's `Tests/Fixtures/` directory is absent at this snapshot; its final “Adding a New Test” section still tells agents to run the full suite and update counts, despite the newer focused-iteration rule earlier in the same document. The stated 4,300+ count in AGENTS is also stale as a description of scale. Replace count-maintenance instructions with generated inventory/result summaries and describe the actual integration/qualification lanes.

## Evidence limits

The timing census can be reconstructed from the repository's `actions/workflows/ci.yml/runs` API using the fixed creation interval above and each run's `actions/runs/<id>/jobs` response. The 24 successful run IDs were: `36192120824`, `36188404222`, `36186303546`, `36184099050`, `36183264834`, `36181790480`, `36181202496`, `36175041131`, `36174905766`, `36172100401`, `36146242169`, `36106797099`, `36105416812`, `36100530486`, `36100038681`, `36098687736`, `36097115247`, `36095211296`, `36090793066`, `36085369320`, `36083464521`, `36083462222`, `36083435245`, and `36056451102`. Read logs with `gh run view <id> --repo moona3k/macparakeet --log`. Later reruns or completion of the two in-progress jobs must not silently change the original cohort. Temporary API/log working files are under `/tmp/macparakeet-ci-timing/`; the report retains the relevant evidence without adding a raw-log archive to the repository.

No per-case timing artifact was available from these runs, so there is no defensible claim that AEC, SQLite, sleeps, or subprocess startup individually dominate test runtime. No cache, scheduling, worker-count, or product-selection optimization was benchmarked. No mutation tests or physical/UI flows were executed during this research. Test-value conclusions come from source inspection and existing regression history; savings estimates are explicitly labeled.

The investigation used three delegated GPT-6 Sol research passes for CI data extraction, source/test-value inspection, and integration feasibility, with primary-agent synthesis and cross-checks. No Jev steps were used: the work was deterministic data extraction plus open-ended technical reasoning, not a new semantic routing/classification implementation. Existing unrelated checkout edits were preserved.
