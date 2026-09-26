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

## Build-state reuse trial

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
to later PRs; cache misses remain ordinary full builds. Cache transfer time,
size, cold/warm timings, and source invalidation need hosted verification before
this trial can be accepted. Toolchain/manifest/workflow invalidation is covered
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

## Results

The SwiftPM-only trial at `c72489c2` passed both
[attempts of run 36251805803](https://github.com/moona3k/macparakeet/actions/runs/36251805803).
Cold: 46m11s elapsed and 70m03s occupied macOS time. Warm: 26m11s elapsed and
46m16s occupied macOS time, with exact cache hits in both lanes. The combined
cache entries occupied about 4.99 GB and warm restoration took 1m58s total.
Warm elapsed improved only 3.32% against the earlier baseline, below the
preselected 5% threshold. This is inconclusive, not a demonstrated win.
The cold distribution runner compiled the same number of tasks much more
slowly; its cause is unknown. These observations are not controlled benchmarks.

The follow-up trial adds the separate DerivedData cache because warm packaging
still took 16m07s. Its cold/warm timings and actual package invalidation proof
are pending. Main advanced independently through #1160 between candidates;
comparisons must retain their commit identities.

## Deliberately deferred

Removing the SwiftPM app Release build would drop a distinct compilation
surface, so it is retained. Swift 6 scheduling may improve turnaround at the
cost of extra setup; measure after the cache trial. Worker-count tuning has no
established benefit from the current timing artifact. No broad test deletion,
new test framework, dependency, or cache timestamp restoration is included.
