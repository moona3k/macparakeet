# Telemetry System

> Status: **ACTIVE** — Design document for MacParakeet's privacy-first analytics system.
> Reviewed by: Codex (2026-03-13). See [Codex Review](#codex-review-2026-03-13) for accepted/rejected feedback.

## Philosophy

**Goal:** Understand how the app is used so we can make it better. Not to track users.

**Principles:**
- **Non-identifying by design** — No persistent user ID, no device fingerprint, no IP storage. Session IDs reset every app launch.
- **Transparent** — Users can see what's collected and opt out in Settings
- **Minimal** — Collect what helps improve the product, nothing more
- **Local-first still** — Audio never leaves the device. Only non-identifying usage signals are sent.

**Privacy promise (updated):**
> "Your audio and transcriptions never leave your device. MacParakeet collects non-identifying usage statistics — like which features are popular and how long transcriptions take — to help us improve. No personal data is ever collected. You can opt out anytime in Settings."

---

## Architecture

```
MacParakeet.app (Swift client)
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
Dashboard (password-protected, internal)
    │  SQL queries → charts
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
    props     TEXT CHECK(json_valid(props)),  -- JSON: {"duration": 12.5, "word_count": 84}
    app_ver   TEXT NOT NULL,         -- '0.4.2'
    os_ver    TEXT NOT NULL,         -- '15.3'
    locale    TEXT,                  -- 'en-US'
    chip      TEXT,                  -- 'Apple M1', 'Apple M2 Pro'
    country   TEXT,                  -- from CF-IPCountry header (not stored by app)
    session   TEXT NOT NULL,         -- random UUID, resets every app launch
    ts        TEXT NOT NULL          -- ISO 8601 timestamp
);

CREATE INDEX idx_events_event_ts ON events(event, ts);
CREATE INDEX idx_events_ts ON events(ts);
CREATE INDEX idx_events_session ON events(session);
```

### Privacy Properties (sent with every event)

| Field | Example | Privacy | Notes |
|---|---|---|---|
| `session` | `a8f2c...` | Random UUID | Resets every app launch. No persistence. |
| `app_ver` | `0.4.2` | Safe | Tracks version adoption |
| `os_ver` | `15.3` | Safe | macOS compatibility |
| `locale` | `en-US` | Safe | Language priority insights |
| `chip` | `Apple M1` | Safe | Performance benchmarking across chip types |
| `country` | `US` | From CF header | Cloudflare provides this; we don't store IP |

### What We Explicitly DON'T Collect

- Transcription text content
- Custom word or snippet values
- File names or paths
- YouTube URLs
- LLM prompts or responses
- IP addresses
- Device serial numbers or hardware IDs
- Persistent user identifiers across sessions
- Unredacted error descriptions (server-side PII redaction strips paths, URLs, keys before storage)
- Any data that could identify the user

---

## Event Catalog

### 1. App Lifecycle — "Who's using this?"

| Event | Props | Question It Answers |
|---|---|---|
| `app_launched` | — | How many active users? DAU/WAU/MAU? |
| `app_quit` | `session_duration_seconds` | How long are sessions? |
| `app_updated` | `from_version`, `to_version` | Are users updating? How fast? |
| `onboarding_completed` | `duration_seconds` | How long does setup take? |
| `onboarding_step` | `step` (permissions, model_download, etc.) | Where do people get stuck in onboarding? |

### 2. Dictation — "Is the core feature working well?"

| Event | Props | Question It Answers |
|---|---|---|
| `dictation_started` | `trigger` (hotkey, pill_click, menu_bar) | How do people start dictating? |
| `dictation_completed` | `duration_seconds`, `word_count`, `mode` (hold, persistent) | How long are dictations? Which mode is popular? |
| `dictation_cancelled` | `duration_seconds`, `reason` (escape, hotkey, silence) | Are people cancelling often? Why? |
| `dictation_empty` | `duration_seconds` | Are people getting empty results? (quality signal) |
| `dictation_failed` | `error_type` | Core feature failures — blind spot without this |

### 3. Transcription — "Is file transcription valuable?"

| Event | Props | Question It Answers |
|---|---|---|
| `transcription_started` | `source` (file, youtube, drag_drop), `audio_duration_seconds` | What sources are popular? How big are the files? |
| `transcription_completed` | `source`, `audio_duration_seconds`, `processing_seconds`, `word_count` | Real-world performance metrics |
| `transcription_cancelled` | `source`, `audio_duration_seconds` | Are people abandoning long jobs? |
| `transcription_failed` | `source`, `error_type` | What's breaking? |

### 4. Feature Adoption — "What features matter?"

| Event | Props | Question It Answers |
|---|---|---|
| `export_used` | `format` (txt, md, srt, vtt, docx, pdf, json) | Which export formats matter? |
| `llm_summary_used` | `provider` (openai, anthropic, ollama, openrouter) | Is LLM worth maintaining? Which providers? |
| `llm_summary_failed` | `provider`, `error_type` | LLM failure rates per provider |
| `llm_chat_used` | `provider`, `message_count` | Do people chat with transcripts? |
| `llm_chat_failed` | `provider`, `error_type` | Chat failure rates per provider |
| `history_searched` | — | Is search useful? |
| `history_replayed` | — | Do people re-listen to audio? |
| `copy_to_clipboard` | `source` (dictation, transcription, history) | How do people get text out? |

### 5. Settings & Customization — "How do people configure the app?"

| Event | Props | Question It Answers |
|---|---|---|
| `hotkey_customized` | — | Do people change the default hotkey? (not which key) |
| `processing_mode_changed` | `mode` (raw, clean) | Is the clean pipeline valued? |
| `custom_word_added` | — | Are custom words used? (NOT the word itself) |
| `snippet_added` | — | Are snippets used? |
| `setting_changed` | `setting` (save_history, audio_retention, menu_bar_only, hide_pill) | Which settings get toggled? |
| `telemetry_opted_out` | — | How many opt out? (send this one last event, then stop) |

### 6. Licensing — "Is the business working?"

> Note: Trial/licensing is not active yet (app is free during development). These events are included for when licensing is enabled.

| Event | Props | Question It Answers |
|---|---|---|
| `trial_started` | — | When do trials begin? |
| `trial_expired` | — | Are people hitting the trial wall? |
| `paywall_viewed` | — | Are people seeing the paywall? |
| `purchase_started` | — | Are people attempting to buy? |
| `license_activated` | — | Conversion! |
| `license_activation_failed` | `error_type` | What blocks purchases? |
| `restore_attempted` | — | Are people trying to restore? |
| `restore_succeeded` | — | Restore success rate |
| `restore_failed` | `error_type` | What blocks restores? |

### 7. Performance — "Is the app fast?"

| Event | Props | Question It Answers |
|---|---|---|
| `model_loaded` | `load_time_seconds` | How long does model warmup take on different chips? |
| `model_download_started` | — | First-run experience tracking |
| `model_download_completed` | `duration_seconds` | How long is the 6 GB download? |
| `model_download_cancelled` | — | Are people abandoning the download? |
| `model_download_failed` | `error_type` | Are downloads failing? |

### 8. Permissions — "Is onboarding smooth?"

| Event | Props | Question It Answers |
|---|---|---|
| `permission_prompted` | `permission` (microphone, accessibility) | How many prompts are shown? |
| `permission_granted` | `permission` | Grant rate |
| `permission_denied` | `permission` | Denial rate — is something confusing? |

### 9. Errors — "What's breaking?"

| Event | Props | Question It Answers |
|---|---|---|
| `error_occurred` | `domain`, `code`, `description` | What errors are users hitting? |

> **Important:** `error_occurred` includes a `description` field for full error visibility. The **Cloudflare Worker redacts PII server-side** before storage:
> - File paths (`/Users/...`, `~/...`) → `[PATH]`
> - URLs → `[URL]`
> - Strings matching API key patterns → `[REDACTED]`
> - Email addresses → `[EMAIL]`
> - Truncated to 512 chars max
>
> This gives us real debugging context while protecting user privacy.

---

## Swift Client Design

### Core API

```swift
// Simple fire-and-forget API
Telemetry.send("dictation_completed", [
    "duration_seconds": "12.5",
    "word_count": "84",
    "mode": "hold"
])

// No props needed
Telemetry.send("app_launched")
```

### Implementation

```swift
public protocol TelemetryServiceProtocol: Sendable {
    func send(_ event: String, props: [String: String]?)
    func flush() async
}

public final class TelemetryService: TelemetryServiceProtocol, @unchecked Sendable {
    // Queue events in memory
    // Each event gets a client-generated UUID (event_id) for idempotency
    // Flush every 60 seconds, on app quit/background, or when queue hits 50 events
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
  - On **app quit or background** (NSApplication termination + `NSWorkspace.willSleep`)
  - When queue hits **50 events**
  - **Immediately** for critical events: `telemetry_opted_out`, `onboarding_completed`, `license_activated`, and all licensing events
- On flush: POST batch as JSON array to `/api/telemetry`
- On network failure: events are **dropped** (not persisted to disk — simplicity over completeness)
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
   - Props values within max length (256 chars per value)
   - Reject unknown top-level fields
3. Rate limit: max **10 requests per minute** per IP (via CF headers, IP not stored)
4. Enrich: add `country` from `CF-IPCountry` header
5. Insert batch into D1 using `batch()` (transactional — all or nothing)
6. Return `200 OK` (or `207` for partial idempotency conflicts)

### Event Name Allowlist

The worker maintains a hardcoded allowlist of valid event names. Any event not on the list is rejected. This prevents:
- Endpoint abuse / data poisoning from reverse-engineering
- Accidental typos in event names going undetected

### CORS

Not technically needed for native HTTP clients, but included for consistency with existing workers.

---

## Data Retention

- **Raw events:** 90 days
- **Aggregated summaries:** Keep indefinitely (daily/weekly rollups via scheduled Worker)
- **Deletion:** Scheduled Cloudflare Worker cron (`0 2 * * *`) deletes events older than 90 days

---

## Dashboard

Internal, password-protected web page. Key views:

1. **Overview** — DAU/WAU/MAU, sessions, app version distribution
2. **Features** — Event counts by type, adoption trends
3. **Dictation** — Duration distribution, trigger breakdown, cancel rate
4. **Transcription** — Source breakdown, performance (processing time vs audio length)
5. **Errors** — Top errors, trends, affected versions
6. **Permissions** — Prompt/grant/deny funnel

Queries are simple SQL against D1. Dashboard is a Cloudflare Pages site (or a page within macparakeet-website behind auth).

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

## Implementation Order

1. **Documentation** (this file) + ADR-012 — define events, architecture, and decision rationale
2. **Cloudflare Worker + D1** — ingestion endpoint and storage
3. **Swift TelemetryService** — client in MacParakeetCore
4. **Settings toggle** — opt-out UI in Settings
5. **Instrument events** — add `Telemetry.send()` calls throughout the app
6. **Dashboard** — build when there's data to look at

---

## Codex Review (2026-03-13)

External AI review of the telemetry design. Each point was evaluated and accepted/rejected.

### Accepted

| # | Feedback | Action Taken |
|---|---|---|
| 1 | `error_occurred.description` is a privacy leak — free-form text could contain file paths, user content | **Partially accepted.** Kept `description` for full error visibility, but added server-side PII redaction in the Worker (strips file paths, URLs, API keys, emails; truncates to 512 chars). |
| 2 | No dedupe/idempotency key — retries cause double-counting | Added `event_id TEXT NOT NULL UNIQUE` (client-generated UUID) to schema. |
| 3 | "Anonymous by architecture" is too strong — session + chip + locale + country + timestamps could theoretically single out users | Reworded to "non-identifying, session-scoped telemetry" throughout. |
| 4 | Missing `permission_prompted` / `permission_granted` — can't compute denial rate without denominator | Added both events to new "Permissions" category. |
| 5 | Missing `dictation_failed` — core feature failures are a blind spot | Added to Dictation events with `error_type` prop. |
| 6 | Missing `transcription_cancelled` — long jobs get abandoned | Added with `source` and `audio_duration_seconds` props. |
| 7 | Missing `model_download_cancelled` — onboarding funnel gap | Added to Performance events. |
| 8 | Missing `llm_summary_failed` / `llm_chat_failed` — need failure rates per provider | Added both with `provider` + `error_type` props. |
| 9 | Cut `dictation_private` — sensitive signal, user explicitly wanted privacy | Removed. |
| 10 | Cut `hotkey_changed.key` value — track boolean, not which key | Changed to `hotkey_customized` with no props. |
| 11 | Cut `pill_hidden` as separate event — redundant with `setting_changed` | Merged into `setting_changed` with `setting: "hide_pill"`. |
| 12 | `error_occurred` needs allowlist — generic catch-all becomes junk | Added note: controlled allowlist of `domain` + `code`, no free-form text. |
| 13 | Flush immediately for critical events (opt-out, onboarding, licensing) | Updated batching strategy with immediate flush list. |
| 14 | Flush on app background/termination, not just quit — macOS can terminate without clean quit | Added `NSWorkspace.willSleep` and termination notification triggers. |
| 15 | Remove "respects macOS system analytics setting" — no public API to read it | Removed from opt-out behavior. |
| 16 | Use D1 `batch()` for transactional inserts | Updated worker logic. |
| 17 | Abuse controls: event name allowlist, rate limiting, field validation | Added to worker logic section. |
| 18 | `CHECK(json_valid(props))` on props column | Added to schema. |
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

- **Crash reporting** — If Apple's built-in crash reports (Xcode Organizer) aren't sufficient, add Sentry later
- **A/B testing** — Not needed now, but the event infrastructure supports it
- **Funnel analysis** — Can be done with SQL (session-based event sequences)
- **Speaker diarization telemetry** — Add events when diarization ships to GUI
