# Telemetry System

> Status: **ACTIVE** — Design document for MacParakeet's privacy-first analytics system.
> Reviewed by: Codex (2026-03-13). See [Codex Review](#codex-review-2026-03-13) for accepted/rejected feedback.
> Observability update: Codex (2026-04-26). Added canonical operation events for product health and CLI/agent usage while preserving the existing opt-out and privacy model.
> Logging/wide-events review: Codex (2026-05-02). Compared the implementation against the "Logging Sucks" wide-event guidance. Conclusion: MacParakeet already uses the right operation-wide-event model for product telemetry; follow-up work is mainly coverage, schema hygiene, and local diagnostic export. See [`docs/audits/2026-05-02-logging-telemetry-review.md`](audits/2026-05-02-logging-telemetry-review.md) and [`docs/audits/2026-05-02-logging-telemetry-issues.md`](audits/2026-05-02-logging-telemetry-issues.md).
> Field verification: Codex (2026-05-05). Verified the v0.6 telemetry error-count snapshot and CoreAudio `-10868` bucket after the v0.6.2 hotfix. See [`docs/audits/2026-05-05-telemetry-error-count-verification.md`](audits/2026-05-05-telemetry-error-count-verification.md).
> Dashboard taxonomy update: Codex (2026-05-05). Deployed `surface` separation
> for GUI vs CLI telemetry, split true operation failures from non-failure
> terminal outcomes, and renamed the dashboard error panel to failure-event log.
> Activation cohort caveats: Codex (2026-06-03). `first_dictation_completed`
> shipped 2026-05-23; do not divide 30d `first_dictation` by 30d `onboarding_completed`
> or compare 7d vs 30d without a ship-date cutoff. See
> [`docs/audits/2026-06-03-activation-metrics-cohort-caveats.md`](audits/2026-06-03-activation-metrics-cohort-caveats.md).

## Philosophy

**Goal:** Understand how the app is used so we can make it better. Not to track users.

**Principles:**
- **Non-identifying by design** — No persistent user ID, no device fingerprint, no IP storage. Session IDs reset every app launch.
- **Transparent** — Users can see what's collected and opt out in Settings
- **Minimal** — Collect what helps improve the product, nothing more
- **Local-first still** — Audio never leaves the device. Only non-identifying usage signals are sent.
- **Fully optional** — Turning telemetry off in Settings discards queued unsent telemetry, sends only the final `telemetry_opted_out` event, and then stops queuing new network telemetry. A request already in flight may complete. Local `os.Logger` diagnostics remain on-device unless a user explicitly exports them.

**Privacy promise (updated):**
> "Telemetry never includes your audio, transcripts, notes, prompts, or file names. MacParakeet collects non-identifying usage statistics — like which features are popular and how long transcriptions take — to help us improve. You can opt out anytime in Settings."

---

## Architecture

```
MacParakeet.app / macparakeet-cli (Swift clients)
    │
    │  Typed TelemetryEventSpec events
    │  - breadcrumb events for funnels
    │  - canonical *_operation outcome events for product health
    │
    │  POST /api/telemetry  (batch of events, every 60s / app quit / 50 events)
    │
    ▼
Cloudflare Worker (ingestion)
    │
    │  Validate (allowlist + rate limit), enrich (country from CF-IPCountry), write
    │
    ▼
Cloudflare D1 (SQLite)
    │
    ▼
Aggregate stats + internal inspection
    │  SQL queries → public aggregate stats / private diagnostics
```

### Why This Stack?

- **Cloudflare Worker** — We already use Cloudflare for the website and feedback. Same infra, same deploy pipeline.
- **D1 (SQLite)** — Familiar (MacParakeet uses GRDB/SQLite locally). Simple schema, simple queries.
- **No third-party analytics** — We own the data, the pipeline, and the privacy guarantees.

---

## Event Schema (D1)

```sql
CREATE TABLE events (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id  TEXT NOT NULL UNIQUE,  -- client-generated UUID, idempotency key
    event     TEXT NOT NULL,         -- 'dictation_completed', 'export_used'
    props     TEXT CHECK(json_valid(props) OR props IS NULL),  -- JSON props or NULL
    app_ver   TEXT NOT NULL,         -- '0.4.2'
    os_ver    TEXT NOT NULL,         -- '15.3'
    locale    TEXT,                  -- 'en-US'
    chip      TEXT,                  -- 'Apple M1', 'Apple M2 Pro'
    country   TEXT,                  -- from CF-IPCountry header (not stored by app)
    session   TEXT NOT NULL,         -- random UUID, resets every app launch
    surface   TEXT CHECK(surface IN ('gui', 'cli') OR surface IS NULL),
    ts        TEXT NOT NULL          -- ISO 8601 timestamp
);

CREATE INDEX idx_events_event_ts ON events(event, ts);
CREATE INDEX idx_events_ts ON events(ts);
CREATE INDEX idx_events_session ON events(session);
CREATE INDEX idx_events_surface_ts ON events(surface, ts);
```

`surface` is `gui` for the menu-bar app and `cli` for macparakeet-cli
invocations. Historical rows were backfilled on 2026-05-05 by
`scripts/migrations/2026-05-04-add-surface.sql` in the website repo:
`cli_operation` rows became `cli`; every other historical row became `gui`.
The deployed ingestion Worker writes a non-null surface for every new event,
deriving it from the event name when older clients do not send the field.

### Privacy Properties (sent with every event)

| Field | Example | Privacy | Notes |
|---|---|---|---|
| `session` | `a8f2c...` | Random UUID | Resets every app launch. No persistence. |
| `app_ver` | `0.4.2` | Safe | Tracks version adoption |
| `os_ver` | `15.3` | Safe | macOS compatibility |
| `locale` | `en-US` | Safe | Language priority insights |
| `chip` | `Apple M1` | Safe | Performance benchmarking across chip types |
| `country` | `US` | From CF header | Cloudflare provides this; we don't store IP |
| `surface` | `gui` / `cli` | Safe | Separates menu-bar app sessions from one-shot CLI invocations |

### What We Explicitly DON'T Collect

- Transcription text content
- Custom word or snippet values
- File names or paths
- YouTube/media URLs
- LLM prompts or responses
- AI Formatter profile names, profile ids, profile prompts, or match kinds
- Exact app bundle identifiers or app display names
- Browser hostnames, domains, URLs, or window titles
- IP addresses
- Microphone names, device UIDs, serial numbers, or hardware IDs
- Persistent user identifiers across sessions
- Raw provider error bodies or free-form user content in error fields
- Any data that could identify the user

Error details that are sent are sanitized at the Swift event-serialization
boundary: local file paths, `file://` URLs, and `http(s)` URLs are replaced and
values are truncated. LLM call sites intentionally omit error detail because
provider errors can echo transcript or prompt content. The ingestion Worker
validates event names, top-level fields, batch size, and prop length; it should
not be treated as the primary privacy scrubber for app-originated strings.

---

## Event Catalog

### Canonical Operation Events

MacParakeet uses two event shapes together:

- **Breadcrumb events** such as `dictation_started`, `transcription_failed`, and
  `llm_formatter_used` preserve existing funnel and feature-adoption analysis.
- **Operation events** such as `dictation_operation`,
  `transcription_operation`, `meeting_operation`, `llm_operation`,
  `transform_operation`, `feedback_operation`, `auto_save_operation`, `model_operation`,
  `speech_engine_switch_operation`, and `cli_operation` are wide,
  outcome-focused events emitted once per operation completion. They carry a
  short-lived `operation_id`, `workflow_id`, optional `parent_operation_id`,
  `outcome`, duration, safe dimensions, and `error_type` when relevant.

Operation IDs and workflow IDs are random UUIDs and are not persisted across app
launches. `workflow_id` lets child work, such as a transcription or LLM call,
join back to its root operation without string matching. `parent_operation_id`
links one child operation to the operation that started it. These IDs exist to
correlate local operation breadcrumbs inside one telemetry session, not to
identify a user.

This is the app equivalent of the wide-event / canonical-log-line model: for
MacParakeet, the unit is an operation rather than an HTTP request. A successful
dictation, file transcription, meeting recording, LLM call, auto-save, feedback
submission, or CLI invocation should have one wide outcome event with the safe
dimensions needed to answer product-health questions. Breadcrumb events remain
useful for funnels and feature adoption, but new non-trivial workflows should
not be breadcrumb-only.

Operation outcomes are intentionally not all errors. Dashboard and analytics
queries should treat:

- `success` as completed work.
- `failure` as a true operation failure that should appear in failure-rate and
  top-failure views.
- `cancelled`, `empty`, and `unavailable` as non-failure terminal outcomes.
  They are important product signals, but they should not be ranked as red
  failure buckets.

Local `os.Logger` lines are still useful for developer triage and user-supplied
diagnostics, especially audio/runtime edge cases. They are not the canonical
analytics source and should not replace a corresponding `*_operation` event
when the question is "what happened to this operation?"

### 1. App Lifecycle — "Who's using this?"

| Event | Props | Question It Answers |
|---|---|---|
| `app_launched` | — | How many active users? DAU/WAU/MAU? |
| `app_quit` | `session_duration_seconds` | How long are sessions? |
| `onboarding_completed` | `duration_seconds` | How long does setup take? |
| `onboarding_step` | `step` (permissions, model_download, etc.) | Where do people get stuck in onboarding? |

#### Activation analytics caveats (agents: read this)

**Do not conflate** `first_dictation_completed`, `onboarding_completed`, and
`dictation_completed` without reading
[`docs/audits/2026-06-03-activation-metrics-cohort-caveats.md`](audits/2026-06-03-activation-metrics-cohort-caveats.md).

| Pitfall | Correct approach |
|---------|------------------|
| `first_dictation_completed / onboarding_completed` over 30d → “~76% never activate” | **Invalid** if the window includes onboardings before **2026-05-23** (event did not exist). Pre-ship completers can have `dictation_completed` but zero `first_dictation_completed`. |
| 7d vs 30d `first_dictation` same-session rate → “activation improved” | Usually **ship-date mix**, not product. Post-ship cohorts are ~**43–45%** for both windows (2026-06-03 verify). |
| `app_launched` sessions = installs | **Session** resets every launch; install milestones fire once per UserDefaults install. |

**Preferred T0 KPI (history-safe):** share of `onboarding_completed` **sessions**
with at least one **`dictation_completed` in the same session** (~45–48% as of
2026-06-03). Use **`first_dictation_completed`** only for installs that
completed onboarding **on or after 2026-05-23**, for time-to-first-success
(`activation_window`) — not for long-window “% never activate” unless the
denominator is cohort-filtered.

The public stats dashboard (`/stats/`, `GET /api/stats`) exposes these as
`activation` (30d GUI): `t0_success_rate`, `post_ship_first_dictation_rate`
(cohort-filtered), and `onboarding_abandon_rate`, plus the ship-date caveat in
the UI. Setup **step views** remain a separate 24h funnel (`onboarding`).

### 2. Dictation — "Is the core feature working well?"

| Event | Props | Question It Answers |
|---|---|---|
| `dictation_started` | `trigger` (hotkey, pill_click, menu_bar) | How do people start dictating? |
| `dictation_completed` | `duration_seconds`, `word_count`, `mode` (hold, persistent), `speech_engine`, `engine_variant`, `language`, `app_category`, `device_*` | How long are dictations? Which mode, language, and STT engine are popular? Where do people dictate? |
| `first_dictation_completed` | `activation_window` (under_1m, under_1h, under_1d, under_1w, over_1w, unknown) | First **successful** dictation per install (shipped **2026-05-23**). Not comparable to 30d `onboarding_completed` without ship-date cohort filter — see [activation caveats](audits/2026-06-03-activation-metrics-cohort-caveats.md) |
| `dictation_cancelled` | `duration_seconds`, `reason` (escape, hotkey, ui), `device_*` | Are people cancelling often? Why? |
| `dictation_empty` | `duration_seconds`, `device_*` | Are people getting empty results? (quality signal) |
| `dictation_failed` | `error_type`, `device_*` | Core feature failures — blind spot without this |
| `dictation_operation` | `operation_id`, `workflow_id`, `parent_operation_id`, `outcome`, `trigger`, `mode`, `duration_seconds`, `word_count`, `speech_engine`, `engine_variant`, `language`, `app_category`, `error_type`, `cancel_reason`, `device_*` | One wide outcome event per dictation attempt |
| `dictation_first_load_caption_shown` | `first_install` | How often the first model-load caption is shown |
| `dictation_first_load_caption_duration` | `duration_ms`, `outcome` | How long the first model-load caption stays visible, and whether it resolves, extends, or fails |

> **Device props** (optional, included when available): `device_transport`, `device_sub_transport`, `device_sample_rate`, `device_channels`, `device_fallback`, `device_selected`. Raw device names and UIDs are intentionally not serialized.

`app_category` (optional) is the coarse category of the frontmost app selected
as the dictation finish target — one of `messaging`, `email`, `browser`,
`notes`, `docs`, `code`, `terminal`, `other`. The app's bundle identifier is
mapped to a structural bucket on-device and **only the bucket is transmitted** —
the bundle id never leaves the device, and any unrecognized app maps to
`other`, so a niche or identifying app is never observable. The same prop
appears on `transform_executed` / `transform_operation` (the app a Transform
rewrote text in).

Dictation AI Formatter profiles can use exact bundle IDs, app display names, and
profile prompts locally to choose a formatter prompt and annotate saved
dictation history. V1 does not add any formatter-profile telemetry fields:
profile ids, profile names, profile match kinds, exact bundle IDs, app display
names, and prompt bodies stay on-device. Future aggregate profile-adoption
telemetry must update the paired website Worker allowlist and stats paths before
shipping.

`speech_engine` and `engine_variant` describe the STT engine that actually
processed the audio. They come from `STTResult` attribution or persisted
transcription output, not the user's current mutable engine setting. Unknown
model variants are serialized as `custom` so local model paths or future
private identifiers cannot leak into telemetry.

`language` is the normalized STT language code (`en`, `ko`, `ja`, `zh`, etc.)
reported by the speech engine. It is not derived from the user's macOS locale
and is omitted when unknown, set to auto-detect, or outside the bounded language
catalog.

### 3. Transcription — "Is file transcription valuable?"

| Event | Props | Question It Answers |
|---|---|---|
| `transcription_started` | `source` (file, youtube, drag_drop, meeting), `audio_duration_seconds` | What sources are popular? How big are the jobs? |
| `transcription_completed` | `source`, `audio_duration_seconds`, `processing_seconds`, `word_count`, `speaker_count`, `diarization_requested`, `diarization_applied`, `speech_engine`, `engine_variant`, `language` | Real-world performance, speaker-label coverage, language coverage, and STT engine adoption across file, YouTube, and meeting pipelines |
| `transcription_cancelled` | `source`, `audio_duration_seconds`, `stage` (download, audio_conversion, stt, diarization, post_processing) | Where do users abandon jobs? |
| `transcription_failed` | `source`, `stage`, `error_type` | What's breaking, and in which pipeline stage? |
| `transcription_operation` | `operation_id`, `workflow_id`, `parent_operation_id`, `outcome`, `source`, `stage`, `duration_seconds`, `audio_duration_seconds`, `processing_seconds`, `word_count`, `speaker_count`, `diarization_requested`, `diarization_applied`, `input_kind`, `media_extension`, `file_size_bucket`, `speech_engine`, `engine_variant`, `language`, `error_type` | One wide outcome event per file, media URL, or meeting transcription |

`transcription_operation` is the broad product-health outcome event. Its
`stage` values are `preflight`, `download`, `audio_conversion`, `stt`,
`diarization`, `post_processing`, and `persistence`. `transcription_completed`
remains the stable success breadcrumb/performance event. For meetings, the app
always treats the final transcript as fresh batch STT over the recorded source
artifacts, not reused live-preview metadata. The separate `diarization_*`
events remain useful for diarization-specific timing and failure analysis.

### 3b. Speaker Diarization — "Is speaker detection working?"

| Event | Props | Question It Answers |
|---|---|---|
| `diarization_started` | — | How often is diarization used? |
| `diarization_completed` | `duration_seconds`, `speaker_count` | How long does it take? How many speakers? |
| `diarization_failed` | `error_type`, `error_detail` | What breaks in diarization? |

### 4. Feature Adoption — "What features matter?"

| Event | Props | Question It Answers |
|---|---|---|
| `export_used` | `format` (txt, md, srt, vtt, docx, pdf, json) | Which export formats matter? |
| `llm_prompt_result_used` | `provider` | Are prompt-library results and generated summaries being used? Which providers matter? |
| `llm_prompt_result_failed` | `provider`, `error_type` | Failure rates for prompt-library result generation per provider |
| `llm_chat_used` | `provider`, `source` (`meeting_ask`, `transcript_chat`), `message_count` | Do people chat with transcripts? Live meeting Ask is separable from post-transcription chat. |
| `llm_chat_failed` | `provider`, `source` (`meeting_ask`, `transcript_chat`), `error_type` | Chat failure rates per provider and surface |
| `llm_transform_used` | `provider` | One-off transform feature usage |
| `llm_transform_failed` | `provider`, `error_type` | One-off transform failure rates |
| `transform_executed` | `transform_name`, `capture_path`, `replace_path`, `llm_ms`, `total_ms`, `app_category` | End-to-end system-wide Transform completions by built-in/custom bucket, and where they're used |
| `transform_failed` | `transform_name`, `reason` | End-to-end system-wide Transform failure reasons (`empty_selection`, `no_provider`, `capture_failed`, `llm_failed`, `replacement_failed`, `cancelled`) |
| `transform_operation` | `operation_id`, `workflow_id`, `parent_operation_id`, `outcome`, `transform_name`, `stage`, `capture_path`, `replace_path`, `duration_seconds`, `llm_ms`, `total_ms`, `app_category`, `error_type` | One safe outcome event per system-wide Transform attempt, without prompts, selected text, or output text |
| `ask_menu_opened` | — | Whether users discover the live meeting Ask prompt menu |
| `ask_prompt_fired` | `source`, `group`, `label` | Which built-in live Ask prompts are used, using stable built-in slugs. Edited built-ins and custom prompts collapse to `custom`. |
| `llm_formatter_used` | `provider`, `source`, `duration_seconds`, `input_chars`, `output_chars`, `default_prompt_used`, `input_truncated` | Is transcript/dictation formatting useful, and how expensive is it? |
| `llm_formatter_failed` | `provider`, `source`, `duration_seconds`, `error_type`, `default_prompt_used`, `input_truncated` | Formatter failure rates and prompt-shape correlations |
| `llm_provider_unavailable` | `provider`, `error_type`, `feature`, `source` | Provider setup/config drift distinct from true LLM request failures |
| `llm_operation` | `operation_id`, `workflow_id`, `parent_operation_id`, `feature`, `provider`, `streaming`, `outcome`, `duration_seconds`, `input_chars`, `output_chars`, `input_truncated`, `prompt_default_used`, `message_count`, `error_type` | One safe outcome event per LLM call, without prompts, responses, or provider error bodies |
| `history_searched` | — | Is search useful? |
| `history_replayed` | — | Do people re-listen to audio? |
| `copy_to_clipboard` | `source` (dictation, transcription, history, meeting, discover) | How do people get text out? |
| `keystroke_snippet_fired` | — | Are keystroke action snippets being used? |
| `feedback_submitted` | `category` (bug, featureRequest, other) | Feedback volume and sentiment split |
| `feedback_operation` | `operation_id`, `workflow_id`, `parent_operation_id`, `category`, `outcome`, `duration_seconds`, `screenshot_attached`, `system_info_included`, `error_type` | Feedback delivery health without storing message text or email |
| `auto_save_operation` | `operation_id`, `workflow_id`, `parent_operation_id`, `scope`, `format`, `outcome`, `duration_seconds`, `error_type` | Whether transcript/meeting auto-save succeeds for configured users |
| `transcription_deleted` | — | Are users cleaning up transcriptions? |
| `dictation_deleted` | — | History hygiene patterns |
| `transcription_favorited` | `is_favorite` (true/false) | Which content types get saved? |
| `dictation_undo_used` | — | Is the 5-second undo window used? |
| `chat_conversation_created` | — | Multi-conversation adoption |

Formatter profile routing is intentionally absent from the formatter telemetry
props in V1. The existing `default_prompt_used` value can distinguish global
default prompt usage from a custom prompt body, but it does not identify whether
that custom prompt came from the global formatter preference or a local
app/category profile.

### 4b. Meeting Recovery — "Does crash resilience work?"

| Event | Props | Question It Answers |
|---|---|---|
| `meeting_recovery_discovered` | `count`, `source` (launch, settings) | How often interrupted recordings are found, and where users encounter them |
| `meeting_recovery_started` | `count`, `source` | How often users choose to recover |
| `meeting_recovery_completed` | `count`, `duration_seconds`, `source` | Recovery success rate and latency |
| `meeting_recovery_discarded` | `count`, `source` | How often users intentionally discard interrupted recordings |
| `meeting_recovery_failed` | `count`, `source`, `error_type`, `error_detail` | What blocks recovery in the field |

### 4c. Meeting Recording — "Is meeting capture healthy?"

| Event | Props | Question It Answers |
|---|---|---|
| `meeting_recording_started` | `trigger` (manual, hotkey, calendar_auto_start) | How meetings start |
| `meeting_recording_completed` | `duration_seconds`, `live_word_count`, `live_transcript_lagged` | Recording duration and live-preview quality |
| `meeting_recording_cancelled` | `duration_seconds` | How often recordings are intentionally discarded |
| `meeting_recording_failed` | `error_type` | What blocks recording/finalization |
| `meeting_operation` | `operation_id`, `workflow_id`, `parent_operation_id`, `outcome`, `trigger`, `stage`, `duration_seconds`, `live_word_count`, `live_transcript_lagged`, `microphone_track_present`, `system_track_present`, `notes_used`, `notes_length_bucket`, `error_type` | One wide outcome event for the full meeting capture + transcription flow |
| `vad_model_prep` | `outcome` (`prepared`, `failed`) | Whether launch-time Silero VAD model prep is reaching the installed base in flag-on VAD live-chunking builds |

`meeting_operation.stage` values are `permissions`, `start_recording`,
`recording`, `stop_recording`, `transcription`, `complete_transcription`, and
`cancel`.

### 5. Settings & Customization — "How do people configure the app?"

| Event | Props | Question It Answers |
|---|---|---|
| `hotkey_customized` | `surface` (`dictation`, `meeting`, `file_transcription`, `youtube_transcription`), `kind` (`disabled`, `modifier`, `key_code`, `chord`) | Which capture surface gets its hotkey customized, and is the binding a single modifier vs a full chord vs a key? (still **not** which specific key — see Q&A item 10) |
| `processing_mode_changed` | `mode` (raw, clean) | Is the clean pipeline valued? |
| `custom_word_added` | — | Are custom words used? (NOT the word itself) |
| `custom_word_deleted` | — | Are custom words removed often? |
| `snippet_added` | — | Are snippets used? |
| `snippet_deleted` | — | Are snippets removed often? |
| `prompt_created` | — | Are custom prompt templates used? |
| `prompt_updated` | — | Are custom prompts actively maintained? |
| `prompt_deleted` | — | Are custom prompts abandoned or cleaned up? |
| `setting_changed` | `setting` (save_history, audio_retention, app_appearance, menu_bar_only, hide_pill, save_transcription_audio, youtube_audio_quality, speaker_diarization, parakeet_model_variant, whisper_default_language, auto_save, meeting_auto_save, microphone_selection, meeting_audio_source_mode, pause_media_during_dictation, keep_dictation_on_clipboard, launch_at_login, silence_auto_stop, voice_return, calendar_auto_start_mode, calendar_reminder_minutes, calendar_trigger_filter, calendar_included_calendars) | Which non-hotkey settings get toggled? Hotkey changes use `hotkey_customized`. Appearance changes log only that the setting changed, not the selected light/dark/system value. The Parakeet model picker, Whisper language picker, and CJK first-run setup emit only the setting name; selected speech engine details are observed from actual STT usage rows. Media pause does not log source app, title, URL, artist, or Now Playing metadata. |
| `telemetry_opted_out` | — | How many opt out? (send this one last event, then stop) |

### 5b. Calendar Auto-Start — "Do calendar-driven meetings work?"

> Calendar automation is implemented and enabled (`AppFeatures.calendarEnabled
> = true`) after the post-#318 reliability hardening, so these events now fire
> from the real UI. Auto-start defaults to mode `.off`, so volume reflects only
> users who opt in via onboarding or Settings.

| Event | Props | Question It Answers |
|---|---|---|
| `calendar_reminder_shown` | `mode`, `lead_minutes`, `has_meet_url` | How often calendar reminders surface and under which mode |
| `calendar_auto_start_triggered` | `lead_seconds`, `has_meet_url` | How often countdowns reach auto-start |
| `calendar_auto_start_cancelled` | `reason` | How often users cancel the countdown |
| `calendar_auto_start_failed` | `reason` (`permission_denied`, `state_busy`, `service_threw`) | What blocks auto-start |

### 6. Licensing — "Is the business working?"

> Note: App is now free/GPL-3.0. The licensing enum cases are intentionally
> retained for the historical LemonSqueezy/trial entitlement surface and for a
> possible future paid official distribution. Most are not emitted today; do not
> remove them as dead code without explicit owner direction and an ADR/spec
> update.

| Event | Props | Question It Answers |
|---|---|---|
| `trial_started` | — | When do trials begin? (currently not emitted in free builds) |
| `trial_expired` | — | Are people hitting the trial wall? (currently not emitted in free builds) |
| `purchase_started` | — | Are people attempting to buy? (currently not emitted in free builds) |
| `license_activated` | — | Official paid distribution/support conversion, if re-enabled |
| `license_activation_failed` | `error_type` | What blocks purchase activation, if re-enabled? |
| `restore_attempted` | — | Are people trying to restore? (currently not emitted in free builds) |
| `restore_succeeded` | — | Restore success rate, if paid activation is re-enabled |
| `restore_failed` | `error_type` | What blocks restores, if paid activation is re-enabled? |

### 7. Performance — "Is the app fast?"

| Event | Props | Question It Answers |
|---|---|---|
| `model_loaded` | `load_time_seconds`, `model_kind`, `speech_engine`, `engine_variant` | How long does model warmup take on different chips and engines? |
| `model_download_started` | `model_kind`, `speech_engine`, `engine_variant` | First-run and Whisper model setup funnel by engine |
| `model_download_completed` | `duration_seconds`, `model_kind`, `speech_engine`, `engine_variant` | How long do model downloads take by engine/model? |
| `model_download_failed` | `error_type`, `model_kind`, `speech_engine`, `engine_variant` | Are downloads failing for Parakeet setup or Whisper downloads? |
| `model_operation` | `operation_id`, `workflow_id`, `parent_operation_id`, `action`, `outcome`, `stage`, `model_kind`, `speech_engine`, `engine_variant`, `duration_seconds`, `error_type` | Canonical model lifecycle event for downloads, warm-up, repairs, cache clears, and cancellations |
| `speech_engine_switch_operation` | `operation_id`, `workflow_id`, `parent_operation_id`, `from_engine`, `to_engine`, `outcome`, `duration_seconds`, `blocked_reason`, `error_type`, `was_cold` | Why engine switches succeed, fail, cancel, or get blocked; whether Whisper switches are still paying first-use optimize cost |
| `stt_runtime_unhealthy` | `reason` | Whether the STT runtime watchdog detects a stuck speech runtime |

### 8. Permissions — "Is onboarding smooth?"

| Event | Props | Question It Answers |
|---|---|---|
| `permission_prompted` | `permission` (microphone, accessibility, screen_recording, calendar) | How many prompts are shown? |
| `permission_granted` | `permission` | Grant rate |
| `permission_denied` | `permission` | Denial rate — is something confusing? |

### 9. Errors — "What's breaking?"

| Event | Props | Question It Answers |
|---|---|---|
| `error_occurred` | `domain`, `code`, `description` | What errors are users hitting? |
| `crash_occurred` | `crash_type`, `signal`, `reason`, `stack_trace`, `crash_app_ver`, `crash_os_ver` | What crashes are happening? |

### 10. CLI — "Are agents and scripts succeeding?"

| Event | Props | Question It Answers |
|---|---|---|
| `cli_operation` | `operation_id`, `workflow_id`, `parent_operation_id`, `command`, `subcommand`, `outcome`, `duration_seconds`, `input_kind`, `output_format`, `json`, `exit_code`, `error_type` | Which CLI workflows are used by scripts/agents, and where they fail |

CLI telemetry is initialized once by the root `macparakeet-cli` runner after
argument parsing succeeds and uses the same app preference as the GUI. Override
resolution order (first match wins):

1. `MACPARAKEET_TELEMETRY=0/false/no/off` → force-off for this process
2. `MACPARAKEET_TELEMETRY=1/true/yes/on` → force-on for this process
3. `DO_NOT_TRACK=1` → force-off (industry-standard signal, also honored by
   Homebrew, GitLab, VS Code)
4. CI auto-disable: any of `CI`, `GITHUB_ACTIONS`, `GITLAB_CI`, `BUILDKITE`,
   `CIRCLECI`, `TRAVIS`, `JENKINS_URL`, `TF_BUILD`, `TEAMCITY_VERSION` set to
   a truthy value (avoids 1000-job agent runs flooding the endpoint)
5. Persisted UserDefaults `telemetryEnabled` (default: true)

CLI-only users (no GUI) can persist their preference via:

```bash
macparakeet-cli config set telemetry off   # also accepts on, true/false, 1/0
macparakeet-cli config get telemetry
macparakeet-cli config list
```

The CLI writes to the shared UserDefaults suite (`com.macparakeet.MacParakeet`),
so a later GUI install picks the same preference up automatically.
The CLI also honors `DO_NOT_TRACK=1` and `MACPARAKEET_TELEMETRY=off` for
automation contexts.

CLI events use `surface='cli'` and are shown in their own dashboard section.
They should not be mixed into GUI app sessions, app version adoption,
crash-free rates, or GUI operation failure lists because each CLI invocation is
a one-shot process with a fresh session ID.

> **Important:** `error_occurred` includes a bounded `description` field, but
> callers should treat it as an allowlisted diagnostic string, not a place for
> arbitrary provider or user-content error bodies. `TelemetryEventSpec.props`
> sanitizes paths and URLs at serialization time and truncates descriptions to
> 512 chars. The Worker is an ingestion validator, not the primary redaction
> boundary.

---

## Swift Client Design

### Core API

```swift
// Simple fire-and-forget API. Event names and props are typed in
// TelemetryEventSpec so schema drift is caught by tests.
Telemetry.send(.dictationCompleted(
    durationSeconds: 12.5,
    wordCount: 84,
    mode: .hold
))

let operationContext = Observability.childOperationContext()
Telemetry.send(.transcriptionOperation(
    operationID: operationContext.operationID,
    operationContext: operationContext,
    outcome: .success,
    source: .file,
    stage: .postProcessing,
    durationSeconds: 2.9,
    audioDurationSeconds: 30,
    processingSeconds: 2.4,
    wordCount: 120,
    speakerCount: nil,
    diarizationRequested: false,
    diarizationApplied: false,
    inputKind: .audio,
    mediaExtension: "m4a",
    fileSizeBucket: "1_10mb",
    errorType: nil
))
```

### Implementation

```swift
public protocol TelemetryServiceProtocol: Sendable {
    func send(_ event: TelemetryEventSpec)
    func sendAndFlush(_ event: TelemetryEventSpec) async -> Bool
    func clearQueue()
    func flush() async
    func flushForTermination()
}

public final class TelemetryService: TelemetryServiceProtocol, @unchecked Sendable {
    // Queue events in memory
    // Each event gets a client-generated UUID (event_id) for idempotency
    // Flush every 60 seconds, on app termination, or when queue hits 50 events
    // Respect opt-out setting
    // Random session UUID per launch (not persistent)
    // Include device context (app version, OS, locale, chip) with every event
}
```

### Batching Strategy

- Events queue in memory (array of structs)
- Each event gets a client-generated `event_id` (UUID) for idempotency — prevents double-counting on retries
- Flush triggers:
  - Every **60 seconds** (timer)
  - On **app termination** (`NSApplication.willTerminateNotification`)
  - When queue hits **50 events**
  - **Immediately** for critical events: `telemetry_opted_out`, `onboarding_completed`, `app_quit`, `crash_occurred`, `license_activated`, and all licensing events
- On flush: POST batch as JSON array to `/api/telemetry`
- On network failure: failed events are requeued in memory and retried until queue pressure trims them. Events are still not persisted to disk.
- Max queue size: **200 events** (prevent memory issues if network is down for extended period)

> **Note:** Metrics are best-effort and biased against short sessions and sessions that end in crashes. This is acceptable for product analytics at this scale.

### Opt-Out Behavior

- Default: **ON** (telemetry enabled)
- Toggle in Settings: "Help improve MacParakeet" with explanatory detail text
- When opted out: `send()` is a no-op (events are silently discarded)
- One final `telemetry_opted_out` event is sent and flushed immediately when the user disables telemetry

---

## Cloudflare Worker Design

### Endpoint

`POST https://macparakeet.com/api/telemetry`

### Request Format

```json
{
    "events": [
        {
            "event_id": "b3f1a2c4-...",
            "event": "dictation_completed",
            "props": {"duration_seconds": "12.5", "word_count": "84"},
            "app_ver": "0.4.2",
            "os_ver": "15.3",
            "locale": "en-US",
            "chip": "Apple M1",
            "session": "a8f2c3d4-...",
            "ts": "2026-03-13T10:30:00Z"
        }
    ]
}
```

### Worker Logic

1. Parse JSON body
2. Validate:
   - Max **100 events** per batch
   - Required fields present (`event_id`, `event`, `app_ver`, `os_ver`, `session`, `ts`)
   - `event` name is on the **allowlist** (reject unknown event names)
   - Props values within max length (1024 chars per value)
   - Reject unknown top-level fields
3. Rate limit: max **10 requests per minute** per IP (via CF headers, IP not stored)
4. Enrich: add `country` from `CF-IPCountry` header
5. Insert batch into D1 using `batch()` (transactional — all or nothing)
6. Return `200 OK`; duplicate `event_id` values are ignored idempotently

### Event Name Allowlist

The worker maintains a hardcoded allowlist of valid event names. Any event not on the list is rejected. This prevents:
- Endpoint abuse / data poisoning from reverse-engineering
- Accidental typos in event names going undetected

The app-side source of truth is `TelemetryEventName` plus
`TelemetryImplementedContract` in `Sources/MacParakeetCore/Services`. The
website Worker allowlist may temporarily contain legacy or planned event names,
but every emitted app event must be accepted by the Worker before release.
Schema-drift checks should compare the Swift enum, this document, and the
Worker allowlist together.

### CORS

Not technically needed for native HTTP clients, but included for consistency with existing workers.

---

## Data Retention

- **Raw events:** 90 days
- **Aggregated summaries:** Keep indefinitely once rollups exist
- **Deletion:** The sibling `macparakeet-website` branch
  `codex/telemetry-retention-cron` adds a standalone scheduled Cloudflare Worker
  that runs daily at 02:00 UTC and deletes `events` rows older than 90 days.
  Deploy that Worker before relying on automatic production deletion.

---

## Dashboard

Aggregate product stats are exposed through the website stats endpoint/page; raw
event inspection should remain internal. Key views:

1. **Overview** — GUI app DAU/WAU/MAU, sessions, app version distribution
2. **Features** — Event counts by type, adoption trends
3. **Dictation** — Duration distribution, trigger breakdown, cancel rate
4. **Transcription** — Source breakdown, performance (processing time vs audio length)
5. **Failures** — explicit failure events, operation failures, crash reports
6. **Permissions** — Prompt/grant/deny funnel
7. **CLI** — CLI invocations, CLI versions, and command outcomes, separated
   from GUI app session counts

Main dashboard queries default to `surface='gui'`. CLI telemetry has a separate
view because each command is a one-shot invocation with a fresh session ID and
can otherwise inflate app sessions, version adoption, crash-free rates, and
operation failures.

Operation-health dashboard queries should keep true `failure` outcomes separate
from non-failure terminal states such as `cancelled`, `empty`, and
permission-gated `unavailable`; otherwise ordinary user cancellation can be
mislabeled as an error bucket.

Operation health groups by an **event-specific primary dimension** (for example
`dictation_operation` uses `trigger · mode`, not a COALESCE chain that would
prefer `speech_engine` and hide hotkey vs pill_click success rates).

The deployed stats endpoint returns both `operations.failures` and
`operations.non_failure`. The dashboard's "Failure Event Log" is only for
explicit failure breadcrumb events and crash reports; normal terminal outcomes
are excluded from that panel.

The dashboard's operation reliability panel covers GUI product operation events
that map directly to user-visible work: dictation, transcription, meeting, LLM,
Transforms, feedback, auto-save, model lifecycle, and speech-engine switches.
It also exposes a dedicated speech-engine usage panel so Parakeet-vs-Whisper
adoption can be read from actual usage rows (`dictation_operation`,
`transcription_operation`, `model_operation`) and settings intent rows
(`speech_engine_switch_operation`). A separate language usage panel reads the
same dictation/transcription operation and completion rows so CJK and other
multilingual adoption can be monitored without collecting transcript content.

Queries are simple SQL against D1. Dashboard is a Cloudflare Pages site at
`https://macparakeet.com/stats/`.

## Operational Feedback Loop

MacParakeet now has enough telemetry coverage for a lightweight automated
review loop, but the loop should keep counting and judgment separate:

```text
D1 telemetry -> deterministic review report -> thresholded signals -> agent/human review -> issue/PR/journal -> post-release verification
```

The deterministic layer lives in the website repo because it owns the D1
binding and dashboard taxonomy:

```bash
cd ../macparakeet-website
pnpm telemetry:review
```

That command runs `scripts/telemetry-review.mjs`, queries the remote
`macparakeet-telemetry` D1 database, and writes Markdown + JSON reports to this
repo's private `journal/` directory by default. The journal is gitignored; it is
for candid field notes and daily operating context, not public documentation.
Use the script's `--output-dir`, `--markdown-output`, or `--json-output` flags
when a CI or cron job needs durable artifacts elsewhere.

The reviewer script treats SQL as the source of truth for counts and rates. It
separates GUI vs CLI surfaces, keeps true `outcome='failure'` operation rows
separate from `cancelled` / `empty` / `unavailable`, and compares the current
window against a prior baseline. It also carries watchlist checks for the v0.6
incidents: exact CoreAudio `-10868`, `interrupted during subscribe`
false-failure telemetry, and YouTube transcription failures after the 0.6.2
hotfix.

An agent reviewer can consume the generated report, but it should not be trusted
to do raw counting ad hoc. Its job is code correlation and product judgment:
whether a signal is real user impact, which release or code path is implicated,
and whether the right follow-up is an issue, PR, dashboard taxonomy fix, or
continued monitoring.

---

## Capacity Planning

At MacParakeet's scale:

| Metric | Value |
|---|---|
| Events per user per day | ~30 |
| D1 free tier | 5M rows read/day, 100K rows written/day |
| 100 DAU x 30 events | 3,000 writes/day (well within free tier) |
| 90-day retention x 3K/day | ~270K rows (tiny for SQLite) |
| Scale limit (D1 free) | ~3,300 DAU before needing paid tier ($5/mo) |

---

## Implementation Status

1. **Documentation** — active in this file plus ADR-012.
2. **Cloudflare Worker + D1** — deployed ingestion endpoint and D1 storage.
3. **Swift TelemetryService** — active in MacParakeetCore with opt-out support.
4. **Settings toggle** — active; disabling telemetry clears queued unsent events.
5. **Instrumented events** — core lifecycle, dictation, transcription, meeting,
   LLM, feedback, auto-save, model, permission, crash, and CLI surfaces are
   instrumented.
6. **Dashboard** — deployed at `https://macparakeet.com/stats/` with GUI/CLI
   surface separation and operation failure taxonomy.

---

## Codex Review (2026-03-13)

External AI review of the telemetry design. Each point was evaluated and accepted/rejected.

### Accepted

| # | Feedback | Action Taken |
|---|---|---|
| 1 | `error_occurred.description` is a privacy leak — free-form text could contain file paths, user content | **Partially accepted.** Kept a bounded `description`, but the current implemented guardrail is Swift-side serialization sanitization for paths/URLs plus truncation. Worker-side PII redaction remains a defense-in-depth follow-up. |
| 2 | No dedupe/idempotency key — retries cause double-counting | Added `event_id TEXT NOT NULL UNIQUE` (client-generated UUID) to schema. |
| 3 | "Anonymous by architecture" is too strong — session + chip + locale + country + timestamps could theoretically single out users | Reworded to "non-identifying, session-scoped telemetry" throughout. |
| 4 | Missing `permission_prompted` / `permission_granted` — can't compute denial rate without denominator | Added both events to new "Permissions" category. |
| 5 | Missing `dictation_failed` — core feature failures are a blind spot | Added to Dictation events with `error_type` prop. |
| 6 | Missing `transcription_cancelled` — long jobs get abandoned | Added with `source` and `audio_duration_seconds` props. |
| 7 | Missing model download cancellation visibility — onboarding funnel gap | Covered by canonical `model_operation` events with `action`, `outcome`, `stage`, model/engine dimensions, and duration. A separate `model_download_cancelled` event was intentionally not kept because it duplicates and blurs warm-up vs download cancellation. |
| 8 | Missing LLM failure telemetry — need provider-level failure rates | Added `llm_prompt_result_failed`, `llm_chat_failed`, and formatter failure events with provider + error props. |
| 9 | Cut `dictation_private` — sensitive signal, user explicitly wanted privacy | Removed. |
| 10 | Cut `hotkey_changed.key` value — track boolean, not which key | Changed to `hotkey_customized`. The 2026-05-09 review found props were emitting NULL on every event so we couldn't tell hotkey customization apart by capture surface. Now emits `surface` (which feature) + `kind` (structural category: disabled / modifier / key_code / chord). The original "not which key" commitment still holds — we never emit the specific modifier name or keyCode value. |
| 11 | Cut `pill_hidden` as separate event — redundant with `setting_changed` | Merged into `setting_changed` with `setting: "hide_pill"`. |
| 12 | `error_occurred` needs allowlist — generic catch-all becomes junk | Added note: controlled allowlist of `domain` + `code`, no free-form text. |
| 13 | Flush immediately for critical events (opt-out, onboarding, licensing) | Updated batching strategy with immediate flush list. |
| 14 | Flush on app background/termination, not just quit — macOS can terminate without clean quit | Implemented app termination flush. Background and sleep-triggered flush remain future hardening. |
| 15 | Remove "respects macOS system analytics setting" — no public API to read it | Removed from opt-out behavior. |
| 16 | Use D1 `batch()` for transactional inserts | Updated worker logic. |
| 17 | Abuse controls: event name allowlist, rate limiting, field validation | Added to worker logic section. |
| 18 | `CHECK(json_valid(props))` on props column | Current schema allows either valid JSON props or `NULL` props: `CHECK(json_valid(props) OR props IS NULL)`. |
| 19 | Add purchase funnel events (paywall_viewed, purchase_started, restore_*) | Added to Licensing category. |
| 20 | Document that metrics are best-effort, biased against short/crash sessions | Added note to batching strategy. |

### Rejected

| # | Feedback | Reason for Rejection |
|---|---|---|
| 1 | Cut `custom_word_added` / `snippet_added` | These tell us if clean pipeline features are valued — important for roadmap decisions. |
| 2 | Cut `history_searched` / `history_replayed` — marginal | History is a core feature. Cheap to keep, useful signal. |
| 3 | Coarsen `chip` to family (apple_silicon vs intel) | Exact chip model is valuable for performance benchmarking across M1/M2/M3/M4. App is Apple Silicon only anyway. |
| 4 | Coarsen `os_ver` to major only | Minor version matters for compatibility debugging (e.g., 15.2 vs 15.3 behavior differences). |
| 5 | `[String: String]` props → typed struct | CAST in SQL is fine at this scale. Typed props adds complexity without proportional benefit. |
| 6 | Promote frequently queried props as columns | Premature optimization. JSON blob with CAST works at <1M rows. Can promote later if needed. |
| 7 | `ts` as INTEGER unix timestamp | ISO 8601 TEXT is more readable and debuggable. Performance is irrelevant at this scale. |

---

## Future Considerations

- **Server-side defense-in-depth redaction** — Add Worker-side scrubbing for
  paths, URLs, API-key-looking strings, and emails before D1 insert. The app
  already sanitizes current emitted details, but the Worker should not rely on
  every future client doing the right thing.
- **Local diagnostic export** — Build an explicit user-triggered diagnostic
  bundle that includes recent `os.Logger` entries for MacParakeet subsystems,
  `~/Library/Logs/MacParakeet/dictation-audio.log` status/metric lines,
  app version/build info, and redacted runtime metadata. Do not upload
  automatically. Do not include audio bytes, transcripts, notes, prompts, file
  names, paths, URLs, API keys, microphone names, CoreAudio device IDs, or
  device UIDs.
- **Operation-event coverage gate** — For any new workflow that can succeed,
  fail, cancel, or become unavailable, require a matching wide `*_operation`
  event or a documented reason it is intentionally breadcrumb-only.
- **Worker/schema sync test** — Add a small CI or release-check script that
  verifies the Swift event-name enum is accepted by the checked-in/deployed
  Worker allowlist.
- **Tail sampling** — Not needed at current event volume. If costs rise, sample
  successful fast operations first while keeping all failures, crashes,
  unavailable outcomes, and slow operations.
- **Crash reporting** — If the self-hosted crash reporter plus Apple's built-in crash reports (Xcode Organizer) aren't sufficient, add Sentry later
- **A/B testing** — Not needed now, but the event infrastructure supports it
- **Funnel analysis** — Can be done with SQL (session-based event sequences)
- **~~Speaker diarization telemetry~~** — ✅ Shipped: `diarization_started`, `diarization_completed`, `diarization_failed`
- **Retained licensing telemetry** -- Keep unfired trial/purchase/restore event
  names unless the project owner explicitly decides to remove the future
  paid-distribution option and records that decision in an ADR/spec update
