# Recover dictation admission from stale synthetic input (#1286)

## Intent and boundary

Prevent an app-posted key from indefinitely vetoing bare Fn, including after
process restart, while still rejecting a real pre-held key or modifier.
Preserve physical typing interruption, passive Fn delivery, peer ownership,
custom shortcuts, layout-aware copy/paste, and clipboard restoration.
Keep tap callbacks independent of the main thread and free of diagnostic I/O.

The persistent rejection was established by source inspection: the old
physical-key provider read combined session state and subtracted only releases
remembered by its process. The rare native trigger is not reproduced. A marker
alone cannot fix the aggregate veto or survive a fresh process.

## Work

1. Measure Quartz source/table behavior with a bounded standalone probe on a
   disposable GitHub macOS runner. Never inject deliberately incomplete input
   into the user's active desktop. Record source identity, posting location,
   session/HID state, process restart, and cleanup outcomes.
2. Use the evidence to choose the narrow admission/recovery policy and event
   source. Mark our synthetic events consistently at the production boundary.
   Do not add a timeout, unconditional corrective release, or V-specific bypass.
3. Add deterministic regression and negative-control tests; update the input
   contract, feature spec, subsystem README, and root-cause record.
4. Commit, open a PR, obtain independent review, and drive exact-head GitHub CI
   and valid review findings to completion. The user subsequently authorized
   merge after final review without waiting for another CI run. The production
   head passed CI and the expanded native probe; final review also includes
   Sonnet 5.5 at xhigh effort. Release remains gated on native acceptance.

## Verification

The user requests GitHub CI instead of local CI. No local Swift build/test or
no-mistakes test gate. Static checks and review are appropriate locally.
GitHub tests must cover stale aggregate with physical-up, real held keys,
startup/recovery, marked input, peer callbacks, and Command-layout resolution.
Runner synthetic-state evidence is distinct from physical-key and Jump Desktop
acceptance; retain any unperformed native gates explicitly in the PR.
