# Crash context and bounded report retention

Status: implementation and independent review complete; focused verification and final PR gate in progress. Base `ffa6bda6e`. User requested deep review, verification, implementation, and PR; subsequently made avoiding regression/performance harm a release requirement. No merge, release, deployment, or native crash fix is in scope.

## Problem and scope

Recent crash investigation could identify native caller boundaries but not reliably connect fatal reports to the original process's last capture state. Ordinary telemetry is memory queued, framework image identity is incomplete, and one pending file can be overwritten. Improve those three gaps without changing capture, recovery, inference, consent, or logging cadence.

Use the [canonical-event principle](https://loggingsucks.com): enrich the crash record with bounded context; reuse existing operation telemetry. No user IDs, raw messages, transcripts, audio, device names, filenames, or per-buffer events. Random per-process/session and per-crash identifiers are ephemeral correlation, not longitudinal identity.

## Proposed design and ownership

1. **Native bounded context (root):** fixed 32-record numeric ring in C. Normal lifecycle writers never do disk/network I/O, formatting, allocation, or wait. A single atomic try-claim serializes writers; contention drops a breadcrumb and increments a counter. Slots contain lock-free atomic sequence/value pairs; publish invalidation before mutation and validate sequence before/after read. Fatal reader makes one bounded pass, never waits for writer ownership, and omits incomplete records. Update registered-workflow mask independently. All context is appended to the already existing minimum fatal report before unsafe best-effort backtrace. No new timer/thread, locks, Swift/ObjC/dyld work inside the signal handler. Native memory limits are compile-time; required atomic widths must be always lock-free.
2. **Typed hooks (capture owner):** internal `CrashAudioContext` maps finite enums into numeric payloads; each lifecycle observer receives a process-local attempt token. Hook normal lifecycle enter/beginAttempt/finish and precise teardown/recovery boundaries, excluding scoped subscription waiting and real-time render/buffer callbacks. Tagged events mean transitions, not a single authoritative current state: late A.finish after B.enter remains A's event and must not overwrite B's state. No attempt token is described as engine generation. Registered consumers are workflow owners, not microphone-active flags; passive warming may have none.
3. **Report ownership (storage owner):** up to 16 per-process UUID directories under `CrashReports`, each with report and stable owner lock. Hold owner lease through process exit; upload/prune only after nonblocking claim. Bound report reads to 32KiB and unreadable/unparseable report retention subject to capacity eviction. Short nonblocking queue lock for reservation/prune; never across await/network. Skip persistence if capacity is entirely live/claimed. Remove empty dead reservations; capacity eviction only affects owned diagnostic reports, never recordings or user data. New writers never use legacy path. Legacy reports retain no newly invented crash ID. Preserve true=delivered/intentional-discard and false=retain semantics of `sendAndFlush`.
4. **Identity (root/integration):** one random process session shared by default telemetry, local audio logs, and startup crash metadata. Upload envelope stays the new process; optional `crash_session` identifies the original one. Snapshot random crash ID, OS build, and dyld shared-cache UUID/slide during normal startup using public SDK Mach/sysctl APIs; omit on failure. App UUID/slide remains existing evidence. No claim of full dynamic-image/all-thread crash reporting.
5. **Wire contract (root + receiver owner):** optional bounded props on existing `crash_occurred`: `crash_id`, `crash_session`, `crash_os_build`, `shared_cache_uuid`, `shared_cache_slide`, `crash_context_version`, `crash_registered_consumers`, `crash_breadcrumbs_dropped`, and `crash_breadcrumbs_incomplete`. Raw ring remains local. Receiver validates optional fields, prefers valid persisted crash ID for dedup with legacy fallback, strips private diagnostics from public responses, and requires no D1 migration. Companion receiver PR precedes app release; no deployment here.

Detailed lifecycle summary fields are omitted from wire v1 because they could misrepresent current native ownership. The local ring preserves observed transitions.

## Must-not-change invariants

- No recovery timing, audio ownership, engine replacement order, STT routing, or normal operation emission policy changes.
- No new work on render/buffer callbacks. No blocking persistence or queued logging jobs during lifecycle recording. Startup metadata/storage work is bounded and degrades to missing diagnostics on failure.
- Fatal handler cannot wait on normal threads, acquire locks, allocate, call Swift/ObjC, or enumerate images. Existing best-effort backtrace limitation remains disclosed.
- A live process/report claim is never pruned, sent, or deleted; failed delivery stays pending subject to explicit capacity retention. Opt-out intentionally disposes reports through the existing policy.
- No stable identity, raw content, arbitrary keys, or public diagnostic exposure. Receiver deployment remains a release prerequisite, not assumed by PR creation.
- Capture continues if diagnostics are unavailable. CLI reporter installation is unchanged.

## Review and verification before delivery

- Independent design reviews: audio-hook semantics/races, filesystem ownership/consent, receiver/privacy/dedup. Resolve substantive objections before implementation.
- Focused executable tests: overlap/stale lifecycle completion; finite decoding; ring wrap and contended/incomplete writes; native fatal report survives failed backtrace; malformed/oversized files; live lock contention; two drainers; crash during upload; failed upload; legacy replacement; opt-out; old/new event compatibility.
- Performance: release-optimized native recording benchmark, single and competing writers, fixed memory/ring bound, no healthy-path file output, and startup snapshot/retention timing. Measure rather than assert zero cost. Investigate any material tail-latency cost before shipping; diagnostic recording must drop under contention rather than wait.
- Run focused Swift suites during development; full Swift suite at most once in final no-mistakes gate. Receiver focused tests/build in isolated companion worktree. Native signal tests run disposable processes only.
- Independent correctness, maintainability, privacy and performance review on committed diff, local Greptile, no-mistakes gate, current PR checks/thread sweep. Document unverified physical/native audio behavior; instrumentation does not prove crash resolution.

## Known boundaries

The ring is persisted as part of fatal reporting, not periodically to disk. SIGKILL, power loss, or failure before handler persistence can still lose it. This deliberately avoids continuous capture-path I/O. Exact-once upload is not promised; persisted crash ID enables deduplication. Safe coexistence with legacy writers that ignore leases has limited guarantees and needs explicit migration tests/documentation. Shared-cache metadata does not describe every later-loaded non-cache dylib. No broad exposure/outcome instrumentation or telemetry transport rewrite in this PR.

## Design-review resolutions

- All slot invalidation/payload/publication stores and reader loads are sequentially consistent. Sequence zero means unpublished. Sequence values never repeat: stop accepting records at counter exhaustion. Reader accepts only the expected nonzero sequence observed identically before and after payload read. No handler retry or writer-flag acquisition. Incomplete/skipped slots and writer contention are reported distinctly from complete history.
- Wire v1 omits detailed lifecycle summaries. Only original identity, OS/cache metadata, context schema, registered-workflow mask, and bounded dropped/incomplete counts extend the crash event. Local numeric history retains attempt-tagged transitions. This avoids misrepresenting late completion or dropped events as current native state.
- Limit directory inspection to 64 entries per pass and managed reservations to 16. Fail diagnostics reservation on traversal/capacity/lock failure. No blocking lock waits. Queued draining/maintenance is off-main; startup reservation has measured filesystem cost, not a claimed hard wall-time bound.
- Cap both C and Objective-C emitted reports below 32KiB, including exception strings and stack count. Bounded reads alone are insufficient.
- Adopt legacy file by rename under queue ownership before awaiting upload; never stat-then-delete a possibly replaced legacy file after await. Never invent a crash ID for adopted legacy content.
- Measure the complete Swift-to-C adapter and native recorder under release optimization, including contention. Benchmarks do not prove absence of all regressions; native audio qualification remains explicitly unrun until exercised.

## Verification record

See [crash-context-verification.md](../crash-context-verification.md) for measured
costs and release proof boundaries. Local Greptile is unavailable because the
installed CLI is signed out; independent code reviews cover the native buffer,
filesystem ownership, archive, receiver, and privacy contract. The final gate
and PR retain automated validation evidence. No Jev steps were needed: this
change uses fixed schemas and mechanical validation, not semantic judgments.
