# ADR-012: Self-Hosted Telemetry via Cloudflare

> Status: **Accepted**
> Date: 2026-03-13

## Context

MacParakeet launched with a "zero telemetry" stance as a privacy selling point. In practice, this leaves us blind to:

- How many people actively use the app
- Which features are popular vs unused
- What errors users encounter
- Performance characteristics across different hardware
- Onboarding drop-off rates
- Whether the LLM integration is worth maintaining

Without observability, we can't make informed product decisions or debug issues users don't bother reporting.

### Options Considered

| Option | Pros | Cons |
|---|---|---|
| **TelemetryDeck** (SaaS) | Free tier (100K signals/mo), privacy-first, Swift SDK, zero setup | Closed-source backend, no self-hosting, ~110 DAU limit on free tier |
| **Aptabase** (open source) | Self-hostable, privacy-first, Swift SDK | Extra infra to maintain, smaller community |
| **PostHog** (open source) | Feature-rich (funnels, session replay, A/B testing) | Overkill for indie app, heavy infra (ClickHouse, Kafka, Redis) |
| **Sentry** (SaaS) | Best-in-class crash reporting | Focused on errors, not product analytics |
| **Self-hosted on Cloudflare** | Own the stack, $0 cost, already have Cloudflare infra, full control | Must build dashboard, no pre-built funnels |

### Decision

**Self-hosted on Cloudflare (Worker + D1).** Reasons:

1. **We already have Cloudflare infra** — Website, feedback worker, R2 downloads, DNS. Adding a Worker + D1 database is incremental, not new infrastructure.
2. **Full control over privacy guarantees** — We can make architectural promises (no persistent IDs, no IP storage) and verify them in our own code.
3. **$0 at our scale** — D1 free tier supports ~3,300 DAU before needing the $5/mo paid tier.
4. **Dashboard is no longer the bottleneck** — AI-assisted development makes building a simple dashboard trivial.
5. **Simplicity** — The entire system is ~200 lines of code (Swift client + Cloudflare Worker). No vendor SDK, no third-party dependency in the app.

### Privacy Model

The system is designed as **non-identifying, session-scoped telemetry**:

- **No persistent user ID** — Session UUID resets every app launch
- **No device fingerprint** — No hardware ID, serial number, or UDID
- **No IP storage** — Cloudflare processes requests but we don't store IP addresses
- **Country only** — Derived from Cloudflare's `CF-IPCountry` header, not from IP geolocation we perform
- **No content** — Transcription text, custom words, file names, URLs, LLM prompts are never sent
- **Idempotent** — Client-generated event UUIDs prevent double-counting
- **Error messages redacted** — Server-side regex strips file paths, URLs, API keys, and emails before storage. Descriptions truncated to 512 chars.
- **Opt-out** — Users can disable in Settings; `send()` becomes a no-op

This is not "anonymous" in the strict GDPR sense (session + chip + locale + country + timestamps could theoretically single out users). It is non-identifying: we have no mechanism to map any event to any person, and we don't try.

### What We Collect

~40 event types across 9 categories: app lifecycle, dictation, transcription, feature adoption, settings, licensing (future), performance, permissions, and errors. Full catalog in `docs/telemetry.md`.

### What We Don't Collect

Transcription content, audio, file paths, YouTube URLs, LLM prompts/responses, custom words/snippets, persistent identifiers, IP addresses.

## Consequences

### Positive

- **Product decisions backed by data** — Know which features matter, what's breaking, where onboarding drops off
- **No vendor dependency** — Own the full pipeline, no third-party SDK in the app binary
- **Privacy by architecture** — Can make and verify strong privacy claims
- **Zero cost** — Free tier covers early growth comfortably

### Negative

- **Must build and maintain dashboard** — No pre-built analytics UI (mitigated: simple SQL queries, AI-assisted development)
- **Best-effort metrics** — Dropped on network failure, biased against short/crash sessions (acceptable for product analytics)
- **No advanced analytics** — No built-in funnels, cohorts, or retention curves (can build with SQL if needed)

### Risks

- **Endpoint abuse** — Mitigated with event name allowlist, rate limiting, field validation
- **Schema evolution** — Props are JSON, so new event types don't require migrations. New categories just need allowlist updates.

## References

- Full design: `docs/telemetry.md`
- Feedback worker (same pattern): `macparakeet-website/functions/api/feedback.ts`
