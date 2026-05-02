# Logging & Telemetry Review -- 2026-05-02

> Status: REVIEWED. Article reviewed: [Logging Sucks](https://loggingsucks.com/).
> Scope: MacParakeet app/core/viewmodels/CLI telemetry, local logging, crash
> reporting, and the checked-in Cloudflare telemetry Worker in
> `macparakeet-website`.
> Follow-up tracker:
> [`2026-05-02-logging-telemetry-issues.md`](2026-05-02-logging-telemetry-issues.md).

## Bottom Line

MacParakeet is already in good shape against the article's core advice. The app
does not rely only on scattered string logs; it has typed, privacy-safe
operation events for the main workflows:

- `dictation_operation`
- `transcription_operation`
- `meeting_operation`
- `llm_operation`
- `feedback_operation`
- `auto_save_operation`
- `cli_operation`

That is the right desktop-app translation of "one wide event per request".
Because MacParakeet deliberately avoids persistent user IDs, it should not copy
the article's user-centric high-cardinality model literally. Short-lived
`operation_id`, `workflow_id`, and `session` IDs are the right privacy-preserving
correlation mechanism.

## Strengths

- Typed `TelemetryEventSpec` prevents most schema drift and content leakage.
- `TelemetryImplementedContract` tests ensure every Swift event name has a
  serialization contract.
- Operation context propagation with `Observability.currentOperationContext`
  links CLI, transcription, meeting, and LLM child work without string search.
- Telemetry is opt-out, session-scoped, non-identifying, and CI-disabled for the
  CLI unless explicitly forced on.
- LLM telemetry avoids prompts, responses, provider error bodies, and API keys.
- Crash reporting is self-hosted and sends on next launch through telemetry
  rather than adding a third-party SDK.
- Local audio diagnostics are useful for low-level capture bugs that product
  telemetry should not try to encode exhaustively.

## Gaps & Refinements

1. **Docs overclaimed Worker redaction.** The app sanitizes paths/URLs at the
   Swift telemetry boundary, but the checked-in Worker validates and stores; it
   does not currently redact API-key-looking strings or emails. Treat Worker
   redaction as defense-in-depth follow-up, not shipped behavior.

2. **Retention cron not visible in the checked-in website Worker.** The policy
   target is 90-day raw-event retention, but the initially reviewed website repo
   did not show a scheduled deletion cron. Fixed in follow-up on the sibling
   website branch `codex/telemetry-retention-cron`; deploy it before relying on
   automatic deletion in production.

3. **Worker allowlist is a superset of app events.** It includes legacy/planned
   names such as `app_updated`, `paywall_viewed`, `llm_summary_*`, and Live Ask
   prompt events. A superset is acceptable, but a release check should verify
   every Swift `TelemetryEventName` is accepted and docs match emitted events.

4. **Model cancellation should be analyzed through `model_operation`.** The
   earlier `model_download_cancelled` candidate duplicated the richer canonical
   lifecycle event and was too broad for warm-up cancellation. The app and docs
   now use `model_operation(outcome=cancelled)` for download/warm-up
   interruption analysis.

5. **Local logging conventions need continued tightening.** Many logs already
   use event-style `key=value` messages, but subsystems and privacy annotations
   are inconsistent. This follow-up normalized a targeted set of
   dictation/transcription lifecycle logs, including making one captured audio
   path private. New logs should prefer stable event names, safe dimensions,
   classified `error_type`, and `.private` for paths, URLs, filenames, device
   names/UIDs, prompts, notes, and provider bodies.

6. **No shipped diagnostic export path was found.** The spec described
   `Help > Export Diagnostic Logs`, but current menus/settings only expose copy
   build info and local logs. Implement an explicit user-triggered diagnostic
   bundle before depending on user-exported logs for support.

7. **Operation events could include more STT dimensions.** Fixed in follow-up:
   `dictation_operation` and `transcription_operation` now include
   `speech_engine` and `engine_variant` from authoritative STT attribution.
   Coarse language/source buckets can still be considered later if product
   analysis needs them.

8. **Local logs and telemetry are not always joinable.** Consider including the
   short-lived `operation_id` in major local lifecycle logs for dictation,
   transcription, meeting, and LLM operations. Do not persist it across launches
   or expose it as a user identifier.

9. **Sampling is not needed yet.** Event volume is low enough that full capture
   is reasonable. If volume/cost changes, tail sample only successful fast
   operations and keep all failures, crashes, unavailable outcomes, and slow
   operations.

## Recommended Sequence

1. Add Worker-side redaction and a Worker/Swift event-name sync check.
2. Implement the diagnostic export bundle with redaction.
3. Continue gradually normalizing local OSLog lines when touching nearby code;
   avoid a repo-wide churn-only logging rewrite.
