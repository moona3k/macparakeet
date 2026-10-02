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
- [App PR #1205](https://github.com/moona3k/macparakeet/pull/1205) merged at
  `9d63551d452c7f521f53fea186729525f2eb0a30` on October 2, after all 19
  review threads were resolved and the final head `317374b55` passed hosted
  CI. The fixes preserve CLI/GUI retranscription ownership, prevent stale
  Library publication across single and bulk mutations, move replacement
  queries off the main actor, and repair onboarding recovery layout.
  All 264 focused GUI cases passed, including 80 Library and two real
  Core/SQLite regressions. [Final CI receipt](evidence/pr1205-final-ci.json).
- [Cancellation PR #1206](https://github.com/moona3k/macparakeet/pull/1206)
  merged at `f3a8758ae7be4c0b3fdd65aa37a5a5cfea3072bd`, after final head
  `ef461c949` passed hosted CI and all four review threads were resolved.
  It checks cancellation after late backend results and before persistence,
  while retaining inference ownership until native work actually exits.
  The 155 focused tests cover failed-before/passed-after behavior and genuine
  optional-failure controls. [Final CI receipt](evidence/pr1206-final-ci.json).
- Both final PR runs passed 7,929 xUnit cases and 30 Swift Testing cases,
  Swift 6 and release/bundle checks. Counts belong to each separate PR run;
  they must not be added together as distinct tests. The XML summaries do
  not report skipped-case counts. The telemetry comparison still explicitly
  skipped; the cache-invalidation job is opt-in and was skipped too.
- After both app merges, [440 focused cases](evidence/integrated-main-tests.json)
  passed on combined `main` `f3a8758ae`, covering the affected CLI, GUI and
  diarization flows together. No second full local suite was run.
- [Physical audio checks](native-audio.md) on this Mac passed short dual-source
  and microphone-only capture, known-phrase recognition and saved-artifact
  reopen. The lower-gain first probe captured the fixture but did not recognize
  it under competing playback. The owner explicitly skipped first-run testing.
  Bluetooth, AEC and long-call qualification remain separate.
- The durable outcome/provenance slice has a
  [reviewed implementation plan](../../../plans/active/2026-10-02-diarization-outcomes.md).
  It is not implemented by the cancellation repair. Legacy outcome handling,
  public CLI/GUI exposure and held-out final-word evaluation remain next work.

## Execution order

1. **App fixes landed.** Exact-head CI and review convergence completed for
   #1205 and #1206. Original dirty checkouts and unrelated active work were
   preserved. Complete source delivery is separate from a stable release.
2. **Preserve cancellation, then expose outcomes and provenance.** The
   late-result cancellation repair is landed. Implement a bounded
   end-to-end slice from actual model execution through saved transcription,
   CLI JSON and a nonblocking result-view explanation. Legacy rows remain
   unknown. Preserve successful ASR, cancellation, source separation, explicit
   speaker constraints and user correction overlays. Do not change clustering
   or smoothing from the two training-exposed regression cases. Update data,
   CLI and ADR contracts with the implementation and tests.
3. **Qualify onboarding and recovery.** Fix the identified Whisper lifetime/
   watchdog gap in a separate reviewed change. First-run qualification is
   skipped at the owner's request. Short physical capture checks on this Mac
   passed with isolated artifacts; extend them only to the remaining named
   hardware/workload boundaries. Offscreen renders remain layout
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
