# MacParakeet independent app audit — 2026-10-02

MacParakeet has useful architectural foundations: shared Core logic, a broad
automation contract, source-separated meeting audio, transactional storage,
correction overlays and substantial deterministic tests. The best next work
is to protect user intent across asynchronous operations, make uncertain
speaker attribution explicit, and qualify complete native journeys. A broad
rewrite would add risk without addressing the demonstrated failures.

This audit includes four contained app fixes, a separate telemetry dashboard
fix, real-model execution, native view inspection, current CI measurements,
and aligned specifications. The [validation record](validation.md) separates
what passed from unexecuted hardware, production and release checks and
records the PRs. The [visual overview](overview.html) is a standalone offline
report with a before/after onboarding comparison.

The owner subsequently authorized landing the fixes and proceeding with the
recommendations. Current delivery and execution order are recorded in
[follow-through](follow-through.md).

## Read the reports

| Report | Main questions answered |
| --- | --- |
| [Speaker diarization](diarization.md) | Backend routing, final word attribution, fresh accuracy evidence, speaker counts, failures, corrections and identity limits |
| [GUI, UX and onboarding](gui-onboarding.md) | Permission/setup journey, recovery layout, Library races, keyboard access, engine lifetime and native evidence |
| [CLI, durable data and trust boundaries](cli-data.md) | Command coverage, JSON/errors, retranscription data loss, subprocess containment, persistence and recovery |
| [Telemetry and observability](telemetry-observability.md) | Consent/privacy, delivery, producer/receiver drift, metric interpretation, crashes, latency and activation |
| [Architecture, code quality, CI and performance](architecture-ci-performance.md) | Ownership boundaries, large-file seams, cancellation, measured build cost, coverage and latency priorities |
| [Prioritized follow-through](recommendations.md) | Five concrete projects with scope, acceptance criteria, effort, dependencies and stopping rules |
| [Validation and coverage](validation.md) | Reproduction commands, local/CI/runtime distinctions, independent reviews, exclusions and PRs |

## Highest-value findings

Priorities indicate consequence and ordering, not a claim that every item
blocks the stable release. Source line anchors in domain reports refer to the
baseline unless explicitly identified as the fix.

| Priority | Finding | Evidence | Disposition |
| --- | --- | --- | --- |
| P1 | CLI retranscription overwrote concurrent metadata or recreated a deleted recording | Real Core + SQLite red/green tests across file, URL, podcast and meeting paths | Fixed: return Core's committed row |
| P1 | Completed/cancelled dictation reruns recreated deleted History or overwrote changed status | Deletion/status interleavings and lifetime-statistics assertions | Fixed: atomic existence/status precondition; same-status metadata merging remains a limitation |
| P1 | GUI retranscription could overwrite a transcript correction saved after Core completed | Real Core/SQLite regression failed before removal of the redundant GUI save | Fixed: publish Core's committed result without a second save |
| P1 | Library queries restored stale favorite/deleted/audio state or skipped a row during pagination | Four of five gated tests failed on baseline; 71 Library tests passed for the initial repair; final review passes 80 Library cases and 264 combined GUI cases ([validation](validation.md#landing-review-follow-up)) | Fixed: invalidate older queries and retain the requested page window |
| P1 | Speaker quality is not qualified at the final word/identity boundary | Four acoustic runs plus real ASR/product integration; a correct word assignment erased by smoothing | Held-out final-word evaluation before changing policy |
| P1 | Speaker failures and actual backend/fallback lack a shared durable GUI/CLI outcome | Service/model/event tracing and ADR mismatch | Add typed outcome/provenance |
| P1 | Whisper setup lacks the background lifetime promised after Skip/Finish | Window cancellation reaches the view-model-owned download | Open conformance gap in ADR-005; qualify and fix with a controlled downloader |
| P1 | Green app CI can contain a skipped telemetry receiver compatibility check | Exact baseline CI log; local fresh receiver comparison passes | Require non-skipped release evidence and paired receiver deployment |
| P2 | Failed setup overlapped its heading and cropped recovery actions | Actual SwiftUI before/after renders at 760 × 600, including scrolling | Fixed: intrinsic error-card height |
| P2 | Onboarding chart omitted current steps and counted retries as visits | Real SQLite-backed receiver route regression | Fixed in [website PR #102](https://github.com/moona3k/macparakeet-website/pull/102); deployment remains separate |
| P2 | Meeting roster counts an unknown source bucket as another person | Real product output: Me + Others + two remote identities = four entries | Separate identities from source-only labels without erasing evidence |
| P2 | External helper output is time-bounded but not byte-bounded | Direct subprocess buffer inspection | Bounded draining and explicit oversized-output failure |
| P2 | CI wait is dominated by Release compilation and bundle building | Exact hosted run: 35m02s, two SwiftPM cache misses | Measure cache utility and optimize the critical path |

Other recommendations include keyboard-accessible transcript/chat controls,
Whisper stall recovery, source-aware acoustic timelines, synthetic library
restore drills and SQL-backed scalar/prefix queries. The CLI query probe did
not establish a material latency regression; source complexity alone is not
a measured speedup claim.

## Speaker diarization: what the fresh evidence says

The same public recordings, scoring policy and audio bytes were processed by
both current backends with network access denied.

| Fixture | Reference people | Nemotron DER / count | Community-1 DER / count |
| --- | ---: | --- | --- |
| `wibky`, 302.91s | 1 | 1.92% / 1 | 10.73% / 2 |
| `ouvtt`, 727.62s | 2 | 10.83% / 3 | 25.78% / 4 |

DER is diarization error rate; lower is better under this fixed protocol.
VoxConverse overlaps Nemotron's disclosed training data. These results support
regression comparison and do not establish held-out generalization or a reason
to change the current default again.

A separate real-ASR test passed meeting/file processing, a 500ms source offset,
DB reopen, artifact persistence and silence reset. On its fixed 180-second
crop, word smoothing reduced agreement from 487 to 486 of 491 eligible word
midpoints. Overlap and ASR errors were outside that diagnostic. The microphone
remains one source named Me; multi-person room diarization on that microphone
is outside the captured-meeting design. Imported files have a different scope.
These limits should be understandable in the product.

## Performance and delivery priorities

The observed stop-to-posted-paste phase sum has a **225ms median and 6,645ms
p99**, from 9,143 telemetry samples. It measures internal phases, not verified
insertion in another app. The tail merits investigation, but these aggregate
numbers do not identify a lock, model or provider as the cause.

Keep the Core/ViewModels/app/CLI structure. Concentrate refactoring on
ownership of completion, revisions, cancellation and publication. Extract one
testable workflow from the 6,814-line result view at a time. Preserve the speech
scheduler's actual execution ownership; its watchdog observes an unhealthy
call, it does not forcibly terminate one.

Next investment order:

1. Qualify final speaker-attributed words and expose failures/provenance.
2. Run clean-install → permissions → model → actual insertion, plus recovery
   and relaunch, in a disposable native account.
3. Close producer/receiver compatibility and deployed-ingestion evidence.
4. Measure tail latency and long-meeting memory on constrained hardware under
   an actual call workload.
5. Improve the measured CI critical path and split workflow ownership where
   it reduces maintenance risk.

## Documentation reconciled

| Governing document | Alignment |
| --- | --- |
| Architecture spec | Canonical completion ownership, query invalidation, app-state isolation limits |
| UI patterns | Mutation publication rules and intrinsic setup-failure layout |
| Testing spec and testing index | Current compiled caches/CI jobs, targeted SwiftUI coverage, real-model evidence and native qualification limits |
| ADR-005 | Records Whisper lifetime/watchdog as unfulfilled intended behavior, preserving the requirement |
| ADR-010 | Measured evidence, smoothing limits, missing warning/provenance, source buckets and acoustic-timeline distinction |
| CLI JSON contract and changelog | No stale post-completion save, deletion/status preconditions, unchanged output shape |
| Telemetry contract and receiver API docs | Current steps, distinct-session metric, legacy cached semantics and freshness interpretation |
| Diarization benchmark docs | Links new reruns and preserves historical measurements as historical |

Historical results are not rewritten as if rerun, and ADR requirements are
not weakened merely because implementation falls short.

## Baseline and limits

App baseline: `f43f4bed2ba7d4afdb005369759afc3d6cc44d34`, fetched from
`origin/main`; website baseline: `6a9f8ffd48338820b83677a6fbe8137558278e71`.
The stable release was v0.8.9 when verified. Main contains later changes;
this audit is not a retroactive claim about the shipped DMG. Original dirty
checkouts and unrelated PRs were preserved.

Local host: Apple Silicon Mac16,7, 48 GiB RAM, macOS 26.7.1, Xcode 26.4.1,
Swift 6.3.1. Hosted baseline CI used macOS 14 and Xcode 16.1.

This was a risk-weighted review of a 643-file, 227,336-line first-party Swift
codebase, not proof that every line is defect-free. No personal recordings,
transcripts, production database writes, permission resets, provider spending,
deployment, release or merge were performed. Signed upgrade, physical audio,
native TCC/focus, full VoiceOver, long low-memory calls, all migrations and
third-party binary internals remain separately qualified boundaries. Each
report identifies inspected versus executed areas.
