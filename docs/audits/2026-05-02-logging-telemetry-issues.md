# Logging & Telemetry Follow-Up Tracker -- 2026-05-02

> Source review: [`2026-05-02-logging-telemetry-review.md`](2026-05-02-logging-telemetry-review.md)
> Scope: MacParakeet app telemetry/logging plus the self-hosted telemetry
> ingestion Worker in `macparakeet-website`.

Status legend: **TODO**, **IN PROGRESS**, **FIXED**, **DEFERRED**, **REFUTED**.

| ID | Priority | Status | Title | Notes |
|---|---|---|---|---|
| LOGTEL-001 | P1 | FIXED | Implement 90-day raw-event retention cron | Implemented in sibling website worktree branch `codex/telemetry-retention-cron` as a standalone scheduled Worker bound to the telemetry D1 database. Requires deploy via `pnpm deploy:telemetry-retention`. |
| LOGTEL-002 | P1 | TODO | Add Worker-side defense-in-depth redaction | Website repo work. Scrub paths, URLs, emails, and API-key-looking strings before D1 insert even though Swift clients already sanitize current payloads. |
| LOGTEL-003 | P1 | TODO | Add Worker/Swift event-name sync check | Prevent deployed ingestion allowlist drift from `TelemetryEventName` and docs. |
| LOGTEL-004 | P2 | FIXED | Add safe STT dimensions to operation events | `dictation_operation` and `transcription_operation` now emit `speech_engine` and `engine_variant` from authoritative `STTResult` attribution/persisted operation output, not current settings. Unknown/local model variants are bucketed as `custom`. |
| LOGTEL-005 | P2 | TODO | Implement explicit diagnostic export bundle | User-triggered only. Include recent MacParakeet `os.Logger` entries, local audio diagnostics metrics/status lines, app/build info, and redacted runtime metadata. No audio bytes/files/content, transcripts, notes, prompts, file names, paths, URLs, API keys, or device UIDs. |
| LOGTEL-006 | P2 | IN PROGRESS | Normalize new local `os.Logger` lines | Targeted dictation/transcription lifecycle logs were normalized in this follow-up, including removing a captured audio filename from audio diagnostics. Continue using stable event-style messages with `key=value`, safe dimensions, classified public `error_type`, and `.private` for raw error details when touching nearby code. Avoid repo-wide churn-only rewrites. |
| LOGTEL-007 | P2 | FIXED | Resolve model lifecycle cancellation drift | Implemented canonical `model_operation` and `speech_engine_switch_operation` events in Swift with safe lifecycle dimensions. Cancellation is represented as `model_operation(outcome=cancelled)` instead of a duplicate `model_download_cancelled` event. Worker allowlist sync is handled in the website telemetry follow-up branch. |
| LOGTEL-008 | P3 | DEFERRED | Tail sampling for operation events | Not needed at current volume. If costs rise, keep all failures, crashes, unavailable outcomes, and slow operations while sampling successful fast operations. |
