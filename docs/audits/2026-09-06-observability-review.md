# Telemetry and local audio observability review

Reviewed [Logging Sucks](https://loggingsucks.com/), the live
[stats page](https://macparakeet.com/stats/) and its JSON endpoint, the Swift
telemetry producer and outcome call sites, local audio diagnostics, and the
website ingestion, aggregation, rollup and deterministic agent-review code.

App baseline: `1159dfca8ae53a15ffcc1562b1efb9220f95cd88`.
Website baseline: `80be9eb` in the separate `macparakeet-website` repository.
Both changes use isolated worktrees; existing working-copy edits were preserved.

## Assessment

The operation-wide-event model already fits MacParakeet. An operation outcome,
safe dimensions and short-lived correlation let agents answer useful questions
without collecting speech content. The article's recommendation to enrich
outcomes is useful; its user-identifying examples do not fit this product's
privacy contract. More generic log volume or a new observability vendor would
not solve the defects found here.

| Observed defect | Change |
| --- | --- |
| Live API returned a snapshot generated at `2026-09-06T02:50:10.416Z` when fetched at `07:26:36Z`, with `X-Stats-Cache: stale`, despite live/five-minute page copy | Explicit JSON and visible freshness, expiry-bounded caching, uncached stale/error responses; distinguish 15-minute snapshots from five-minute polling |
| Public failure details contained a residual filename/path after whitespace stopped the sanitizer | Omit free-form network errors; drop them at ingestion for old clients; filter cached public snapshots and coarsen unknown public error categories |
| Failed in-flight telemetry could restore a queue cleared during opt-out; queued batches could send later | Consent generation invalidates retries and waiting batches; already-dispatched requests may complete |
| Cancellation inflated dictation failures; successful CLI thrown exits carried runtime error categories | Preserve cancellation as a separate terminal outcome and remove errors from successful CLI exits |
| A late confirmation through the public dictation service could emit cancellation after success for the same operation | Admit at most one terminal outcome for the current operation; reset the guard for a new operation without changing capture/UI timing |
| Private reviewer used stage-specific or missing denominators, and missed runtime/VAD/export diagnostics | Whole-operation denominators with action/command separation, explicit unknown evidence and separate diagnostic-signal counts |
| Overall and meeting durations weighted incomplete averages by all operation/success counts | Expose and use measured duration sample counts; older snapshots produce unknown aggregate duration |
| Activity panels divided unrelated time-window starts/completions; dual capture was inferred from separate track totals | Show breadcrumb counts without cohort claims; count both tracks on the same successful meeting outcome, using known track statuses as the denominator and showing measurement coverage |
| Local async log timestamps represented write time; append failures could overwrite history; retention could discard complete lines; app/CLI writers could race during rotation | Capture occurrence clocks before enqueue, add local process correlation, preserve history on failure and retain whole lines; coordinate participating writers through a stable advisory lock |
| Agents had no bounded structured query path for the audio log | Offline JSON query utility with filters and explicit missing, incomplete, changed-during-read and unparseable evidence |
| Malformed ingestion objects/types could reach D1 binding or throw before the error handler | Validate record shapes, bounded envelope strings and UTC timestamps before binding |

The website also emits a structured stats-request outcome with duration,
cache state, historical source and available aggregate query metadata, and no
longer scans events for the retired formatter panel.

## Essential signals and how to query them

| Question | Evidence and limits |
| --- | --- |
| Did an operation succeed, fail, cancel, return empty or become unavailable? | Canonical `*_operation` outcomes; delivered terminal events are the denominator, not a census of all attempts |
| Which engine/version/stage is implicated? | Release/surface, engine/variant, operation stage and classified error type; preserve recognized CoreAudio numeric status and the fixed interrupted-subscribe category |
| Did capture receive or retain audio? | Local first-buffer, timeout, frame/sample/signal, stop-summary and meeting source-health events; these do not establish semantic transcription quality |
| Did recovery happen? | Local configuration-change recovery attempt/outcome and microphone/system-stream diagnostics; detections alone are not terminal operation failures |
| Is the dashboard current? | Read `freshness` and expiry; a successful read does not prove ingestion health |
| Is there enough evidence for an agent verdict? | Review input age/population, denominators and diagnostic query scan metadata; missing data means unknown |

See the [telemetry contract](../../spec/contracts/telemetry-v1.md),
[offline query guide](../local-audio-diagnostics-query.md), and the separate
website repository's `docs/telemetry-api.md` and `docs/telemetry-reviewer.md`.

Read-only local verification scanned the existing 1,992,759-byte audio log:
13,847 complete lines, 13,840 parsed records, seven unparseable lines, no byte
truncation and no observed modification during the read. The latest timestamp
was `2026-09-05T06:52:14.460Z`. Only aggregate counts and timestamps were
reported; no audio or transcripts were opened. This is historical diagnostic
evidence, not a new microphone/hardware exercise.

## Boundaries and follow-ups

- This app change does not deploy the companion website or release a new app
  version. The website fixes need their own reviewed deployment. No production
  telemetry write canary or historical row deletion was performed.
- The live refresh failure's underlying D1/Worker cause remains unconfirmed:
  the original D1 request returned authentication error `10000`, but subsequent
  device authorization succeeded. Authenticated database metadata and schema
  queries now pass; the database is approximately 2.2 GB and the event, snapshot
  and rollup tables exist. This does not establish snapshot-refresh health or
  the reason for the earlier stale result.
- Every current Swift event name was accepted by the checked-in Worker name
  allowlist. A persistent cross-repository name/schema gate and complete
  per-event property/value schemas remain follow-ups; generic length/shape
  validation is not a complete privacy boundary for arbitrary future clients.
- Telemetry remains best effort. Queue caps, opt-out, offline sessions and process
  death limit completeness. No all-attempt availability claim or user-level
  cohort inference is justified from these counts.
- Per-process local correlation is available on newly written records; a capture
  operation ID is not yet present on every low-level audio event. Legacy records
  remain readable and must be interpreted with their weaker correlation.

## Verification

- Final combined Swift focused checks passed: 224 XCTest cases and a focused
  subset of 21 Swift Testing cases (the full suite below ran 25). These cover
  telemetry consent/retry behavior, event privacy,
  error classification, CLI outcomes, dictation terminal outcomes, diagnostic
  writing/rotation and scope, plus all 35 `AudioRecorderFormatChangeTests`.
- The single full `swift test --disable-automatic-resolution -j 1` run executed
  5,243 XCTest cases with 20 skips and two failure reports from one case:
  `AudioRecorderFormatChangeTests.testDiscardPreRollMakesMediaOnlyCaptureInsufficient`.
  Its mock-engine readiness poll reached its two-second deadline, then the test
  cancelled capture. All 25 Swift Testing cases passed. The entire failing test
  family passed in the subsequent focused run; the failure's cause remains
  unconfirmed. This is not a clean full-suite result. The terminal guard and
  bridged-code naming received their focused verification after that full run.
- Offline diagnostic-query tests passed: 11 synthetic-file tests. The read-only
  historical log inspection is described above.
- PR #962 feedback verification: 149 focused XCTest cases passed across
  telemetry, dictation, and audio diagnostics; the final classifier-only run
  passed all 25 Swift Testing cases. The query suite passed 14 synthetic-file
  tests, including first-byte alignment, atomic replacement, and disappearance.
  These follow-up runs cover atomic request admission, cancellation, deferred
  writes with original clocks, deterministic success dwell, and quoted secrets.
- Independent agent reviews covered client privacy/consent/outcomes, local
  writer concurrency/data preservation/query semantics, and website evidence
  calculations. Valid findings were addressed; production publication gates
  and external review bots were not invoked.
- Website checks passed: 52 tests with zero skips, including real TypeScript
  route handlers and all 53 stats statements against synthetic in-memory SQLite
  data. The fixtures cover incomplete duration/track measurements, disjoint
  audio tracks, stale/error caching, malformed ingestion and cached privacy.
  `pnpm build` produced 86 pages successfully.
- `git diff --check` passed in both worktrees. Informational Swift formatting
  checks addressed new diagnostics; inherited repository warnings remain.
- The final classifier-only check passed all 23 tests after restricting native
  NSError domain transmission to six recognized system domains. Identifier-like
  custom/private domains now fall back to `NSError.<code>`.
- After Cloudflare authentication, the updated reviewer completed against live
  D1 with `--no-write`. Latest stable v0.7.4 had no thresholded alerts among
  observed events. All-version watch signals concerned v0.7.3 GUI engine-busy
  switches (three), microphone-stall detections (28), and unhealthy-runtime
  detections (17). This is operational evidence, not complete event-delivery
  coverage or deployed website verification.

No physical microphone, browser visual comparison or deployed Worker behavior
was exercised. The machine also showed substantial process pressure during
setup, including process-start failures; this does not establish the cause of
the Swift test timeout.
