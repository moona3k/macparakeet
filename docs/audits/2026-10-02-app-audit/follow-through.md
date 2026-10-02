# Audit follow-through

The owner authorized landing the verified fixes and proceeding through the
prioritized follow-through on 2026-10-02. This record distinguishes merged
source, pending review and still-unqualified product behavior.

## Current delivery

- [Website PR #102](https://github.com/moona3k/macparakeet-website/pull/102)
  merged at `1390491ea7b2c9dc09d443d1eae766ed87ce3322` on October 2.
  Immediately before merge, both review checks passed, no review threads were
  unresolved, all 146 telemetry tests passed with zero skips, and the Astro
  build produced 86 pages. The tested head was `30743ed31`.
  A local browser replay additionally verified both legacy event-count and
  current session-reach captions and actual chart tooltips, with zero page
  errors ([receipt](evidence/onboarding-dashboard-browser.json)).
  Merged source does not establish that Pages and the snapshot worker both
  run it; deployment verification is separate.
- [App PR #1205](https://github.com/moona3k/macparakeet/pull/1205) is in final
  review. The replacement Library query now runs off the main actor; bulk
  mutations also invalidate stale loads and preserve partial-failure state.
  GUI retranscription publishes Core's committed result without a redundant
  save that could overwrite later transcript corrections. All 264 focused GUI
  cases pass, including 80 Library and two real Core/SQLite regressions.
  Final checks must cover the revised head before merge.
- The next cancellation repair has reproduced late-result persistence across
  speaker detection and post-processing, with 155 focused tests passing after
  correction. It is being kept in a separate branch/PR with its own evidence.
- The owner explicitly skipped first-run onboarding qualification and authorized
  physical-audio tests on this Mac. Those tests use isolated dev state; no
  personal permission reset or first-run certification is implied.

## Execution order

1. **Land the app fixes.** Address valid review findings, run focused regression
   tests, inspect exact-head hosted CI and all review threads, then merge the
   reviewed head. Preserve unrelated local checkouts and active work.
2. **Preserve cancellation, then expose outcomes and provenance.** First land
   the verified late-result cancellation repair. Then implement a bounded
   end-to-end slice from actual model execution through saved transcription,
   CLI JSON and a nonblocking result-view explanation. Legacy rows remain
   unknown. Preserve successful ASR, cancellation, source separation, explicit
   speaker constraints and user correction overlays. Do not change clustering
   or smoothing from the two training-exposed regression cases. Update data,
   CLI and ADR contracts with the implementation and tests.
3. **Qualify onboarding and recovery.** Fix the identified Whisper lifetime/
   watchdog gap in a separate reviewed change. First-run qualification is
   skipped at the owner's request. Run the authorized physical capture checks
   on this Mac with isolated artifacts. Offscreen renders remain layout
   evidence, not permission/focus/audio-delivery proof.
4. **Close telemetry's operational contract.** Coordinate existing receiver
   work, require readable compatibility evidence, and verify staging ingestion
   and authorized deployment separately from the public stats read.
5. **Measure latency, memory and CI cost.** Use repeatable optimized workloads
   and matched cache/run receipts. Attribute a regression before changing
   scheduling or deleting tests. Qualify low-memory call workloads on suitable
   hardware rather than extrapolating from this 48 GiB host.

The [recommendations](recommendations.md) retain detailed acceptance criteria
and stopping conditions. A reviewable implementation, a merged change, a
deployed receiver and physical release qualification are separate milestones.
