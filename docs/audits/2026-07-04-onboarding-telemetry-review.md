# Onboarding + Telemetry Review

Date: 2026-07-04
Source: Cloudflare D1 `macparakeet-telemetry` (`7372263e-6a0b-4c70-8188-8f1d6d16bf31`) and current app code.

## Live Findings

- Ingestion is current: D1 had 1,304,121 rows from 2026-03-13T19:00:00Z through 2026-07-04T06:57:46Z at review time.
- The database is 709 MB. `wrangler d1 info` reported 196,905 rows written in the prior 24h, so retention and aggregation pressure remain real operational concerns.
- Last 30 days, GUI release builds:
  - Onboarding starters: 2,177
  - Onboarding completers: 1,419
  - Abandoned: 758 (34.8%)
  - Same-session dictation try rate after completion: 52.4%
  - Same-session dictation success rate after completion: 44.0%
- Shorter windows:
  - 7d: 425 starters, 291 completers, 31.5% abandon, 39.9% same-session dictation success
  - 14d: 799 starters, 556 completers, 30.4% abandon, 42.6% same-session dictation success
  - 30d: 2,177 starters, 1,419 completers, 34.8% abandon, 44.0% same-session dictation success

## Step Drop-Off

30-day distinct session transition rates:

| Transition | Rate |
|---|---:|
| Microphone -> Accessibility | 95.3% |
| Accessibility -> Hotkey | 86.9% |
| Hotkey -> Speech Model | 98.9% |
| Speech Model -> Ready | 81.2% |

Furthest measured step for 30-day starters:

| Furthest step | Sessions | Completed |
|---|---:|---:|
| Microphone | 97 | 0 |
| Accessibility | 299 | 0 |
| Hotkey | 20 | 2 |
| Speech Model | 335 | 0 |
| Ready | 1,421 | 1,417 |

Speech Model is the biggest measured blocker. Accessibility is the second.

## Model Setup Signals

30-day GUI model-download telemetry:

- `model_download_started local_speech_stack`: 1,730 sessions
- `model_download_completed local_speech_stack`: 1,524 sessions
- `model_download_failed WarmUpStalled`: 248 sessions
- Other notable failures: `URLError.timedOut` 23 sessions, `HubClientError.downloadError` 18, `BackgroundWarmUpError` 16, `URLError.networkConnectionLost` 13

Among onboarding sessions with model failures:

- 123 sessions ended at Speech Model and did not complete.
- 166 sessions still reached Ready and completed after a model failure.

## Instrumentation Gaps Found

- Existing `onboarding_completed` rows have missing `duration_seconds` in the last 30 days.
- Existing `onboarding_step` only records the destination step on forward navigation, so it misses:
  - welcome-only bounces
  - back navigation
  - sidebar jumps
  - explicit setup dismissal
  - engine ready versus engine failed terminal state
- Existing step labels are human copy (`speech model`) rather than stable telemetry identifiers.

## Change Direction

Keep the six-step dictation-first onboarding contract from ADR-005. Do not add back meeting or calendar setup.

Upgrade telemetry on the existing `onboarding_step` event instead of adding new event names, because the website Worker rejects unknown event names until its allowlist is deployed. The improved event should carry stable `step`, `action`, elapsed timing, step index, total steps, and optional engine state.

Product priority after this review:

1. Reduce Speech Model abandonment with better retry/failure measurement and more actionable recovery.
2. Reduce Accessibility confusion without weakening the paste/hotkey requirement.
3. Improve post-completion activation by nudging the first successful dictation, not just opening the app.
