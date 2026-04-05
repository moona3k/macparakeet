# ADR-002: Local-First Processing

> Status: **Accepted** (Amended 2026-03-11)
> Date: 2026-02-08
> Amended: 2026-03-11 — Refined scope from "no cloud processing" to "local-first" with opt-in LLM providers (ADR-011)

## Context

MacParakeet is entering a market where the dominant player (WisprFlow) relies on cloud processing. WisprFlow sends audio to remote servers for transcription and AI refinement, which creates three problems users consistently report:

1. **Privacy**: Audio data leaves the device. Users dictating medical notes, legal documents, proprietary code, or personal journals have legitimate privacy concerns.
2. **Latency**: WisprFlow users report 20-30 second server delays during peak usage hours. Cloud dependency means performance varies with server load, network conditions, and geographic distance.
3. **Reliability**: WisprFlow's Trustpilot rating is 2.8/5, with many complaints about server outages and inconsistent behavior. Cloud dependency introduces a failure mode that local processing eliminates entirely.

Meanwhile, local-only alternatives (MacWhisper, VoiceInk, BetterDictation) have proven that on-device STT is viable and increasingly preferred by privacy-conscious users.

## Decision

**Local-first processing.** The core product — transcription and dictation — runs on-device. Audio never leaves the device.

LLM-powered features (summarization, chat, transforms) use external providers configured by the user. This is opt-in, explicit, and text-only — audio is never sent.

### What is always local (non-negotiable)

- **STT**: Parakeet TDT 0.6B-v3 runs locally via FluidAudio CoreML on ANE (ADR-001, ADR-007)
- **Audio capture**: All microphone and file audio stays on-device
- **Text processing**: Deterministic pipeline runs locally (ADR-004)
- **Database**: All dictations, transcriptions, history stored locally (SQLite/GRDB)
- **Analytics**: Anonymous, opt-out telemetry via Cloudflare (ADR-012). No persistent IDs, no IP storage, no content transmitted.

### What uses external providers (opt-in, user-configured)

- **LLM features**: Summarization, chat-with-transcript, custom transforms (ADR-011)
  - Transcript *text* (not audio) is sent to the user's chosen provider
  - User configures their own API key, Ollama runtime, or Local CLI tool
  - No default provider — user must explicitly opt in
  - Features work without any provider configured (they're just unavailable)

### What uses the network (user-initiated)

- **YouTube downloads**: Fetches public videos for transcription (user-initiated)
- **License activation**: One-time LemonSqueezy API call (user-initiated)
- **yt-dlp updates**: Optional self-update check (non-blocking)

## Rationale

### Audio privacy is the brand

"Your voice never leaves your Mac" remains the core promise. This is unchanged. Audio — the sensitive data — is always processed locally on the ANE. What changed is recognizing that *transcript text* has a different privacy profile than *audio recordings*, and users should choose their own tradeoff.

### The quality gap is real

A local 8B model produces mediocre summaries. Cloud models (Claude, GPT-4) produce excellent ones. We tried local-only LLM (Qwen3-8B, ADR-008) and removed it because the quality wasn't worth the complexity. The "bring your own provider" approach delivers better quality with less code and zero resource impact.

### Privacy is a spectrum, not binary

| Configuration | Audio leaves device? | Text leaves device? | Quality |
|--------------|---------------------|---------------------|---------|
| No provider (default) | No | No | No LLM features |
| Ollama | No | No (localhost) | Good (local model) |
| Local CLI | No | Depends on the CLI tool | Varies by tool/provider |
| Cloud API key | No | Yes (user-initiated) | Excellent |

Users make an informed choice. The UI makes the tradeoff explicit. Apple Intelligence follows the same pattern — on-device by default, cloud with user consent for complex tasks.

### One-time purchase still works

Cloud LLM costs are paid directly by the user to their provider (Anthropic, OpenAI, etc.). MacParakeet has zero server costs, zero marginal cost per user. The one-time purchase model (ADR-003) is unaffected.

### Market validation

- Cursor ($20/mo) — bring your own API key for AI features
- Raycast — optional AI features with user's API key
- Char (fastrepl/char) — meeting transcription with cloud + local-provider support
- Apple Intelligence — on-device default, Private Cloud Compute for complex tasks

## Consequences

### Positive

- Audio never leaves the device — core privacy promise intact
- Transcription works fully offline — no degradation
- LLM features use best-available models (Claude, GPT-4) without bundling a runtime
- Local-only users can use Ollama
- Zero resource impact from LLM (no GPU memory, no model downloads)
- One-time purchase pricing preserved
- App Store compatible

### Negative

- **Messaging complexity**: "100% local" was simpler than "local-first with opt-in cloud." Must be communicated clearly and honestly.
- **Cloud LLM features require internet**: Summarization/chat won't work offline unless user runs Ollama. Transcription still works offline.
- **Transcript text exposure**: When using cloud providers or cloud-backed CLI tools, transcript text is sent to third-party services. Must be clear in UI. Users with sensitive content should use Ollama or skip LLM features.
- **No cloud backup or sync**: User data stays on-device. If the Mac is lost, dictation history is lost. This is intentional.
- **No collaborative features**: Real-time sharing, team vocabularies, or cross-device sync would require cloud infrastructure. These are out of scope.

## References

- ADR-011: LLM via cloud API keys + optional local providers
- ADR-008: Previous local LLM approach (HISTORICAL — removed 2026-02-23)
- WisprFlow Trustpilot reviews: 2.8/5 average, common complaints about delays and reliability
- Reddit r/macapps sentiment: strong preference for local processing
- Apple Intelligence strategy: on-device processing as default, cloud only for complex tasks with user consent
