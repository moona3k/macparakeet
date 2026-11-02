# Fresh title, knowledge-card, history, and activity review

Reviewed baseline `v0.8.10` (`394e630b4`) through initial review HEAD `93e7b3944`, including merged PR #1309 (`f7d1a4457`, head `6b712ff5`). Review date: 2026-11-01. Production code was read only by this reviewer; other release reviewers may subsequently change the checkout. Line references below describe the initial review snapshot.

## Findings

### P2, pre-existing: a month word makes a deliberate calendar title eligible for replacement

`MeetingTitleGenerator.shouldReplaceFallbackMeetingTitle`, lines 87–101, accepts every title beginning `Meeting ` that contains any English month name, clock time, or slash date. Its comment says month AND time, but its regular expression uses alternation. Consequently `Meeting May Hiring Plan` and `Meeting with June` are treated as generated timestamp fallbacks.

This reaches production without a hypothetical caller: `MeetingRecordingFlowCoordinator.startFromCalendar(calendarEventSnapshot:)` places the event title in `pendingTitle` at line 509; the start passes that title to `MeetingRecordingService`, whose session initialization at line 723 and `resolveDisplayName` at lines 2584–2588 preserve it. The initial lock stores `displayName` but does not mark the initial calendar name as a `titleOverride`. Final transcription at `TranscriptionService.swift:2310–2317` therefore permits title generation. `TranscriptionRepository.swift:1095–1118` preserves a concurrent rename or explicit override, but neither exists when the initial calendar name remains unchanged. An accepted generated title overwrites that deliberate name.

The same regex and initial-title handling exist at v0.8.10, so this is not a regression introduced by PR #1309. It contradicts the existing preservation rule reiterated in `spec/02-features.md:1886–1897`.

Focused reproduction: construct a calendar-start or equivalent recording named `Meeting May Hiring Plan`, provide at least twelve transcript words, enable titles, and return `Hiring Budget Review` from the mock title provider. Assert the deliberate calendar name is retained and the provider is not called. Also preserve tests for genuine default names. Production defaults use `DateFormatter.locale = .autoupdatingCurrent`, `.medium` date, `.short` time (`MeetingRecordingService.swift:2591–2596`); an English-month-only replacement predicate would fail for other locales. Existing compatibility fixtures additionally accept `Meeting` and `Meeting 6/17/2026`.

### P3, introduced by PR #1309: generic term plus year now passes useful-title validation

`validatedTitle(from:)` accepts `Meeting 2027`, `Discussion 2027`, and `Summary 2027`: each has two words, is below 70 characters, is not an exact member of the generic set at lines 126–140, and matches none of the narrowed date patterns at lines 152–160. Previously the blanket year rule rejected these. For a fallback-named meeting, an LLM response of `Meeting 2027` is persisted at `TranscriptionService.swift:2316–2317`; the fallback predicate subsequently rejects that title as replaceable, so a later retranscription will not improve it. This is a small validation gap against the stated generic-title rejection contract, not a release-wide blocker.

Focused reproduction: add validator rejection cases for generic term plus year, with positive controls `2027 Budget Review` and `Meeting 2026 Budget Planning`; use the existing persisted-title transcription test to confirm the timestamp fallback survives a generic-year result. The current unresolved CodeRabbit thread independently names the same case; this conclusion follows from current code, not its verdict.

## Reviewed coverage without additional confirmed defects

- **PR #1309:** traced the actual `TranscriptionService` caller, default preference and configured-analysis-route gate in `AppEnvironment`, generic provider operation, cancellation boundaries, logging, and transactional metadata preservation. Provider calls are bounded at two; invalid title responses are not retried. Cancellation and opt-out are checked after response and before another attempt. Diagnostics expose fixed classifications rather than transcript/title/CLI stderr.
- **Knowledge cards:** reviewed the changed `LLMService.generateKnowledgeCard`, configuration-contention retry, inference-capability resolver, input/output budgeting, HTTP adapter consumption of options, shared `CardDraft` decoding, and `CardGenerationService` persistence path. Four configuration reads and two LLM calls are the bounds; retries use one resolved context. Parseable truncation is rejected, partial provider output is not fed back, and missing usage stays unknown. Cancellation, unchanged-source checks, and `saveIfCurrent` protect replacement. The history of prior audit verdicts was not used as correctness evidence.
- **CLI history:** traced all three changed JSON commands through `printHistoryTranscriptionsJSON` and `SpeakerAttributionReadService.effectiveTranscription`, including correction fingerprint matching, edited/omitted text, speaker materialization, unchanged array schema, and no save-back. Reviewed new tests for all source types, corrected-word search, omitted text, original evidence preservation, and empty arrays against `cli-json-v1.md`.
- **Activity reminders:** traced `BrowserMeetingURLCollector`, candidate resolver, session policy, coordinator, AppEnvironmentConfigurer callbacks, quit invalidation, and the nonactivating panel. Reviewed fresh-evidence revalidation, prejoin veto, muted Meet controls, native process replacement, busy/dictation deferral, capture-success consumption, and stale callback tokens. Browser reads use existing AX consent, bound node/depth/time traversal, and role-gated document/button metadata; no provider requests or URL telemetry are introduced. Unknown background-browser observations preserve suppression while fresh evidence remains necessary to record.

## Verification limits and focused gaps

No build, test run, native UI action, or external provider request was performed by this reviewer; the parent owns execution. Existing test code was inspected, not treated as a substitute for native evidence.

- Title tests cover opt-out/cancellation immediately after a provider response; explicit cancellation/opt-out during the one-second backoff is not directly covered, though the next iteration checks both and the sleep is cancellable.
- Native Accessibility traversal and panel behavior still need supported-browser/native qualification. Reader injection and label fixtures cannot establish real AX topology, hidden-control exposure, responsiveness, or locale coverage. The governing ADR explicitly limits supported label fixtures and requires user confirmation.
- Actual provider response size, model context capacity, and recovery behavior remain unverified live. Mock tests establish request shape and control flow only.
- New capture constructors omit some lock metadata, including `titleOverride`, at the initial snapshot. This was shared with the capture reviewer as a lead, not promoted to a title finding: the observed retry caller retains an existing transcription row and its override. An actual loss path must be established before claiming a defect.

No Jev classification was needed: this was direct code execution tracing and contract review.

## Follow-up review of parent fixes

Reviewed the first uncommitted changes to `MeetingTitleGenerator.swift`, `TranscriptionService.swift`, their two test files, and `spec/02-features.md` after the parent reported reproducing both findings with failing tests. The initial assessment missed a production counterexample; the corrected assessment below supersedes it.

The first calendar guard used the existing normalization helper, which returns nil for a missing, empty, or whitespace-only title. My initial claim that all production snapshots name the recording was incorrect. `MeetingRecordingFlowCoordinator.startRecording` at lines 388–394 also attaches `probableCalendarSnapshotProvider()` to manual/hotkey starts with `title == nil`, while retaining a generated fallback name. The capture reviewer identified this missed caller, and the parent reported reproducing three failing assertions against the first guard. Mere presence of a nonempty snapshot title would suppress legitimate automatic titles on that path.

The validator removes a trailing four-digit year only for the generic-label comparison. Its returned title is unchanged. Existing generic labels still reject; topical year titles and descriptive titles such as `Meeting Notes for Acme 2027` remain accepted. Retry classification/count, cancellation boundaries, preference checks, input construction, and logging have no changes.

The scoped `git diff --check` passed. This follow-up did not run tests or builds; parent-owned focused verification was still running when this assessment was written. The broader fallback recognizer still has its pre-existing permissiveness for non-calendar initial custom names without explicit override provenance; the confirmed calendar path is addressed without claiming a general fallback-recognition rewrite.

### Corrected calendar guard follow-up

Read the revised production diff and tests. The guard now compares the normalized snapshot title with the normalized current `fileName`, protecting the calendar name only when the recording uses it. A distinct probable calendar snapshot, nil snapshot, and blank snapshot title leave a nonempty fallback eligible. If both title and filename normalize to nil, generation is skipped, which does not change the old behavior because an empty filename already fails the generator's fallback predicate.

The regression table now covers adopted calendar names, a probable snapshot with a distinct title, and whitespace-only event titles; the existing fallback-generation test covers no snapshot. The generic-title generator test additionally confirms `Meeting 2027` returns no replacement after exactly one provider call. Descriptive topic years remain unchanged. Retry, cancellation, input privacy, and transactional metadata behavior are unaffected by the revised diff. No remaining concrete defect was found in this corrected patch. No tests or builds were run by this reviewer; parent-owned focused verification remains the execution evidence.


## PR #1310 exact-match probable snapshot follow-up

The equality approximation above still suppressed generation if an unnamed manual recording's timestamp filename exactly equalled a probable calendar title. Production provenance permits a narrow correction: calendar selections produce confirmed snapshots and adopt their names, while unnamed manual/hotkey starts produce probable snapshots. Explicit manual names do not receive probable snapshots, and later edits set the existing title override. These producers and the required Codable confidence field also exist in v0.8.10; recovery preserves that confidence.

The guard now requires confirmed confidence as well as equal normalized names before protecting the calendar title. The regression table adds the exact matching probable/default-filename case and retains confirmed names, distinct probable and blank titles. The parent reproduced three failures before the fix, then reported 142 focused tests passing. Independent read-only re-review found no further issue in this delta or the strengthened probe test; execution evidence remains parent-owned.
