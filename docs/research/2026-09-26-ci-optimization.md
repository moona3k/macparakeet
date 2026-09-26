# CI build reuse and integration-test follow-up

This round retains the full SwiftPM Release build, Xcode bundle/resource probe,
all ordinary tests, concurrency diagnostics, Swift 6 compatibility build, real
CLI persistence, and process-recovery checks. No product behavior changes.

## Baseline and measurement

The successful [combined-main run](https://github.com/moona3k/macparakeet/actions/runs/36247644540)
at `529e23ad` took 27m05s from workflow creation to the final required job,
with 47m58s of occupied macOS jobs. Test compilation took 9m59s, execution
8m21s, Swift 6 compilation 6m02s, Release compilation 9m48s, and packaging
10m50s. The xUnit artifact contains 7,571 cases with zero failures/errors;
Swift Testing separately reports 30 passed. Case durations overlap and cannot
be summed into elapsed time. These are observations, not controlled benchmarks.

## Retained build-state reuse

Each lane caches its own SwiftPM build directories. The identity includes
architecture, macOS, Xcode, Swift, SDK build, package manifest/lockfile,
workflow, and cache-key policy. A commit suffix permits new immutable entries;
restore prefixes never cross the identity boundary. No source timestamp
rewriting is used. Each build always executes after cache restore, so changed
or removed source inputs must be reconciled before any `--skip-build` test.
Tests always run, including on exact cache hits. SwiftPM and Xcode DerivedData
use separate caches. The Xcode identity additionally includes the packaging
script and resolved checkout, DerivedData and developer-directory paths.
Native echo-suppression build/source outputs remain outside both caches.
The opt-in `qualify_build_cache` workflow restores the exact entries published
by its distribution job, changes an actual app string and JSON resource, and
requires the rebuilt package to contain both changes. It restores the sources
and never saves that mutated build state. No GUI is launched.

The [GitHub cache contract](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)
scopes PR caches to their merge ref. Successful main runs seed caches available
to later PRs when compatible entries remain available; cache misses remain
ordinary full builds. Hosted cold/warm execution and actual package invalidation
passed as recorded below. Toolchain/manifest/workflow invalidation is covered
by executable helper tests using isolated inputs. The hosted "SwiftPM Build
Reuse Contract" step additionally builds, archives, and restores an owned
temp package to prove the installed SwiftPM itself keeps honoring a changed
or deleted dependency source and a changed manifest after a restored `.build`.
This is a consumer contract check on the toolchain, not a read of this
repo's actual cache hit/miss behavior or its cold/warm timings.

## Integration quality

The older raw-recording crash check previously ignored the result of `kill()`
and accepted playable media after a child could exit normally. It now requires
a successful SIGKILL and signal termination, fails if the helper survives to
clean finalization, and defers child cleanup for errors. CI explicitly executes
both raw-container survival and fresh-process production recovery/idempotency.
Synthetic audio and stub speech recognition do not establish microphone or
model quality. Native Library GUI, real-model inference, and physical device
qualification retain the prerequisites in [the qualification guides](../testing/README.md).

## Results and decision

[PR #1175](https://github.com/moona3k/macparakeet/pull/1175) merged as
`3dde9219c20cf4c1fb5eefdcae492ef11c0d508c`. The fixed acceptance rule required
at least 5% elapsed improvement without more than 10% occupied-runner regression,
all correctness gates, an identical-head warm rerun, and actual consumer invalidation.

| Observation | Head / attempt | Elapsed | Occupied macOS |
| --- | --- | --- | --- |
| [Original baseline](https://github.com/moona3k/macparakeet/actions/runs/36247644540) | `529e23ad` / 1 | 27m05s | 47m58s |
| [SwiftPM-only cold](https://github.com/moona3k/macparakeet/actions/runs/36251805803/attempts/1) | `c72489c2` / 1 | 46m11s | 70m03s |
| [SwiftPM-only warm](https://github.com/moona3k/macparakeet/actions/runs/36251805803/attempts/2) | `c72489c2` / 2 | 26m11s | 46m16s |
| [Newer main reference](https://github.com/moona3k/macparakeet/actions/runs/36256318137) | `ed92db91` / 1 | 32m26s | 53m26s |
| [SwiftPM + Xcode cold](https://github.com/moona3k/macparakeet/actions/runs/36258044277/attempts/1) | `88197f5e` / 1 | 34m26s | 58m09s |
| [SwiftPM + Xcode warm](https://github.com/moona3k/macparakeet/actions/runs/36258044277/attempts/2) | `88197f5e` / 2 | 25m15s | 45m39s |

Elapsed spans workflow start through the final gate; occupied time sums macOS
job lifetimes, including setup/cache overhead. Reruns use their own start time.
The later consumer-qualification run includes an extra job and is not a speed
comparison. All table runs passed.
PR rows identify branch heads; their workflows test GitHub merge checkouts.
The combined candidate tested `10110eb4` in both attempts; the manual consumer
workflow tested branch commit `88197f5e` directly.

The SwiftPM-only result improved elapsed by 3.32%, below the fixed threshold,
and was inconclusive. The retained combined configuration improved elapsed by
**110 seconds (6.77%)** against the original baseline. Occupied time differed
by 139 seconds (4.83%), inside the 5% comparison threshold: **runner-cost savings
remain unproven**. The decision tool selected the combined configuration because
elapsed cleared the threshold without violating the runner constraint.

Xcode's timed SwiftCompile task count fell from 37 cold to 5 warm. That proves
reuse occurred; it does not establish a universal or causal 6.77% speedup.
Hosted runners varied, and main gained tests between candidates: the final
candidate ran 7,679 XCTest cases versus the baseline's 7,571. The newer-main
observation is context, not a replacement baseline. No forecast promised a
numeric saving; the measured result supports retaining this bounded change,
with the costs below.

## Correctness evidence

The warm candidate's artifacts contain 7,679 XCTest cases with zero failures
or errors, 30 Swift Testing cases, and two executed process-crash journeys with
zero failures in 17.938 seconds. Swift 6, Ask CLI, prompt persistence, release
build, packaged resource, and CLI contract gates also passed.

[Consumer qualification run 36261692182](https://github.com/moona3k/macparakeet/actions/runs/36261692182)
passed at `88197f5e`. Its distribution job first built and saved branch-scoped
caches. A fresh dependent job restored the exact SwiftPM and Xcode keys for that
commit, changed a compiled app string and `discover-fallback.json`, ran normal
packaging, and verified the unique marker in the packaged GUI binary and parsed
JSON. The probe passed in 12m09s, restored both original source files, and saved
no mutated cache. Full workflow time was 47m45s with 73m33s of macOS jobs because
it also repeated ordinary validation and seeded cold caches. No app was launched.

Two earlier pushes were rejected during workflow parsing, scheduled zero jobs,
and are recorded as errors rather than timing samples. The actual rejection was
`runner.temp` in job-level environment expressions; moving those values into
consuming step environments fixed it. A preceding bracket-notation edit did not
fix that error. Full candidate verification followed the final correction.

[Integrated-main run 36264632281](https://github.com/moona3k/macparakeet/actions/runs/36264632281)
passed at exact merge commit `3dde9219c20cf4c1fb5eefdcae492ef11c0d508c`,
including independently merged changes that arrived during the trial. It ran
7,683 XCTest cases with zero failures/errors, 30 Swift Testing cases, and both
crash journeys in 18.958 seconds. Release, packaged resources/CLI, persistence,
and Swift 6 gates passed. This cold main-cache seed took 34m58s elapsed and
59m50s occupied macOS time; it is final integration proof, not a warm speed claim.

## Cache cost and limits

The retained configuration's three compressed entries totaled **6.83 GB**:
3.60 GB behavior SwiftPM, 1.62 GB distribution SwiftPM, and 1.61 GB Xcode.
Warm restoration occupied 54, 34, and 33 seconds respectively, **121 seconds**
across the two lanes; these costs are included in the table.

Retention is a material limit. After the warm run, repository cache usage was
12.25 GB across five entries, including older/main caches. After branch-scoped
qualification seeded another set, snapshots no longer listed the PR's behavior
or distribution entries; only its Xcode entry remained. This demonstrates cache
turnover, not a proven quota or eviction cause. No unrelated cache was deleted
and no quota was changed during this work. PR merge-ref caches cannot seed main
or a branch dispatch; future PR warmth depends on compatible retained default/base
or same-ref entries. Do not assume every PR receives the measured warm benefit.
After successful main seeding and completion of every consuming experiment,
only the two remaining owned branch-cache entries were removed (3.22 GB).
All three main entries were preserved, leaving 6.83 GB in the final snapshot.
No branch/worktree or unrelated cache was deleted.

The experiment stopped after the two candidate configurations; no further
optimization hypothesis was opened. Five experimental workflow attempts executed;
two additional pushes failed parsing before scheduling jobs. Completion extended
past the original four-hour planning window to finish review repairs, already-started
hosted qualification, integrated-main verification, and reporting. Local scratch
records retain measurements,
cache snapshots, decisions, and review history. Hosted evidence artifacts have
seven-day retention; this report preserves the durable numerical results and
run identities. Physical devices, native GUI behavior, and real model inference
remain outside the demonstrated checks.

## Deliberately deferred

Removing the SwiftPM app Release build would drop a distinct compilation
surface, so it is retained. Swift 6 scheduling and worker tuning were not
pursued in this bounded round. No broad test deletion, new test framework,
dependency, or cache timestamp restoration is included.
